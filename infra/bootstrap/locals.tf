locals {
  project_name      = "opensearch-operator-reliability-lab"
  state_bucket_name = "opensearch-lab-tfstate-ocdaithi-1346323330-eu-west-1"
  state_key         = "bootstrap/terraform.tfstate"

  budget_name                   = "opensearch-lab-monthly-cost"
  bootstrap_user_name           = "opensearch-lab-bootstrap"
  terraform_admin_role_name     = "opensearch-lab-terraform-admin"
  github_actions_role_name      = "opensearch-lab-github-actions"
  terraform_admin_boundary_name = "opensearch-lab-terraform-admin-boundary"
  github_actions_boundary_name  = "opensearch-lab-github-actions-boundary"
  temporary_policy_name         = "opensearch-lab-temporary-bootstrap"

  github_subject = "repo:ocdaithi@321047870/opensearch-operator-reliability-lab@1346323330:environment:aws-bootstrap"

  common_tags = {
    ManagedBy = "Terraform"
    Project   = local.project_name
    Scope     = "account-bootstrap"
  }

  actual_budget_thresholds = toset([10, 25, 40, 50])

  terraform_admin_boundary_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${local.terraform_admin_boundary_name}"
  github_actions_boundary_arn  = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${local.github_actions_boundary_name}"
  temporary_policy_arn         = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${local.temporary_policy_name}"
  budget_arn                   = "arn:${data.aws_partition.current.partition}:budgets::${data.aws_caller_identity.current.account_id}:budget/${local.budget_name}"
  primary_billing_view_arn     = "arn:${data.aws_partition.current.partition}:billing::${data.aws_caller_identity.current.account_id}:billingview/primary"
}
