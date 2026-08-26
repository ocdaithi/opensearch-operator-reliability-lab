provider "aws" {
  region = var.aws_region

  dynamic "assume_role" {
    for_each = var.terraform_admin_role_arn == null ? [] : [var.terraform_admin_role_arn]

    content {
      role_arn     = assume_role.value
      session_name = "terraform-bootstrap-management"
    }
  }

  default_tags {
    tags = local.common_tags
  }
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_iam_user" "bootstrap" {
  user_name = local.bootstrap_user_name
}
