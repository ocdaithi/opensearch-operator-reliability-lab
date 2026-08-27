output "state_bucket_name" {
  description = "Name of the durable Terraform state bucket."
  value       = aws_s3_bucket.state.id
  sensitive   = true
}

output "terraform_admin_role_arn" {
  description = "ARN of the Terraform-managed human administration role."
  value       = aws_iam_role.terraform_admin.arn
  sensitive   = true
}

output "github_actions_role_arn" {
  description = "ARN of the GitHub Actions OIDC role."
  value       = aws_iam_role.github_actions.arn
  sensitive   = true
}
