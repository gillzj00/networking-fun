output "tfstate_bucket" {
  description = "S3 bucket holding Terraform state for all networking-fun layers."
  value       = aws_s3_bucket.tfstate.bucket
}

output "tfstate_bucket_region" {
  description = "Region of the Terraform state bucket."
  value       = var.region
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "gha_role_arn" {
  description = "ARN of the role GitHub Actions assumes. Paste into workflow `role-to-assume`."
  value       = aws_iam_role.gha_terraform.arn
}

output "gha_role_name" {
  description = "Name of the role GitHub Actions assumes."
  value       = aws_iam_role.gha_terraform.name
}

output "account_id" {
  description = "AWS account ID where bootstrap was applied (the dev sub-account)."
  value       = data.aws_caller_identity.current.account_id
}
