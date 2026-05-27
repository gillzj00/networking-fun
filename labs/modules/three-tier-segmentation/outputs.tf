output "vpc_id" {
  description = "Lab VPC ID."
  value       = aws_vpc.this.id
}

output "subnet_ids" {
  description = "Map of tier name -> subnet ID."
  value       = { for k, v in aws_subnet.tier : k => v.id }
}

output "tier_security_group_ids" {
  description = "Map of tier name -> SG ID."
  value       = { for k, v in aws_security_group.tier : k => v.id }
}

output "endpoint_security_group_id" {
  description = "SG attached to the SSM family VPC endpoints. The probe Lambda's SG gets an ingress on this SG so it can call SSM."
  value       = aws_security_group.endpoints.id
}

output "instance_ids" {
  description = "Map of tier name -> EC2 instance ID."
  value       = { for k, v in aws_instance.tier : k => v.id }
}

output "instance_private_ips" {
  description = "Map of tier name -> private IP. Probe uses these as targets for nc TCP connects."
  value       = { for k, v in aws_instance.tier : k => v.private_ip }
}

output "instance_role_arn" {
  description = "ARN of the EC2 instance role (shared across tiers)."
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

output "tier_ports" {
  description = "Map of tier name -> service port the probe targets on that tier."
  value = {
    web = 443
    app = 8080
    db  = 5432
  }
}
