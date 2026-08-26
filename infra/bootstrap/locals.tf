locals {
  project_name        = "opensearch-operator-reliability-lab"
  state_bucket_prefix = "opensearch-lab-tfstate-"
  state_key           = "bootstrap/terraform.tfstate"

  budget_name               = "opensearch-lab-monthly-cost"
  bootstrap_user_name       = "opensearch-lab-bootstrap"
  terraform_admin_role_name = "opensearch-lab-terraform-admin"
  github_actions_role_name  = "opensearch-lab-github-actions"
  temporary_policy_name     = "opensearch-lab-temporary-bootstrap"

  github_subject = "repo:ocdaithi@321047870/opensearch-operator-reliability-lab@1346323330:environment:aws-bootstrap"

  common_tags = {
    ManagedBy = "Terraform"
    Project   = local.project_name
    Scope     = "account-bootstrap"
  }

  actual_budget_thresholds = toset([10, 25, 40, 50])

  temporary_policy_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${local.temporary_policy_name}"
}
