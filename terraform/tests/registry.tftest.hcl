# Design tests. The AWS provider is mocked, so these run in CI with no credentials and create
# nothing. They pin down the decisions that matter: tags can never be moved, every image is
# scanned, storage is bounded, and the role Jenkins pushes with can reach one repository only and
# can be assumed by one role only.

mock_provider "aws" {}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
    arn        = "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_AdministratorAccess_0abc/engineer"
  }
}

override_data {
  target = data.aws_partition.current
  values = {
    partition = "aws"
  }
}

override_data {
  target = data.aws_iam_session_context.current
  values = {
    issuer_arn = "arn:aws:iam::123456789012:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_AdministratorAccess_0abc"
  }
}

# --- Repository ---------------------------------------------------------------------------------

run "tags_are_immutable" {
  command = plan

  assert {
    condition     = aws_ecr_repository.webapp.image_tag_mutability == "IMMUTABLE"
    error_message = "A pushed tag must never point at different bytes later."
  }
  assert {
    condition     = aws_ecr_repository.webapp.name == "davine-wk9-webapp"
    error_message = "The repository name is what the pipeline and the teardown search use."
  }
}

run "every_push_is_scanned_and_encrypted_with_kms" {
  command = plan

  assert {
    condition     = aws_ecr_repository.webapp.image_scanning_configuration[0].scan_on_push
    error_message = "Every pushed image must be scanned for known vulnerabilities."
  }
  assert {
    condition     = aws_ecr_repository.webapp.encryption_configuration[0].encryption_type == "KMS"
    error_message = "Images must be encrypted with KMS."
  }
}

run "lifecycle_expires_untagged_first_then_keeps_the_newest" {
  command = plan

  assert {
    condition     = length(jsondecode(local.lifecycle_policy).rules) == 2
    error_message = "Two lifecycle rules are expected."
  }
  assert {
    condition = (
      jsondecode(local.lifecycle_policy).rules[0].selection.tagStatus == "untagged" &&
      jsondecode(local.lifecycle_policy).rules[0].selection.countNumber == 1
    )
    error_message = "Untagged images must expire after one day."
  }
  assert {
    condition = (
      jsondecode(local.lifecycle_policy).rules[1].selection.tagStatus == "any" &&
      jsondecode(local.lifecycle_policy).rules[1].selection.countNumber == 10 &&
      jsondecode(local.lifecycle_policy).rules[1].rulePriority > jsondecode(local.lifecycle_policy).rules[0].rulePriority
    )
    error_message = "The keep-the-newest rule must cover any tag, keep 10 by default and come last, as ECR requires."
  }
}

run "too_few_images_to_roll_back_is_refused" {
  command = plan
  variables {
    images_to_keep = 2
  }
  expect_failures = [var.images_to_keep]
}

run "too_many_images_is_refused" {
  command = plan
  variables {
    images_to_keep = 101
  }
  expect_failures = [var.images_to_keep]
}

# --- Push role: who may assume it ---------------------------------------------------------------

run "only_the_applying_role_may_assume_the_push_role" {
  command = plan

  assert {
    condition     = length(jsondecode(local.push_role_trust).Statement) == 1
    error_message = "The trust policy must have exactly one statement."
  }
  assert {
    condition     = jsondecode(local.push_role_trust).Statement[0].Principal.AWS == "arn:aws:iam::123456789012:root"
    error_message = "The principal must be this account, never another account or *."
  }
  assert {
    condition = (
      jsondecode(local.push_role_trust).Statement[0].Condition.ArnEquals["aws:PrincipalArn"] ==
      "arn:aws:iam::123456789012:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_AdministratorAccess_0abc"
    )
    error_message = "Only the role of the engineer who applied this may assume the push role."
  }
  assert {
    condition     = aws_iam_role.jenkins_ecr_push.max_session_duration == 3600
    error_message = "Sessions of the push role must last at most one hour."
  }
}

run "an_explicit_trusted_role_replaces_the_applying_role" {
  command = plan
  variables {
    trusted_principal_arn = "arn:aws:iam::123456789012:role/ci-runner"
  }

  assert {
    condition     = jsondecode(local.push_role_trust).Statement[0].Condition.ArnEquals["aws:PrincipalArn"] == "arn:aws:iam::123456789012:role/ci-runner"
    error_message = "trusted_principal_arn must replace the applying role."
  }
}

run "a_wildcard_trusted_role_is_refused" {
  command = plan
  variables {
    trusted_principal_arn = "arn:aws:iam::123456789012:role/*"
  }
  expect_failures = [var.trusted_principal_arn]
}

run "a_user_instead_of_a_role_is_refused" {
  command = plan
  variables {
    trusted_principal_arn = "arn:aws:iam::123456789012:user/jenkins"
  }
  expect_failures = [var.trusted_principal_arn]
}

# --- Push role: what it may do ------------------------------------------------------------------

run "token_statement_is_the_only_wildcard_resource" {
  command = plan

  assert {
    condition = (
      jsondecode(local.push_role_policy).Statement[0].Action == "ecr:GetAuthorizationToken" &&
      jsondecode(local.push_role_policy).Statement[0].Resource == "*"
    )
    error_message = "Only ecr:GetAuthorizationToken, which has no resource-level permissions, may use Resource *."
  }
  assert {
    condition     = length([for s in jsondecode(local.push_role_policy).Statement : s if s.Resource == "*"]) == 1
    error_message = "No other statement may apply to every resource."
  }
}

run "push_and_pull_are_limited_to_this_repository" {
  command = plan

  assert {
    condition     = jsondecode(local.push_role_policy).Statement[1].Resource == "arn:aws:ecr:us-east-1:123456789012:repository/davine-wk9-webapp"
    error_message = "Push and pull must apply to the week 9 repository only."
  }
  assert {
    condition = toset(jsondecode(local.push_role_policy).Statement[1].Action) == toset([
      "ecr:BatchCheckLayerAvailability", "ecr:CompleteLayerUpload", "ecr:InitiateLayerUpload",
      "ecr:PutImage", "ecr:UploadLayerPart", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
    ])
    error_message = "Exactly the five push and two pull actions docker needs, no more."
  }
}

run "the_role_cannot_delete_or_reconfigure_anything" {
  command = plan

  assert {
    condition = length([
      for a in flatten([for s in jsondecode(local.push_role_policy).Statement : s.Action]) : a
      if can(regex("(\\*|Delete|Set|Put(Lifecycle|Registry|Replication|ImageScanning|ImageTagMutability)|Tag|Create)", a))
    ]) == 0
    error_message = "The push role must not delete images or repositories, change policies or settings, or use wildcards."
  }
  assert {
    condition     = jsondecode(local.push_role_policy).Statement[1].Effect == "Allow" && length(jsondecode(local.push_role_policy).Statement) == 2
    error_message = "The policy must have exactly the token statement and the repository statement."
  }
}

run "the_policy_is_attached_to_the_push_role" {
  command = plan

  assert {
    condition     = aws_iam_role.jenkins_ecr_push.name == "davine-wk9-jenkins-ecr-push"
    error_message = "The role name is what the scripts and the teardown search use."
  }
  assert {
    condition     = aws_iam_role_policy.jenkins_ecr_push.policy == local.push_role_policy
    error_message = "The inline policy must be the push-and-pull policy."
  }
}
