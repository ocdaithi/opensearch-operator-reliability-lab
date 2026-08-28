locals {
  project_name    = "opensearch-operator-reliability-lab"
  resource_prefix = "opensearch-lab"
  state_key       = "bootstrap/terraform.tfstate"
  lock_key        = "${local.state_key}.tflock"

  budget_name                   = "${local.resource_prefix}-monthly-cost"
  bootstrap_user_name           = "${local.resource_prefix}-bootstrap"
  terraform_admin_role_name     = "${local.resource_prefix}-terraform-admin"
  github_actions_role_name      = "${local.resource_prefix}-github-actions"
  terraform_admin_boundary_name = "${local.resource_prefix}-terraform-admin-boundary"
  github_actions_boundary_name  = "${local.resource_prefix}-github-actions-boundary"
  temporary_policy_name         = "${local.resource_prefix}-temporary-bootstrap"
  terraform_admin_policy_name   = "${local.resource_prefix}-bootstrap-management"
  github_actions_policy_name    = "${local.resource_prefix}-bootstrap-state"

  github_subject = "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repository}@${var.github_repository_id}:environment:${var.github_environment}"

  common_tags = {
    ManagedBy = "Terraform"
    Project   = local.project_name
    Scope     = "account-bootstrap"
  }

  actual_budget_thresholds = toset([10, 25, 40, 50])

  state_bucket_arn             = "arn:${data.aws_partition.current.partition}:s3:::${var.state_bucket_name}"
  terraform_admin_boundary_arn = "arn:${data.aws_partition.current.partition}:iam::${var.expected_aws_account_id}:policy/${local.terraform_admin_boundary_name}"
  github_actions_boundary_arn  = "arn:${data.aws_partition.current.partition}:iam::${var.expected_aws_account_id}:policy/${local.github_actions_boundary_name}"
  temporary_policy_arn         = "arn:${data.aws_partition.current.partition}:iam::${var.expected_aws_account_id}:policy/${local.temporary_policy_name}"
  budget_arn                   = "arn:${data.aws_partition.current.partition}:budgets::${var.expected_aws_account_id}:budget/${local.budget_name}"
  primary_billing_view_arn     = "arn:${data.aws_partition.current.partition}:billing::${var.expected_aws_account_id}:billingview/primary"
}
