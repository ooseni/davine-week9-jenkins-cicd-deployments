# Credentials come from the environment (AWS_PROFILE with IAM Identity Center), never from code.
provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

# The role behind the signed-in session (for IAM Identity Center, the AWSReservedSSO_... role).
# Only that role may assume the Jenkins push role.
data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

locals {
  name = "davine-wk9"

  # Every resource gets these through default_tags, so cost, ownership and lifecycle are visible
  # in the console, in Cost Explorer and in any tag-based IAM condition.
  common_tags = {
    Project     = "davine-week9-jenkins-cicd-deployments"
    Programme   = "Davine Technologies internship"
    Environment = "lab"
    Owner       = "devops-engineering"
    CostCenter  = "internship-labs"
    ManagedBy   = "terraform"
  }
}
