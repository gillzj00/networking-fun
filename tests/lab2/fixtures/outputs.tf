output "vpc_id" {
  value = module.lab.vpc_id
}

output "instance_ids" {
  value = module.lab.instance_ids
}

output "probe_function_name" {
  value = module.probe.function_name
}

output "scenario" {
  value = var.scenario
}
