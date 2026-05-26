output "demo_log_group_name" {
  description = "Name of the trivial CloudWatch log group managed by the platform layer."
  value       = aws_cloudwatch_log_group.platform_demo.name
}

output "demo_log_group_arn" {
  description = "ARN of the trivial CloudWatch log group managed by the platform layer."
  value       = aws_cloudwatch_log_group.platform_demo.arn
}
