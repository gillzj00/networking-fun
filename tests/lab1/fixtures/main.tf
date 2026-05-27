# tests/lab1/fixtures/ — Terratest root for the layered-reachability lab
# end-to-end tests. Mirrors what labs/runtime/ does for this lab, but with
# Terratest tags in providers.tf and a synthetic pr_number derived from
# the harness suffix.

locals {
  # Map the harness suffix to a deterministic pr_number in [900000, 999999]
  # so test resources can never collide with a real PR provision.
  pr_number = 900000 + (parseint(substr(sha256(var.suffix), 0, 4), 16) % 100000)
}

module "lab" {
  source = "../../../labs/modules/layered-reachability"

  pr_number = local.pr_number
  ttl_iso   = var.ttl_iso
  scenario  = var.scenario
}

module "probe" {
  source = "../../../labs/modules/probe"

  pr_number                  = local.pr_number
  ttl_iso                    = var.ttl_iso
  scenario                   = var.scenario
  lab                        = "layered-reachability"
  vpc_id                     = module.lab.vpc_id
  subnet_ids                 = [module.lab.private_subnet_id]
  target_instance_id         = module.lab.instance_id
  endpoint_security_group_id = module.lab.endpoint_security_group_id

  tags = {
    Lab      = "layered-reachability"
    Scenario = var.scenario
  }
}
