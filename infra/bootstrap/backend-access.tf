data "aws_iam_policy_document" "state_object_access" {
  statement {
    sid    = "ReadAndWriteTerraformState"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.state.arn}/${local.state_key}"]
  }

  statement {
    sid    = "ManageTerraformStateLock"
    effect = "Allow"
    actions = [
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.state.arn}/${local.state_key}.tflock"]
  }
}

data "aws_iam_policy_document" "state_backend_access" {
  source_policy_documents = [data.aws_iam_policy_document.state_object_access.json]

  statement {
    sid       = "ListExactTerraformStateKeys"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]

    condition {
      test     = "StringEquals"
      variable = "s3:prefix"
      values = [
        local.state_key,
        "${local.state_key}.tflock",
      ]
    }
  }
}
