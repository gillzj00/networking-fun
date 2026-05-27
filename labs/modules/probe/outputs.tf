output "function_name" {
  description = "Lambda function name. Use with: aws lambda invoke --function-name <name> /tmp/out.json"
  value       = aws_lambda_function.probe.function_name
}

output "function_arn" {
  description = "Lambda function ARN."
  value       = aws_lambda_function.probe.arn
}

output "log_group_name" {
  description = "CloudWatch log group receiving probe invocations."
  value       = aws_cloudwatch_log_group.probe.name
}

output "security_group_id" {
  description = "Probe Lambda SG."
  value       = aws_security_group.probe.id
}
