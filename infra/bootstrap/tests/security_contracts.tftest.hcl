mock_provider "aws" {
  alias           = "setup"
  override_during = plan

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn    = "arn:aws:s3:::example-terraform-state-bucket"
      bucket = "example-terraform-state-bucket"
      id     = "example-terraform-state-bucket"
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

variables {
  expected_aws_account_id   = join("", ["0000", "0000", "0000"])
  aws_region                = "eu-west-1"
  state_bucket_name         = "example-terraform-state-bucket"
  budget_notification_email = "alerts@example.invalid"
  github_owner              = "example-owner"
  github_owner_id           = "12345"
  github_repository         = "example-repository"
  github_repository_id      = "67890"
  github_environment        = "aws-bootstrap"
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

run "reject_malformed_account_id" {
  command = plan

  providers = {
    aws = aws.policy_documents
  }

  variables {
    expected_aws_account_id = "invalid"
  }

  expect_failures = [var.expected_aws_account_id]
}

run "reject_malformed_region" {
  command = plan

  providers = {
    aws = aws.policy_documents
  }

  variables {
    aws_region = "global"
  }

  expect_failures = [var.aws_region]
}

run "reject_noncommercial_region" {
  command = plan

  providers = {
    aws = aws.policy_documents
  }

  variables {
    aws_region = "cn-north-1"
  }

  expect_failures = [var.aws_region]
}

run "reject_malformed_state_bucket" {
  command = plan

  providers = {
    aws = aws.policy_documents
  }

  variables {
    state_bucket_name = "Invalid_Bucket"
  }

  expect_failures = [var.state_bucket_name]
}

run "reject_malformed_budget_email" {
  command = plan

  providers = {
    aws = aws.policy_documents
  }

  variables {
    budget_notification_email = "invalid"
  }

  expect_failures = [var.budget_notification_email]
}

run "reject_wildcard_github_owner" {
  command = plan

  providers = {
    aws = aws.policy_documents
  }

  variables {
    github_owner = "*"
  }

  expect_failures = [var.github_owner]
}

run "reject_malformed_github_owner_id" {
  command = plan

  providers = {
    aws = aws.policy_documents
  }

  variables {
    github_owner_id = "owner-id"
  }

  expect_failures = [var.github_owner_id]
}

run "reject_wildcard_github_repository" {
  command = plan

  providers = {
    aws = aws.policy_documents
  }

  variables {
    github_repository = "*"
  }

  expect_failures = [var.github_repository]
}

run "reject_malformed_github_repository_id" {
  command = plan

  providers = {
    aws = aws.policy_documents
  }

  variables {
    github_repository_id = "repository-id"
  }

  expect_failures = [var.github_repository_id]
}

run "reject_unsafe_github_environment" {
  command = plan

  providers = {
    aws = aws.policy_documents
  }

  variables {
    github_environment = "environment:*"
  }

  expect_failures = [var.github_environment]
}

run "reject_noncommercial_partition" {
  command = plan

  providers = {
    aws = aws.policy_documents
  }

  override_data {
    target = data.aws_partition.current
    values = {
      partition          = "aws-cn"
      dns_suffix         = "amazonaws.com.cn"
      reverse_dns_prefix = "cn.com.amazonaws"
    }
  }

  expect_failures = [aws_s3_bucket.state]
}

run "accept_valid_runtime_inputs" {
  command = plan

  providers = {
    aws = aws.policy_documents
  }

  plan_options {
    refresh = false
  }

  assert {
    condition = (
      aws_s3_bucket.state.bucket == var.state_bucket_name &&
      aws_budgets_budget.account_cost.account_id == var.expected_aws_account_id &&
      local.github_subject == "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repository}@${var.github_repository_id}:environment:${var.github_environment}"
    )
    error_message = "Valid runtime inputs must bind the exact account, state bucket and immutable GitHub OIDC subject."
  }
}

run "alternate_valid_runtime_inputs_flow_exactly" {
  command = plan

  providers = {
    aws = aws.policy_documents
  }

  variables {
    expected_aws_account_id   = join("", ["1111", "1111", "1111"])
    aws_region                = "us-east-2"
    state_bucket_name         = "alternate-terraform-state-bucket"
    budget_notification_email = "alternate-alerts@example.invalid"
    github_owner              = "alternate-owner"
    github_owner_id           = "54321"
    github_repository         = "alternate-repository"
    github_repository_id      = "98765"
    github_environment        = "alternate-bootstrap"
  }

  plan_options {
    refresh = false
  }

  assert {
    condition = nonsensitive(
      aws_s3_bucket.state.bucket == "alternate-terraform-state-bucket" &&
      local.state_bucket_arn == "arn:aws:s3:::alternate-terraform-state-bucket" &&
      aws_budgets_budget.account_cost.account_id == var.expected_aws_account_id &&
      alltrue([
        for notification in aws_budgets_budget.account_cost.notification :
        toset(notification.subscriber_email_addresses) == toset(["alternate-alerts@example.invalid"])
      ]) &&
      aws_iam_role.terraform_admin.permissions_boundary == "arn:aws:iam::${var.expected_aws_account_id}:policy/opensearch-lab-terraform-admin-boundary" &&
      aws_iam_role.github_actions.permissions_boundary == "arn:aws:iam::${var.expected_aws_account_id}:policy/opensearch-lab-github-actions-boundary" &&
      jsondecode(aws_iam_role.terraform_admin.assume_role_policy).Statement[0].Condition.ArnLike["aws:SignInSessionArn"] == "arn:aws:signin:*:${var.expected_aws_account_id}:session/*" &&
      jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:alternate-owner@54321/alternate-repository@98765:environment:alternate-bootstrap" &&
      one([
        for statement in jsondecode(aws_iam_role_policy.github_actions_state.policy).Statement : statement
        if statement.Sid == "ReadAndWriteTerraformState"
      ]).Resource == "arn:aws:s3:::alternate-terraform-state-bucket/bootstrap/terraform.tfstate" &&
      one([
        for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement
        if statement.Sid == "DeleteReviewedTemporaryBootstrapPolicy"
      ]).Resource == "arn:aws:iam::${var.expected_aws_account_id}:policy/opensearch-lab-temporary-bootstrap"
    )
    error_message = "Alternate valid inputs must flow into every account, bucket, budget and GitHub identity boundary."
  }
}

run "create_mock_state" {
  command = apply

  providers = {
    aws = aws.setup
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

  override_data {
    target = data.aws_iam_policy_document.github_actions_trust
    values = {
      json = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Sid       = "AllowExactRepositoryEnvironment"
          Effect    = "Allow"
          Action    = "sts:AssumeRoleWithWebIdentity"
          Principal = { Federated = "arn:aws:iam::${join("", ["0000", "0000", "0000"])}:oidc-provider/token.actions.githubusercontent.com" }
          Condition = {
            StringEquals = {
              "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
              "token.actions.githubusercontent.com:sub" = "repo:example-owner@12345/example-repository@67890:environment:aws-bootstrap"
            }
          }
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
      permissions_boundary  = "arn:aws:iam::${join("", ["0000", "0000", "0000"])}:policy/opensearch-lab-terraform-admin-boundary"
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
      permissions_boundary  = "arn:aws:iam::${join("", ["0000", "0000", "0000"])}:policy/opensearch-lab-github-actions-boundary"
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

  assert {
    condition = (
      aws_iam_openid_connect_provider.github.url == "https://token.actions.githubusercontent.com" &&
      toset(aws_iam_openid_connect_provider.github.client_id_list) == toset(["sts.amazonaws.com"]) &&
      length(aws_iam_openid_connect_provider.github.client_id_list) == 1
    )
    error_message = "The GitHub OIDC provider must expose only the exact token URL and STS audience."
  }

  assert {
    condition = (
      jsondecode(aws_iam_role.github_actions.assume_role_policy).Version == "2012-10-17" &&
      toset(keys(jsondecode(aws_iam_role.github_actions.assume_role_policy))) == toset(["Statement", "Version"]) &&
      length(jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement) == 1 &&
      jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity" &&
      jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Sid == "AllowExactRepositoryEnvironment" &&
      jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Principal.Federated == aws_iam_openid_connect_provider.github.arn &&
      length(keys(jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Principal)) == 1 &&
      jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com" &&
      jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repository}@${var.github_repository_id}:environment:${var.github_environment}" &&
      length(keys(jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Condition)) == 1 &&
      length(keys(jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Condition.StringEquals)) == 2 &&
      !strcontains(jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"], "*") &&
      toset(keys(jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0])) == toset([
        "Action",
        "Condition",
        "Effect",
        "Principal",
        "Sid",
      ]) &&
      !contains(keys(jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0]), "NotAction") &&
      !contains(keys(jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0]), "NotResource")
    )
    error_message = "The GitHub role trust must require the exact immutable repository environment subject and STS audience without wildcards."
  }

  assert {
    condition = jsondecode(data.aws_iam_policy_document.github_actions_trust.json) == jsondecode(jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid       = "AllowExactRepositoryEnvironment"
        Effect    = "Allow"
        Action    = "sts:AssumeRoleWithWebIdentity"
        Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repository}@${var.github_repository_id}:environment:${var.github_environment}"
          }
        }
      }]
    }))
    error_message = "The raw GitHub trust-policy document must match the exact reviewed contract."
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

  assert {
    condition = nonsensitive(
      aws_iam_role.github_actions.name == "opensearch-lab-github-actions" &&
      nonsensitive(aws_iam_role.github_actions.permissions_boundary) == "arn:aws:iam::${var.expected_aws_account_id}:policy/opensearch-lab-github-actions-boundary" &&
      aws_iam_role.github_actions.max_session_duration == 3600 &&
      length(aws_iam_role.github_actions.managed_policy_arns) == 0 &&
      length(aws_iam_role.github_actions.inline_policy) == 0
    )
    error_message = "The GitHub Actions role must use its exact boundary and contain no embedded or attached managed policy."
  }

  assert {
    condition = (
      aws_iam_role_policy.github_actions_state.name == "opensearch-lab-bootstrap-state" &&
      aws_iam_role_policy.github_actions_state.role == aws_iam_role.github_actions.id &&
      jsondecode(aws_iam_role_policy.github_actions_state.policy).Version == "2012-10-17" &&
      toset(keys(jsondecode(aws_iam_role_policy.github_actions_state.policy))) == toset(["Statement", "Version"]) &&
      length(jsondecode(aws_iam_role_policy.github_actions_state.policy).Statement) == 3 &&
      alltrue([for statement in jsondecode(aws_iam_role_policy.github_actions_state.policy).Statement : statement.Effect == "Allow"]) &&
      toset([for statement in jsondecode(aws_iam_role_policy.github_actions_state.policy).Statement : statement.Sid]) == toset([
        "ListExactTerraformStateKeys",
        "ReadAndWriteTerraformState",
        "ManageTerraformStateLock",
      ]) &&
      alltrue([
        for statement in jsondecode(aws_iam_role_policy.github_actions_state.policy).Statement :
        !contains(keys(statement), "NotAction") &&
        !contains(keys(statement), "NotResource") &&
        alltrue([for action in try(tolist(statement.Action), [statement.Action]) : !strcontains(action, "*")]) &&
        alltrue([for resource in try(tolist(statement.Resource), [statement.Resource]) : resource != "*"])
      ])
    )
    error_message = "The GitHub state policy must contain only the three reviewed statements."
  }

  assert {
    condition = (
      one([for statement in jsondecode(aws_iam_role_policy.github_actions_state.policy).Statement : statement if statement.Sid == "ListExactTerraformStateKeys"]).Action == "s3:ListBucket" &&
      one([for statement in jsondecode(aws_iam_role_policy.github_actions_state.policy).Statement : statement if statement.Sid == "ListExactTerraformStateKeys"]).Resource == aws_s3_bucket.state.arn &&
      toset(keys(one([for statement in jsondecode(aws_iam_role_policy.github_actions_state.policy).Statement : statement if statement.Sid == "ListExactTerraformStateKeys"]))) == toset(["Action", "Condition", "Effect", "Resource", "Sid"]) &&
      toset(keys(one([for statement in jsondecode(aws_iam_role_policy.github_actions_state.policy).Statement : statement if statement.Sid == "ListExactTerraformStateKeys"]).Condition)) == toset(["StringEquals"]) &&
      toset(keys(one([for statement in jsondecode(aws_iam_role_policy.github_actions_state.policy).Statement : statement if statement.Sid == "ListExactTerraformStateKeys"]).Condition.StringEquals)) == toset(["s3:prefix"]) &&
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
      one([for statement in jsondecode(aws_iam_role_policy.github_actions_state.policy).Statement : statement if statement.Sid == "ReadAndWriteTerraformState"]).Resource == "${aws_s3_bucket.state.arn}/bootstrap/terraform.tfstate" &&
      toset(keys(one([for statement in jsondecode(aws_iam_role_policy.github_actions_state.policy).Statement : statement if statement.Sid == "ReadAndWriteTerraformState"]))) == toset(["Action", "Effect", "Resource", "Sid"])
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
      one([for statement in jsondecode(aws_iam_role_policy.github_actions_state.policy).Statement : statement if statement.Sid == "ManageTerraformStateLock"]).Resource == "${aws_s3_bucket.state.arn}/bootstrap/terraform.tfstate.tflock" &&
      toset(keys(one([for statement in jsondecode(aws_iam_role_policy.github_actions_state.policy).Statement : statement if statement.Sid == "ManageTerraformStateLock"]))) == toset(["Action", "Effect", "Resource", "Sid"])
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

  assert {
    condition = nonsensitive(
      aws_iam_role.terraform_admin.name == "opensearch-lab-terraform-admin" &&
      nonsensitive(aws_iam_role.terraform_admin.permissions_boundary) == "arn:aws:iam::${var.expected_aws_account_id}:policy/opensearch-lab-terraform-admin-boundary" &&
      aws_iam_role.terraform_admin.max_session_duration == 3600 &&
      length(aws_iam_role.terraform_admin.managed_policy_arns) == 0 &&
      length(aws_iam_role.terraform_admin.inline_policy) == 0
    )
    error_message = "The human administration role must use its exact boundary and contain no embedded or attached managed policy."
  }

  assert {
    condition = (
      data.aws_iam_user.bootstrap.user_name == "opensearch-lab-bootstrap" &&
      jsondecode(aws_iam_role.terraform_admin.assume_role_policy).Version == "2012-10-17" &&
      toset(keys(jsondecode(aws_iam_role.terraform_admin.assume_role_policy))) == toset(["Statement", "Version"]) &&
      length(jsondecode(aws_iam_role.terraform_admin.assume_role_policy).Statement) == 1 &&
      jsondecode(aws_iam_role.terraform_admin.assume_role_policy).Statement[0].Action == "sts:AssumeRole" &&
      jsondecode(aws_iam_role.terraform_admin.assume_role_policy).Statement[0].Sid == "AllowExactBootstrapUser" &&
      jsondecode(aws_iam_role.terraform_admin.assume_role_policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_role.terraform_admin.assume_role_policy).Statement[0].Principal.AWS == data.aws_iam_user.bootstrap.arn &&
      length(keys(jsondecode(aws_iam_role.terraform_admin.assume_role_policy).Statement[0].Principal)) == 1 &&
      jsondecode(aws_iam_role.terraform_admin.assume_role_policy).Statement[0].Condition.ArnLike["aws:SignInSessionArn"] == "arn:aws:signin:*:${var.expected_aws_account_id}:session/*" &&
      length(keys(jsondecode(aws_iam_role.terraform_admin.assume_role_policy).Statement[0].Condition)) == 1 &&
      length(keys(jsondecode(aws_iam_role.terraform_admin.assume_role_policy).Statement[0].Condition.ArnLike)) == 1 &&
      toset(keys(jsondecode(aws_iam_role.terraform_admin.assume_role_policy).Statement[0])) == toset([
        "Action",
        "Condition",
        "Effect",
        "Principal",
        "Sid",
      ]) &&
      !contains(keys(jsondecode(aws_iam_role.terraform_admin.assume_role_policy).Statement[0]), "NotAction") &&
      !contains(keys(jsondecode(aws_iam_role.terraform_admin.assume_role_policy).Statement[0]), "NotResource")
    )
    error_message = "The human role trust must allow only the named bootstrap user through an AWS Sign-In session."
  }

  assert {
    condition = jsondecode(data.aws_iam_policy_document.terraform_admin_trust.json) == jsondecode(jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid       = "AllowExactBootstrapUser"
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { AWS = data.aws_iam_user.bootstrap.arn }
        Condition = {
          ArnLike = {
            "aws:SignInSessionArn" = "arn:aws:signin:*:${var.expected_aws_account_id}:session/*"
          }
        }
      }]
    }))
    error_message = "The raw human trust-policy document must match the exact reviewed contract."
  }

  assert {
    condition = (
      aws_iam_role_policy.terraform_admin.name == "opensearch-lab-bootstrap-management" &&
      aws_iam_role_policy.terraform_admin.role == aws_iam_role.terraform_admin.id
    )
    error_message = "The human role must have exactly its reviewed separately managed inline policy."
  }
}

run "terraform_admin_policy_is_exact" {
  command = plan

  providers = {
    aws = aws.policy_documents
  }

  plan_options {
    refresh = false
  }

  assert {
    condition = (
      jsondecode(aws_iam_role_policy.terraform_admin.policy).Version == "2012-10-17" &&
      toset(keys(jsondecode(aws_iam_role_policy.terraform_admin.policy))) == toset(["Statement", "Version"]) &&
      length(jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement) == 11 &&
      toset([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement.Sid]) == toset([
        "AuditExactBootstrapUser",
        "DeleteReviewedTemporaryBootstrapPolicy",
        "DetachReviewedTemporaryBootstrapPolicy",
        "ManageBootstrapBudget",
        "ManageStateBucketControls",
        "ManageTerraformStateLock",
        "ReadAndWriteTerraformState",
        "ReadDefaultBillingViewData",
        "ReadExactBootstrapRoles",
        "ReadExactGitHubOIDCProvider",
        "ReadExactPermissionsBoundaries",
      ]) &&
      alltrue([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement.Effect == "Allow"]) &&
      alltrue([
        for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement :
        !contains(keys(statement), "NotAction") &&
        !contains(keys(statement), "NotResource") &&
        alltrue([for action in try(tolist(statement.Action), [statement.Action]) : !strcontains(action, "*")]) &&
        alltrue([for resource in try(tolist(statement.Resource), [statement.Resource]) : resource != "*"])
      ])
    )
    error_message = "The Terraform administration policy must contain only the eleven reviewed allowing statements without wildcard actions, resources, NotAction or NotResource."
  }

  assert {
    condition = (
      toset(one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "ReadAndWriteTerraformState"]).Action) == toset(["s3:GetObject", "s3:PutObject"]) &&
      one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "ReadAndWriteTerraformState"]).Resource == "${aws_s3_bucket.state.arn}/bootstrap/terraform.tfstate" &&
      toset(keys(one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "ReadAndWriteTerraformState"]))) == toset(["Action", "Effect", "Resource", "Sid"]) &&
      toset(one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "ManageTerraformStateLock"]).Action) == toset(["s3:DeleteObject", "s3:GetObject", "s3:PutObject"]) &&
      one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "ManageTerraformStateLock"]).Resource == "${aws_s3_bucket.state.arn}/bootstrap/terraform.tfstate.tflock" &&
      toset(keys(one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "ManageTerraformStateLock"]))) == toset(["Action", "Effect", "Resource", "Sid"])
    )
    error_message = "The Terraform administration policy must read and write only the state object and may delete only the lock object."
  }

  assert {
    condition = (
      toset(one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "ManageStateBucketControls"]).Action) == toset([
        "s3:GetAccelerateConfiguration",
        "s3:GetBucketAcl",
        "s3:GetBucketCORS",
        "s3:GetBucketLocation",
        "s3:GetBucketLogging",
        "s3:GetBucketObjectLockConfiguration",
        "s3:GetBucketOwnershipControls",
        "s3:GetBucketPolicy",
        "s3:GetBucketPublicAccessBlock",
        "s3:GetBucketRequestPayment",
        "s3:GetBucketVersioning",
        "s3:GetBucketWebsite",
        "s3:GetEncryptionConfiguration",
        "s3:GetLifecycleConfiguration",
        "s3:GetReplicationConfiguration",
        "s3:ListBucket",
        "s3:ListTagsForResource",
        "s3:PutBucketOwnershipControls",
        "s3:PutBucketPublicAccessBlock",
        "s3:PutBucketVersioning",
        "s3:PutEncryptionConfiguration",
        "s3:PutLifecycleConfiguration",
        "s3:TagResource",
        "s3:UntagResource",
      ]) &&
      one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "ManageStateBucketControls"]).Resource == aws_s3_bucket.state.arn &&
      toset(keys(one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "ManageStateBucketControls"]))) == toset(["Action", "Effect", "Resource", "Sid"])
    )
    error_message = "The Terraform administration policy must keep the exact state-bucket control actions and resource."
  }

  assert {
    condition = (
      toset(one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "ManageBootstrapBudget"]).Action) == toset([
        "budgets:ListTagsForResource",
        "budgets:ModifyBudget",
        "budgets:TagResource",
        "budgets:UntagResource",
        "budgets:ViewBudget",
      ]) &&
      one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "ManageBootstrapBudget"]).Resource == "arn:aws:budgets::${var.expected_aws_account_id}:budget/opensearch-lab-monthly-cost" &&
      toset(keys(one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "ManageBootstrapBudget"]))) == toset(["Action", "Effect", "Resource", "Sid"]) &&
      one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "ReadDefaultBillingViewData"]).Action == "billing:GetBillingViewData" &&
      one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "ReadDefaultBillingViewData"]).Resource == "arn:${data.aws_partition.current.partition}:billing::${var.expected_aws_account_id}:billingview/primary" &&
      toset(keys(one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "ReadDefaultBillingViewData"]))) == toset(["Action", "Effect", "Resource", "Sid"])
    )
    error_message = "The Terraform administration policy must keep the exact budget actions and primary billing-view ARN."
  }

  assert {
    condition = (
      toset(one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "ReadExactBootstrapRoles"]).Action) == toset([
        "iam:GetRole",
        "iam:GetRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:ListRolePolicies",
        "iam:ListRoleTags",
      ]) &&
      toset(one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "ReadExactBootstrapRoles"]).Resource) == toset([
        aws_iam_role.terraform_admin.arn,
        aws_iam_role.github_actions.arn,
      ]) &&
      toset(keys(one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "ReadExactBootstrapRoles"]))) == toset(["Action", "Effect", "Resource", "Sid"]) &&
      toset(one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "ReadExactGitHubOIDCProvider"]).Action) == toset([
        "iam:GetOpenIDConnectProvider",
        "iam:ListOpenIDConnectProviderTags",
      ]) &&
      one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "ReadExactGitHubOIDCProvider"]).Resource == aws_iam_openid_connect_provider.github.arn &&
      toset(keys(one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "ReadExactGitHubOIDCProvider"]))) == toset(["Action", "Effect", "Resource", "Sid"])
    )
    error_message = "The Terraform administration policy must keep exact read access to the two roles and GitHub OIDC provider."
  }

  assert {
    condition = (
      toset(one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "AuditExactBootstrapUser"]).Action) == toset([
        "iam:GetUser",
        "iam:ListAccessKeys",
        "iam:ListAttachedUserPolicies",
        "iam:ListGroupsForUser",
        "iam:ListMFADevices",
        "iam:ListUserPolicies",
      ]) &&
      one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "AuditExactBootstrapUser"]).Resource == data.aws_iam_user.bootstrap.arn &&
      toset(keys(one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "AuditExactBootstrapUser"]))) == toset(["Action", "Effect", "Resource", "Sid"]) &&
      toset(one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "ReadExactPermissionsBoundaries"]).Action) == toset(["iam:GetPolicy", "iam:GetPolicyVersion"]) &&
      toset(one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "ReadExactPermissionsBoundaries"]).Resource) == toset([
        "arn:aws:iam::${var.expected_aws_account_id}:policy/opensearch-lab-terraform-admin-boundary",
        "arn:aws:iam::${var.expected_aws_account_id}:policy/opensearch-lab-github-actions-boundary",
      ]) &&
      toset(keys(one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "ReadExactPermissionsBoundaries"]))) == toset(["Action", "Effect", "Resource", "Sid"])
    )
    error_message = "The Terraform administration policy must keep exact user-audit and boundary-read permissions."
  }

  assert {
    condition = (
      one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "DetachReviewedTemporaryBootstrapPolicy"]).Action == "iam:DetachUserPolicy" &&
      one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "DetachReviewedTemporaryBootstrapPolicy"]).Resource == data.aws_iam_user.bootstrap.arn &&
      one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "DetachReviewedTemporaryBootstrapPolicy"]).Condition.ArnEquals["iam:PolicyARN"] == "arn:aws:iam::${var.expected_aws_account_id}:policy/opensearch-lab-temporary-bootstrap" &&
      toset(keys(one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "DetachReviewedTemporaryBootstrapPolicy"]))) == toset(["Action", "Condition", "Effect", "Resource", "Sid"]) &&
      toset(keys(one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "DetachReviewedTemporaryBootstrapPolicy"]).Condition)) == toset(["ArnEquals"]) &&
      toset(keys(one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "DetachReviewedTemporaryBootstrapPolicy"]).Condition.ArnEquals)) == toset(["iam:PolicyARN"]) &&
      toset(one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "DeleteReviewedTemporaryBootstrapPolicy"]).Action) == toset([
        "iam:DeletePolicy",
        "iam:GetPolicy",
        "iam:GetPolicyVersion",
        "iam:ListEntitiesForPolicy",
      ]) &&
      one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "DeleteReviewedTemporaryBootstrapPolicy"]).Resource == "arn:aws:iam::${var.expected_aws_account_id}:policy/opensearch-lab-temporary-bootstrap" &&
      toset(keys(one([for statement in jsondecode(aws_iam_role_policy.terraform_admin.policy).Statement : statement if statement.Sid == "DeleteReviewedTemporaryBootstrapPolicy"]))) == toset(["Action", "Effect", "Resource", "Sid"])
    )
    error_message = "The Terraform administration policy must detach and delete only the reviewed temporary bootstrap policy."
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

  assert {
    condition = (
      aws_budgets_budget.account_cost.name == "opensearch-lab-monthly-cost" &&
      aws_budgets_budget.account_cost.account_id == var.expected_aws_account_id &&
      aws_budgets_budget.account_cost.budget_type == "COST" &&
      aws_budgets_budget.account_cost.limit_amount == "50" &&
      aws_budgets_budget.account_cost.limit_unit == "USD" &&
      aws_budgets_budget.account_cost.time_unit == "MONTHLY" &&
      toset(aws_budgets_budget.account_cost.metrics) == toset(["UnblendedCost"])
    )
    error_message = "The account budget must keep its exact name, account and monthly USD 50 unblended-cost limit."
  }

  assert {
    condition = (
      aws_budgets_budget.account_cost.billing_view_arn == null &&
      length(aws_budgets_budget.account_cost.auto_adjust_data) == 0 &&
      length(aws_budgets_budget.account_cost.planned_limit) == 0 &&
      length(aws_budgets_budget.account_cost.cost_filter) == 0 &&
      length(aws_budgets_budget.account_cost.cost_types) == 0
    )
    error_message = "The planned account budget must not use a billing view, adjustment, planned limit or legacy cost filter."
  }

  assert {
    condition = (
      length(aws_budgets_budget.account_cost.filter_expression) == 1 &&
      length(one(aws_budgets_budget.account_cost.filter_expression).not) == 1 &&
      length(one(aws_budgets_budget.account_cost.filter_expression).and) == 0 &&
      length(one(aws_budgets_budget.account_cost.filter_expression).or) == 0 &&
      length(one(aws_budgets_budget.account_cost.filter_expression).dimensions) == 0 &&
      length(one(aws_budgets_budget.account_cost.filter_expression).tags) == 0 &&
      length(one(aws_budgets_budget.account_cost.filter_expression).cost_categories) == 0 &&
      length(one(aws_budgets_budget.account_cost.filter_expression).not[0].dimensions) == 1 &&
      length(one(aws_budgets_budget.account_cost.filter_expression).not[0].and) == 0 &&
      length(one(aws_budgets_budget.account_cost.filter_expression).not[0].or) == 0 &&
      length(one(aws_budgets_budget.account_cost.filter_expression).not[0].not) == 0 &&
      length(one(aws_budgets_budget.account_cost.filter_expression).not[0].tags) == 0 &&
      length(one(aws_budgets_budget.account_cost.filter_expression).not[0].cost_categories) == 0 &&
      one(aws_budgets_budget.account_cost.filter_expression).not[0].dimensions[0].key == "RECORD_TYPE" &&
      toset(one(aws_budgets_budget.account_cost.filter_expression).not[0].dimensions[0].values) == toset(["Credit", "Refund"]) &&
      length(one(aws_budgets_budget.account_cost.filter_expression).not[0].dimensions[0].match_options) == 0
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
        toset(notification.subscriber_email_addresses) == toset(["alerts@example.invalid"]) &&
        length(notification.subscriber_sns_topic_arns) == 0
      ])
    )
    error_message = "The budget must keep the exact email-only actual and forecast alerts without SNS subscribers."
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

  assert {
    condition = (
      aws_s3_bucket.state.bucket == var.state_bucket_name &&
      aws_s3_bucket.state.force_destroy == false &&
      one(aws_s3_bucket_versioning.state.versioning_configuration).status == "Enabled" &&
      one(one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256" &&
      aws_s3_bucket_versioning.state.bucket == aws_s3_bucket.state.id &&
      aws_s3_bucket_server_side_encryption_configuration.state.bucket == aws_s3_bucket.state.id &&
      aws_s3_bucket_public_access_block.state.bucket == aws_s3_bucket.state.id &&
      aws_s3_bucket_lifecycle_configuration.state.bucket == aws_s3_bucket.state.id &&
      aws_s3_bucket_policy.state.bucket == aws_s3_bucket.state.id
    )
    error_message = "The exact deterministic state bucket must resist bulk deletion and use its reviewed versioning, encryption and control resources."
  }

  assert {
    condition = (
      aws_s3_bucket_ownership_controls.state.bucket == aws_s3_bucket.state.id &&
      length(aws_s3_bucket_ownership_controls.state.rule) == 1 &&
      one(aws_s3_bucket_ownership_controls.state.rule).object_ownership == "BucketOwnerEnforced"
    )
    error_message = "The state bucket must keep its sole BucketOwnerEnforced ownership rule."
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
    condition = nonsensitive(
      length(aws_s3_bucket_lifecycle_configuration.state.rule) == 1 &&
      length(one(aws_s3_bucket_lifecycle_configuration.state.rule).filter) == 1 &&
      one(one(aws_s3_bucket_lifecycle_configuration.state.rule).filter).prefix == "" &&
      length(one(one(aws_s3_bucket_lifecycle_configuration.state.rule).filter).and) == 0 &&
      length(one(one(aws_s3_bucket_lifecycle_configuration.state.rule).filter).tag) == 0
    )
    error_message = "The state lifecycle must cover every object without a narrowing filter."
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
