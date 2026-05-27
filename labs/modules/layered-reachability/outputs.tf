output "vpc_id" {
  description = "Lab VPC ID."
  value       = aws_vpc.this.id
}

output "private_subnet_id" {
  description = "ID of the private subnet inside the lab VPC."
  value       = aws_subnet.private.id
}

output "instance_security_group_id" {
  description = "Security group attached to the lab compute instance."
  value       = aws_security_group.instance.id
}

output "instance_id" {
  description = "Lab EC2 instance ID. Use with: aws ssm start-session --target <id>"
  value       = aws_instance.lab.id
}

output "instance_role_arn" {
  description = "ARN of the EC2 instance role."
  value       = aws_iam_role.instance.arn
}

output "ssm_endpoint_ids" {
  description = "Map of SSM family interface endpoint IDs."
  value       = { for k, v in aws_vpc_endpoint.ssm_family : k => v.id }
}

output "flow_log_group_name" {
  description = "CloudWatch log group receiving VPC Flow Logs."
  value       = aws_cloudwatch_log_group.flow_logs.name
}

output "flow_log_group_arn" {
  description = "ARN of the VPC Flow Logs CloudWatch log group."
  value       = aws_cloudwatch_log_group.flow_logs.arn
}
