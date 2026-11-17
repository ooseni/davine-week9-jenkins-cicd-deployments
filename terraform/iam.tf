# The identity Jenkins pushes with, on the week 1 principle: no long-lived access key, and only
# the permissions the job needs.
#
# scripts/jenkins_up.sh assumes this role from the engineer's own session, asks ECR for a
# registry token, and gives Jenkins only that token. An ECR token carries the permissions of the
# identity that requested it, so Jenkins can push to and pull from this one repository, and do
# nothing else in the account, until the token expires.
locals {
  account_id     = data.aws_caller_identity.current.account_id
  partition      = data.aws_partition.current.partition
  repository_arn = "arn:${local.partition}:ecr:${var.region}:${local.account_id}:repository/${local.name}-webapp"
  trusted_role   = coalesce(var.trusted_principal_arn, data.aws_iam_session_context.current.issuer_arn)
  push_actions   = ["ecr:BatchCheckLayerAvailability", "ecr:CompleteLayerUpload", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart"]
  pull_actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
  push_role_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "OnlyTheEngineerWhoAppliedThis"
      Effect    = "Allow"
      Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
      Action    = "sts:AssumeRole"
      # The account root as principal means "a principal in this account"; the condition narrows
      # it to one role. Matching on the ARN, not a principal ID, keeps working if IAM Identity
      # Center re-creates its role.
      Condition = { ArnEquals = { "aws:PrincipalArn" = local.trusted_role } }
    }]
  })
  push_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # GetAuthorizationToken has no resource-level permissions: AWS only accepts "*".
        Sid      = "GetRegistryToken"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid      = "PushAndPullThisRepositoryOnly"
        Effect   = "Allow"
        Action   = concat(local.push_actions, local.pull_actions)
        Resource = local.repository_arn
      },
    ]
  })
}

resource "aws_iam_role" "jenkins_ecr_push" {
  name                 = "${local.name}-jenkins-ecr-push"
  description          = "Assumed by scripts/jenkins_up.sh to mint the ECR token Jenkins uses: push and pull ${local.name}-webapp only."
  assume_role_policy   = local.push_role_trust
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "jenkins_ecr_push" {
  name   = "push-and-pull-${local.name}-webapp"
  role   = aws_iam_role.jenkins_ecr_push.id
  policy = local.push_role_policy
}
