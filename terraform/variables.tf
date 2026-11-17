variable "region" {
  description = "AWS Region for the container registry."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "Use a Region code such as us-east-1."
  }
}

variable "images_to_keep" {
  description = "How many images the repository keeps. Older ones expire, which bounds the storage cost."
  type        = number
  default     = 10

  validation {
    condition     = var.images_to_keep >= 3 && var.images_to_keep <= 100 && floor(var.images_to_keep) == var.images_to_keep
    error_message = "Keep between 3 and 100 images: at least the live release, the one before it and a spare, for rollbacks."
  }
}

variable "trusted_principal_arn" {
  description = "IAM role allowed to assume the Jenkins push role. Leave null to use the role of whoever runs terraform apply."
  type        = string
  default     = null

  validation {
    condition     = var.trusted_principal_arn == null || can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$", var.trusted_principal_arn))
    error_message = "Give one IAM role ARN, with no wildcard."
  }
}
