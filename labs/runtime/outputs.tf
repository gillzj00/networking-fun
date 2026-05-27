output "pr_number" {
  description = "PR that owns this environment."
  value       = var.pr_number
}

output "lab" {
  description = "Lab name."
  value       = var.lab
}

output "scenario" {
  description = "Fault scenario name."
  value       = var.scenario
}

output "ttl_iso" {
  description = "AutoDelete timestamp."
  value       = var.ttl_iso
}

output "region" {
  description = "Region where the lab was provisioned."
  value       = var.region
}

output "vpc_id" {
  description = "Lab VPC ID."
  value       = module.lab.vpc_id
}

output "instance_id" {
  description = "EC2 instance ID. Use with: aws ssm start-session --target <id>"
  value       = module.lab.instance_id
}

output "probe_function_name" {
  description = "Lambda probe function name."
  value       = module.probe.function_name
}

output "probe_log_group" {
  description = "CloudWatch log group for the probe Lambda."
  value       = module.probe.log_group_name
}

output "flow_log_group" {
  description = "CloudWatch log group for VPC Flow Logs."
  value       = module.lab.flow_log_group_name
}
