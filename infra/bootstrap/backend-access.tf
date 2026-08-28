data "aws_iam_policy_document" "state_object_access" {
  statement {
    sid    = "ReadAndWriteTerraformState"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = ["${local.state_bucket_arn}/${local.state_key}"]
  }

  statement {
    sid    = "ManageTerraformStateLock"
    effect = "Allow"
    actions = [
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = ["${local.state_bucket_arn}/${local.lock_key}"]
  }
}

data "aws_iam_policy_document" "state_backend_access" {
  source_policy_documents = [data.aws_iam_policy_document.state_object_access.json]

  statement {
    sid       = "ListExactTerraformStateKeys"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]

    condition {
      test     = "StringEquals"
      variable = "s3:prefix"
      values = [
        local.state_key,
        local.lock_key,
      ]
    }
  }
}
