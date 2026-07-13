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
  description = "Static lab VPC the service runs in."
  value       = module.lab.vpc_id
}

output "cluster_name" {
  description = "Shared ECS cluster the lab service runs on."
  value       = module.lab.cluster_name
}

output "service_name" {
  description = "Per-PR ECS service name."
  value       = module.lab.service_name
}

output "task_definition_arn" {
  description = "Per-PR task definition ARN."
  value       = module.lab.task_definition_arn
}

output "security_group_id" {
  description = "Per-PR security group on the lab task."
  value       = module.lab.security_group_id
}

output "image" {
  description = "Image URI the task definition pins."
  value       = module.lab.image
}

output "app_port" {
  description = "Port the probe targets on the task public IP."
  value       = module.lab.app_port
}

output "container_log_group" {
  description = "Per-PR CloudWatch log group for container logs."
  value       = module.lab.log_group_name
}

output "flow_log_group" {
  description = "CloudWatch log group for the static lab VPC's flow logs (owned by platform/)."
  value       = "/networking-fun/platform/lab-network-flow-logs"
}
