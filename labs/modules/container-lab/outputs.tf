output "cluster_name" {
  description = "Shared ECS cluster the lab service runs on."
  value       = data.aws_ecs_cluster.labs.cluster_name
}

output "service_name" {
  description = "Per-PR ECS service name."
  value       = aws_ecs_service.lab.name
}

output "task_definition_arn" {
  description = "Per-PR task definition ARN."
  value       = aws_ecs_task_definition.lab.arn
}

output "security_group_id" {
  description = "Per-PR security group on the lab task."
  value       = aws_security_group.lab.id
}

output "log_group_name" {
  description = "Per-PR CloudWatch log group for container logs."
  value       = aws_cloudwatch_log_group.lab.name
}

output "image" {
  description = "Image URI the task definition pins (includes the scenario-injected tag, if any)."
  value       = local.image
}

output "app_port" {
  description = "Port the hello app serves on (the probe targets this)."
  value       = local.app_port
}

output "vpc_id" {
  description = "Static lab VPC the service runs in."
  value       = data.aws_vpc.lab.id
}
