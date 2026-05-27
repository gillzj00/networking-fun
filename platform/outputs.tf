output "demo_log_group_name" {
  description = "Name of the trivial CloudWatch log group managed by the platform layer."
  value       = aws_cloudwatch_log_group.platform_demo.name
}

output "demo_log_group_arn" {
  description = "ARN of the trivial CloudWatch log group managed by the platform layer."
  value       = aws_cloudwatch_log_group.platform_demo.arn
}

output "janitor_function_name" {
  description = "Name of the janitor Lambda function."
  value       = aws_lambda_function.janitor.function_name
}

output "janitor_function_arn" {
  description = "ARN of the janitor Lambda function."
  value       = aws_lambda_function.janitor.arn
}

output "alerts_topic_arn" {
  description = "SNS topic ARN that receives platform-layer alarms; email subscription requires manual confirmation."
  value       = aws_sns_topic.alerts.arn
}

output "monthly_budget_name" {
  description = "Name of the account-wide monthly AWS Budget."
  value       = aws_budgets_budget.monthly.name
}

output "terratest_budget_name" {
  description = "Name of the Terratest-tagged AWS Budget."
  value       = aws_budgets_budget.terratest.name
}

output "labs_zone_id" {
  description = "Route53 zone ID for the delegated labs subdomain."
  value       = aws_route53_zone.labs.zone_id
}

output "labs_zone_name_servers" {
  description = "NS records for the delegated labs zone. Copy these into the parent gillzhub.com zone in the management account to complete delegation."
  value       = aws_route53_zone.labs.name_servers
}

output "labs_wildcard_certificate_arn" {
  description = "ARN of the *.labs wildcard ACM cert. Will be in PENDING_VALIDATION until parent-zone NS delegation is in place and enable_acm_validation is set."
  value       = aws_acm_certificate.labs_wildcard.arn
}
