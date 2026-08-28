data "aws_iam_policy_document" "terraform_admin_trust" {
  statement {
    sid     = "AllowExactBootstrapUser"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [data.aws_iam_user.bootstrap.arn]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SignInSessionArn"
      values = [
        "arn:${data.aws_partition.current.partition}:signin:*:${var.expected_aws_account_id}:session/*",
      ]
    }
  }
}

resource "aws_iam_role" "terraform_admin" {
  name                 = local.terraform_admin_role_name
  path                 = "/"
  description          = "Manages the reviewed AWS bootstrap foundation through Terraform."
  assume_role_policy   = data.aws_iam_policy_document.terraform_admin_trust.json
  permissions_boundary = local.terraform_admin_boundary_arn
  max_session_duration = 3600
}

data "aws_iam_policy_document" "terraform_admin" {
  source_policy_documents = [data.aws_iam_policy_document.state_object_access.json]

  statement {
    sid    = "ManageStateBucketControls"
    effect = "Allow"
    actions = [
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
    ]
    resources = [local.state_bucket_arn]
  }

  statement {
    sid    = "ManageBootstrapBudget"
    effect = "Allow"
    actions = [
      "budgets:ListTagsForResource",
      "budgets:ModifyBudget",
      "budgets:TagResource",
      "budgets:UntagResource",
      "budgets:ViewBudget",
    ]
    resources = [local.budget_arn]
  }

  statement {
    sid       = "ReadDefaultBillingViewData"
    effect    = "Allow"
    actions   = ["billing:GetBillingViewData"]
    resources = [local.primary_billing_view_arn]
  }

  statement {
    sid    = "ReadExactBootstrapRoles"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:ListRoleTags",
    ]
    resources = [
      aws_iam_role.terraform_admin.arn,
      aws_iam_role.github_actions.arn,
    ]
  }

  statement {
    sid    = "ReadExactGitHubOIDCProvider"
    effect = "Allow"
    actions = [
      "iam:GetOpenIDConnectProvider",
      "iam:ListOpenIDConnectProviderTags",
    ]
    resources = [aws_iam_openid_connect_provider.github.arn]
  }

  statement {
    sid    = "AuditExactBootstrapUser"
    effect = "Allow"
    actions = [
      "iam:GetUser",
      "iam:ListAccessKeys",
      "iam:ListAttachedUserPolicies",
      "iam:ListGroupsForUser",
      "iam:ListMFADevices",
      "iam:ListUserPolicies",
    ]
    resources = [data.aws_iam_user.bootstrap.arn]
  }

  statement {
    sid    = "ReadExactPermissionsBoundaries"
    effect = "Allow"
    actions = [
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
    ]
    resources = [
      local.terraform_admin_boundary_arn,
      local.github_actions_boundary_arn,
    ]
  }

  statement {
    sid       = "DetachReviewedTemporaryBootstrapPolicy"
    effect    = "Allow"
    actions   = ["iam:DetachUserPolicy"]
    resources = [data.aws_iam_user.bootstrap.arn]

    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = [local.temporary_policy_arn]
    }
  }

  statement {
    sid    = "DeleteReviewedTemporaryBootstrapPolicy"
    effect = "Allow"
    actions = [
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListEntitiesForPolicy",
    ]
    resources = [local.temporary_policy_arn]
  }
}

resource "aws_iam_role_policy" "terraform_admin" {
  name   = local.terraform_admin_policy_name
  role   = aws_iam_role.terraform_admin.id
  policy = data.aws_iam_policy_document.terraform_admin.json
}
