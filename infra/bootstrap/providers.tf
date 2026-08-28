provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.expected_aws_account_id]

  default_tags {
    tags = local.common_tags
  }
}

data "aws_partition" "current" {}

data "aws_iam_user" "bootstrap" {
  user_name = local.bootstrap_user_name
}
