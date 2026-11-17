# The container registry the pipeline pushes to and the cluster pulls from.
# Encrypted with KMS under the AWS managed key aws/ecr, not a customer managed key: a customer
# managed key adds a monthly charge and a 7-day deletion wait that a lab destroyed the same day
# does not need. Production would use one (see "Lab vs production" in the README).
#trivy:ignore:AWS-0033
resource "aws_ecr_repository" "webapp" {
  name = "${local.name}-webapp"

  # A tag, once pushed, always means the same bytes. The pipeline tags every build uniquely
  # (version-commit-build) and deploys by digest, so nothing ever needs to move a tag.
  image_tag_mutability = "IMMUTABLE"

  # Basic scanning against known CVEs on every push, at no charge.
  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }

  # Lab only: lets `terraform destroy` delete the repository with its images in it.
  force_delete = true
}

# Cost and clutter control: untagged images (left over from failed pushes) go after a day, and
# only the newest images are kept. ECR requires the "any" rule to have the highest priority number.
resource "aws_ecr_lifecycle_policy" "webapp" {
  repository = aws_ecr_repository.webapp.name
  policy     = local.lifecycle_policy
}

locals {
  lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Remove untagged images a day after they were pushed"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the newest ${var.images_to_keep} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.images_to_keep
        }
        action = { type = "expire" }
      },
    ]
  })
}
