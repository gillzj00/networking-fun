output "vpc_id" {
  value = module.lab.vpc_id
}

output "private_subnet_id" {
  value = module.lab.private_subnet_id
}

output "instance_id" {
  value = module.lab.instance_id
}

output "instance_security_group_id" {
  value = module.lab.instance_security_group_id
}

output "endpoint_security_group_id" {
  value = module.lab.endpoint_security_group_id
}

output "ssm_endpoint_ids" {
  value = module.lab.ssm_endpoint_ids
}

output "flow_log_group_name" {
  value = module.lab.flow_log_group_name
}
