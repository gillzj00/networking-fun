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
