variable "expected_aws_account_id" {
  description = "AWS account that Terraform is allowed to manage."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_aws_account_id))
    error_message = "The expected AWS account ID must contain exactly 12 digits."
  }
}

variable "aws_region" {
  description = "AWS Region for the bootstrap state bucket."
  type        = string

  validation {
    condition = (
      can(regex("^[a-z]{2}(-[a-z0-9]+)+-[0-9]+$", var.aws_region)) &&
      !startswith(var.aws_region, "cn-") &&
      !startswith(var.aws_region, "us-gov-") &&
      !startswith(var.aws_region, "us-iso-") &&
      !startswith(var.aws_region, "us-isob-")
    )
    error_message = "The AWS Region must be a valid commercial AWS Region."
  }
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state."
  type        = string

  validation {
    condition = (
      length(var.state_bucket_name) >= 3 &&
      length(var.state_bucket_name) <= 63 &&
      can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.state_bucket_name)) &&
      !strcontains(var.state_bucket_name, "..") &&
      !strcontains(var.state_bucket_name, ".-") &&
      !strcontains(var.state_bucket_name, "-.") &&
      !can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", var.state_bucket_name)) &&
      !startswith(var.state_bucket_name, "xn--") &&
      !startswith(var.state_bucket_name, "sthree-") &&
      !startswith(var.state_bucket_name, "amzn-s3-demo-") &&
      !endswith(var.state_bucket_name, "-s3alias") &&
      !endswith(var.state_bucket_name, "--ol-s3") &&
      !endswith(var.state_bucket_name, ".mrap") &&
      !endswith(var.state_bucket_name, "--x-s3") &&
      !endswith(var.state_bucket_name, "--table-s3")
    )
    error_message = "The state bucket name must be a valid, exact S3 bucket name."
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

variable "github_owner" {
  description = "GitHub organisation or user that owns the repository."
  type        = string

  validation {
    condition     = length(var.github_owner) <= 39 && can(regex("^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$", var.github_owner))
    error_message = "The GitHub owner must contain only letters, digits and non-edge hyphens."
  }
}

variable "github_owner_id" {
  description = "Immutable numeric GitHub ID for the repository owner."
  type        = string

  validation {
    condition     = can(regex("^[1-9][0-9]*$", var.github_owner_id))
    error_message = "The GitHub owner ID must contain only digits and must not start with zero."
  }
}

variable "github_repository" {
  description = "GitHub repository name trusted for OIDC federation."
  type        = string

  validation {
    condition     = length(var.github_repository) <= 100 && can(regex("^[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "The GitHub repository must contain only letters, digits, dots, underscores and hyphens."
  }
}

variable "github_repository_id" {
  description = "Immutable numeric GitHub repository ID."
  type        = string

  validation {
    condition     = can(regex("^[1-9][0-9]*$", var.github_repository_id))
    error_message = "The GitHub repository ID must contain only digits and must not start with zero."
  }
}

variable "github_environment" {
  description = "Protected GitHub Environment trusted for OIDC federation."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$", var.github_environment))
    error_message = "The GitHub Environment must be a 1 to 100 character name without spaces, colons or wildcards."
  }
}
