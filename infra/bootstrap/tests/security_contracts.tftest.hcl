mock_provider "aws" {
  alias = "setup"

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn    = "arn:aws:s3:::opensearch-lab-tfstate-test"
      bucket = "opensearch-lab-tfstate-test"
      id     = "opensearch-lab-tfstate-test"
    }
  }

  mock_resource "aws_iam_openid_connect_provider" {
    defaults = {
      arn = "arn:aws:iam::${join("", ["0000", "0000", "0000"])}:oidc-provider/token.actions.githubusercontent.com"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn                   = "arn:aws:iam::${join("", ["0000", "0000", "0000"])}:role/mock-role"
      force_detach_policies = false
      name_prefix           = null
      path                  = "/"
    }
  }

  mock_resource "aws_budgets_budget" {
    defaults = {
      arn = "arn:aws:budgets::${join("", ["0000", "0000", "0000"])}:budget/opensearch-lab-monthly-cost"
    }
  }

  mock_resource "aws_s3_bucket_lifecycle_configuration" {
    defaults = {
      transition_default_minimum_object_size = "all_storage_classes_128K"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json          = jsonencode({ Version = "2012-10-17", Statement = [] })
      minified_json = jsonencode({ Version = "2012-10-17", Statement = [] })
    }
  }
}

provider "aws" {
  alias  = "policy_documents"
  region = "eu-west-1"

  access_key                  = substr(sha256("offline Terraform security-contract test"), 0, 16)
  secret_key                  = sha256("offline Terraform security-contract test")
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true

  endpoints {
    budgets = "http://127.0.0.1:9"
    iam     = "http://127.0.0.1:9"
    s3      = "http://127.0.0.1:9"
    sts     = "http://127.0.0.1:9"
  }
}

override_data {
  target          = data.aws_caller_identity.current
  override_during = plan
  values = {
    account_id = join("", ["0000", "0000", "0000"])
    arn        = "arn:aws:iam::${join("", ["0000", "0000", "0000"])}:user/opensearch-lab-bootstrap"
    user_id    = "test-bootstrap-user"
  }
}

override_data {
  target          = data.aws_partition.current
  override_during = plan
  values = {
    partition          = "aws"
    dns_suffix         = "amazonaws.com"
    reverse_dns_prefix = "com.amazonaws"
  }
}

override_data {
  target          = data.aws_iam_user.bootstrap
  override_during = plan
  values = {
    arn       = "arn:aws:iam::${join("", ["0000", "0000", "0000"])}:user/opensearch-lab-bootstrap"
    user_name = "opensearch-lab-bootstrap"
  }
}

run "create_mock_state" {
  command = apply

  providers = {
    aws = aws.setup
  }

  variables {
    budget_notification_email = "alerts@example.com"
  }

  # Seed prior state only. Assertions decode the policy planned from the module.
  override_data {
    target = data.aws_iam_policy_document.terraform_admin_trust
    values = {
      json = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Sid       = "AllowExactBootstrapUser"
          Effect    = "Allow"
          Action    = "sts:AssumeRole"
          Principal = { AWS = "arn:aws:iam::${join("", ["0000", "0000", "0000"])}:user/opensearch-lab-bootstrap" }
          Condition = { ArnLike = { "aws:SignInSessionArn" = "arn:aws:signin:*:${join("", ["0000", "0000", "0000"])}:session/*" } }
        }]
      })
    }
  }

  override_resource {
    target = aws_iam_role.terraform_admin
    values = {
      arn                   = "arn:aws:iam::${join("", ["0000", "0000", "0000"])}:role/opensearch-lab-terraform-admin"
      force_detach_policies = false
      id                    = "opensearch-lab-terraform-admin"
      name_prefix           = null
      path                  = "/"
    }
  }

  override_resource {
    target = aws_iam_role.github_actions
    values = {
      arn                   = "arn:aws:iam::${join("", ["0000", "0000", "0000"])}:role/opensearch-lab-github-actions"
      force_detach_policies = false
      id                    = "opensearch-lab-github-actions"
      name_prefix           = null
      path                  = "/"
    }
  }
}

run "github_oidc_trust_is_exact" {
  command = plan

  providers = {
    aws = aws.policy_documents
  }

  plan_options {
    refresh = false
  }

  variables {
    budget_notification_email = "alerts@example.com"
  }

  assert {
    condition = (
      aws_iam_openid_connect_provider.github.url == "https://token.actions.githubusercontent.com" &&
      toset(aws_iam_openid_connect_provider.github.client_id_list) == toset(["sts.amazonaws.com"])
    )
    error_message = "The GitHub OIDC provider must expose only the exact token URL and STS audience."
  }

  assert {
    condition = (
      length(jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement) == 1 &&
      jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity" &&
      jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Principal.Federated == aws_iam_openid_connect_provider.github.arn &&
      length(keys(jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Principal)) == 1 &&
      jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com" &&
      jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:ocdaithi@321047870/opensearch-operator-reliability-lab@1346323330:environment:aws-bootstrap" &&
      length(keys(jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Condition)) == 1 &&
      length(keys(jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Condition.StringEquals)) == 2 &&
      !strcontains(jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"], "*")
    )
    error_message = "The GitHub role trust must require the exact immutable repository environment subject and STS audience without wildcards."
  }
}

run "github_state_access_is_exact" {
  command = plan

  providers = {
    aws = aws.policy_documents
  }

  plan_options {
    refresh = false
  }

  variables {
    budget_notification_email = "alerts@example.com"
  }

  assert {
    condition = (
      aws_iam_role.github_actions.name == "opensearch-lab-github-actions" &&
      length(aws_iam_role.github_actions.managed_policy_arns) == 0 &&
      length(aws_iam_role.github_actions.inline_policy) == 0 &&
      aws_iam_role_policy.github_actions_state.name == "opensearch-lab-bootstrap-state" &&
      aws_iam_role_policy.github_actions_state.role == aws_iam_role.github_actions.id &&
      length(jsondecode(aws_iam_role_policy.github_actions_state.policy).Statement) == 3 &&
      alltrue([for statement in jsondecode(aws_iam_role_policy.github_actions_state.policy).Statement : statement.Effect == "Allow"]) &&
      toset([for statement in jsondecode(aws_iam_role_policy.github_actions_state.policy).Statement : statement.Sid]) == toset([
        "ListExactTerraformStateKeys",
        "ReadAndWriteTerraformState",
        "ManageTerraformStateLock",
      ])
    )
    error_message = "The GitHub state policy must contain only the three reviewed statements."
  }

  assert {
    condition = (
      one([for statement in jsondecode(aws_iam_role_policy.github_actions_state.policy).Statement : statement if statement.Sid == "ListExactTerraformStateKeys"]).Action == "s3:ListBucket" &&
      one([for statement in jsondecode(aws_iam_role_policy.github_actions_state.policy).Statement : statement if statement.Sid == "ListExactTerraformStateKeys"]).Resource == aws_s3_bucket.state.arn &&
      toset(one([for statement in jsondecode(aws_iam_role_policy.github_actions_state.policy).Statement : statement if statement.Sid == "ListExactTerraformStateKeys"]).Condition.StringEquals["s3:prefix"]) == toset([
        "bootstrap/terraform.tfstate",
        "bootstrap/terraform.tfstate.tflock",
      ])
    )
    error_message = "The GitHub state policy must list only the exact state and lock keys."
  }

  assert {
    condition = (
      toset(one([for statement in jsondecode(aws_iam_role_policy.github_actions_state.policy).Statement : statement if statement.Sid == "ReadAndWriteTerraformState"]).Action) == toset([
        "s3:GetObject",
        "s3:PutObject",
      ]) &&
      one([for statement in jsondecode(aws_iam_role_policy.github_actions_state.policy).Statement : statement if statement.Sid == "ReadAndWriteTerraformState"]).Resource == "${aws_s3_bucket.state.arn}/bootstrap/terraform.tfstate"
    )
    error_message = "The Terraform state object must permit only read and write access, never deletion."
  }

  assert {
    condition = (
      toset(one([for statement in jsondecode(aws_iam_role_policy.github_actions_state.policy).Statement : statement if statement.Sid == "ManageTerraformStateLock"]).Action) == toset([
        "s3:DeleteObject",
        "s3:GetObject",
        "s3:PutObject",
      ]) &&
      one([for statement in jsondecode(aws_iam_role_policy.github_actions_state.policy).Statement : statement if statement.Sid == "ManageTerraformStateLock"]).Resource == "${aws_s3_bucket.state.arn}/bootstrap/terraform.tfstate.tflock"
    )
    error_message = "DeleteObject must apply only to the exact Terraform lock object."
  }
}

run "human_access_is_exact" {
  command = plan

  providers = {
    aws = aws.policy_documents
  }

  plan_options {
    refresh = false
  }

  variables {
    budget_notification_email = "alerts@example.com"
  }

  assert {
    condition = (
      aws_iam_role.terraform_admin.name == "opensearch-lab-terraform-admin" &&
      data.aws_iam_user.bootstrap.user_name == "opensearch-lab-bootstrap" &&
      length(jsondecode(aws_iam_role.terraform_admin.assume_role_policy).Statement) == 1 &&
      jsondecode(aws_iam_role.terraform_admin.assume_role_policy).Statement[0].Action == "sts:AssumeRole" &&
      jsondecode(aws_iam_role.terraform_admin.assume_role_policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_role.terraform_admin.assume_role_policy).Statement[0].Principal.AWS == data.aws_iam_user.bootstrap.arn &&
      length(keys(jsondecode(aws_iam_role.terraform_admin.assume_role_policy).Statement[0].Principal)) == 1 &&
      jsondecode(aws_iam_role.terraform_admin.assume_role_policy).Statement[0].Condition.ArnLike["aws:SignInSessionArn"] == "arn:aws:signin:*:${data.aws_caller_identity.current.account_id}:session/*" &&
      length(keys(jsondecode(aws_iam_role.terraform_admin.assume_role_policy).Statement[0].Condition)) == 1 &&
      length(keys(jsondecode(aws_iam_role.terraform_admin.assume_role_policy).Statement[0].Condition.ArnLike)) == 1
    )
    error_message = "The human role trust must allow only the named bootstrap user through an AWS Sign-In session."
  }

  assert {
    condition = (
      aws_iam_user_policy.bootstrap_user_assume_role.user == data.aws_iam_user.bootstrap.user_name &&
      length(jsondecode(aws_iam_user_policy.bootstrap_user_assume_role.policy).Statement) == 1 &&
      jsondecode(aws_iam_user_policy.bootstrap_user_assume_role.policy).Statement[0].Action == "sts:AssumeRole" &&
      jsondecode(aws_iam_user_policy.bootstrap_user_assume_role.policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_user_policy.bootstrap_user_assume_role.policy).Statement[0].Resource == aws_iam_role.terraform_admin.arn
    )
    error_message = "The persistent bootstrap-user policy must allow only assumption of the exact human administration role."
  }
}

run "budget_contract_is_exact" {
  command = plan

  providers = {
    aws = aws.policy_documents
  }

  plan_options {
    refresh = false
  }

  variables {
    budget_notification_email = "alerts@example.com"
  }

  assert {
    condition = (
      aws_budgets_budget.account_cost.budget_type == "COST" &&
      aws_budgets_budget.account_cost.limit_amount == "50" &&
      aws_budgets_budget.account_cost.limit_unit == "USD" &&
      aws_budgets_budget.account_cost.time_unit == "MONTHLY" &&
      toset(aws_budgets_budget.account_cost.metrics) == toset(["UnblendedCost"])
    )
    error_message = "The account budget must remain a monthly USD 50 unblended-cost budget."
  }

  assert {
    condition = (
      length(one(aws_budgets_budget.account_cost.filter_expression).not) == 1 &&
      length(one(aws_budgets_budget.account_cost.filter_expression).not[0].dimensions) == 1 &&
      one(aws_budgets_budget.account_cost.filter_expression).not[0].dimensions[0].key == "RECORD_TYPE" &&
      toset(one(aws_budgets_budget.account_cost.filter_expression).not[0].dimensions[0].values) == toset(["Credit", "Refund"])
    )
    error_message = "The account budget must exclude only Credit and Refund record types."
  }

  assert {
    condition = (
      length(aws_budgets_budget.account_cost.notification) == 5 &&
      toset([for notification in aws_budgets_budget.account_cost.notification : notification.threshold if notification.notification_type == "ACTUAL"]) == toset([10, 25, 40, 50]) &&
      length([
        for notification in aws_budgets_budget.account_cost.notification : notification
        if notification.notification_type == "FORECASTED" && notification.threshold == 50
      ]) == 1 &&
      alltrue([
        for notification in aws_budgets_budget.account_cost.notification :
        notification.comparison_operator == "GREATER_THAN" &&
        notification.threshold_type == "ABSOLUTE_VALUE" &&
        toset(notification.subscriber_email_addresses) == toset(["alerts@example.com"])
      ])
    )
    error_message = "The budget must keep the four actual USD thresholds and one USD 50 forecast alert."
  }
}

run "state_bucket_contract_is_exact" {
  command = plan

  providers = {
    aws = aws.policy_documents
  }

  plan_options {
    refresh = false
  }

  variables {
    budget_notification_email = "alerts@example.com"
  }

  assert {
    condition = (
      aws_s3_bucket.state.force_destroy == false &&
      one(aws_s3_bucket_versioning.state.versioning_configuration).status == "Enabled" &&
      one(one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    )
    error_message = "The state bucket must resist bulk deletion and use versioning with AES256 encryption."
  }

  assert {
    condition = (
      aws_s3_bucket_public_access_block.state.block_public_acls &&
      aws_s3_bucket_public_access_block.state.block_public_policy &&
      aws_s3_bucket_public_access_block.state.ignore_public_acls &&
      aws_s3_bucket_public_access_block.state.restrict_public_buckets
    )
    error_message = "All four S3 public-access blocking controls must remain enabled."
  }

  assert {
    condition = (
      length(aws_s3_bucket_lifecycle_configuration.state.rule) == 1 &&
      one(aws_s3_bucket_lifecycle_configuration.state.rule).id == "retain-recent-noncurrent-state" &&
      one(aws_s3_bucket_lifecycle_configuration.state.rule).status == "Enabled" &&
      one(one(aws_s3_bucket_lifecycle_configuration.state.rule).noncurrent_version_expiration).newer_noncurrent_versions == 10 &&
      one(one(aws_s3_bucket_lifecycle_configuration.state.rule).noncurrent_version_expiration).noncurrent_days == 90 &&
      length(one(aws_s3_bucket_lifecycle_configuration.state.rule).expiration) == 0 &&
      length(one(aws_s3_bucket_lifecycle_configuration.state.rule).transition) == 0 &&
      length(one(aws_s3_bucket_lifecycle_configuration.state.rule).noncurrent_version_transition) == 0
    )
    error_message = "The state lifecycle must retain ten newer non-current versions and expire older versions after 90 days."
  }

  assert {
    condition = (
      length(jsondecode(aws_s3_bucket_policy.state.policy).Statement) == 1 &&
      jsondecode(aws_s3_bucket_policy.state.policy).Statement[0].Effect == "Deny" &&
      jsondecode(aws_s3_bucket_policy.state.policy).Statement[0].Action == "s3:*" &&
      jsondecode(aws_s3_bucket_policy.state.policy).Statement[0].Principal == "*" &&
      jsondecode(aws_s3_bucket_policy.state.policy).Statement[0].Condition.Bool["aws:SecureTransport"] == "false" &&
      toset(keys(jsondecode(aws_s3_bucket_policy.state.policy).Statement[0].Condition)) == toset(["Bool"]) &&
      toset(keys(jsondecode(aws_s3_bucket_policy.state.policy).Statement[0].Condition.Bool)) == toset(["aws:SecureTransport"]) &&
      toset(jsondecode(aws_s3_bucket_policy.state.policy).Statement[0].Resource) == toset([
        aws_s3_bucket.state.arn,
        "${aws_s3_bucket.state.arn}/*",
      ])
    )
    error_message = "The state bucket policy must deny every insecure transport request to the bucket and its objects."
  }
}
