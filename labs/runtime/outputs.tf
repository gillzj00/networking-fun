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
  value       = local.vpc_id
}

output "instance_id" {
  description = "EC2 instance ID for labs with a single instance. Use with: aws ssm start-session --target <id>. Empty for three-tier-segmentation."
  value       = local.target_instance_id
}

output "instance_ids" {
  description = "Map of tier -> instance ID for the three-tier-segmentation lab. Empty for layered-reachability."
  value       = local.three_tier_active ? module.lab_three_tier[0].instance_ids : {}
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
  value       = local.flow_log_group_name
}
