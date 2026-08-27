variable "aws_region" {
  description = "AWS Region for the bootstrap state bucket."
  type        = string
  default     = "eu-west-1"

  validation {
    condition     = var.aws_region == "eu-west-1"
    error_message = "The bootstrap foundation must remain in eu-west-1."
  }
}

variable "budget_notification_email" {
  description = "Private email recipient for all account cost budget notifications."
  type        = string
  sensitive   = true

  validation {
    condition = (
      length(var.budget_notification_email) <= 254 &&
      trimspace(var.budget_notification_email) == var.budget_notification_email &&
      can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.budget_notification_email))
    )
    error_message = "The budget notification recipient must be a valid email address."
  }
}

variable "terraform_admin_role_arn" {
  description = "ARN of the Terraform administration role to assume after the initial bootstrap apply."
  type        = string
  default     = null
  sensitive   = true
  nullable    = true

  validation {
    condition = (
      var.terraform_admin_role_arn == null ||
      can(regex("^arn:[a-z0-9-]+:iam::[0-9]{12}:role/opensearch-lab-terraform-admin$", var.terraform_admin_role_arn))
    )
    error_message = "The Terraform administration role ARN must name opensearch-lab-terraform-admin."
  }
}
