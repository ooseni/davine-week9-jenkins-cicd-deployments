output "region" {
  description = "Region of the registry."
  value       = var.region
}

output "repository_name" {
  description = "ECR repository name."
  value       = aws_ecr_repository.webapp.name
}

output "repository_url" {
  description = "ECR repository URL. Contains the account ID: scripts redact it from anything saved."
  value       = aws_ecr_repository.webapp.repository_url
}

output "push_role_arn" {
  description = "Role scripts/jenkins_up.sh assumes to mint the registry token for Jenkins."
  value       = aws_iam_role.jenkins_ecr_push.arn
}

output "trusted_role_arn" {
  description = "The only role allowed to assume the push role."
  value       = local.trusted_role
}
