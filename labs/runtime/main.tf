# ---------- labs/runtime/ ----------
#
# Per-PR root module composed of one lab module + one probe module. The
# lab-provision workflow runs `terraform apply` here with per-PR state at
# s3://<bucket>/labs/<pr-number>/terraform.tfstate. Closing the PR runs
# `terraform destroy`.
#
# v1 wires only the layered-reachability lab; slice 11 adds Lab #2 and
# the lab dispatch flips on var.lab.

module "lab" {
  source = "../modules/layered-reachability"

  pr_number = var.pr_number
  ttl_iso   = var.ttl_iso
  scenario  = var.scenario
}

module "probe" {
  source = "../modules/probe"

  pr_number                  = var.pr_number
  ttl_iso                    = var.ttl_iso
  scenario                   = var.scenario
  vpc_id                     = module.lab.vpc_id
  subnet_ids                 = [module.lab.private_subnet_id]
  target_instance_id         = module.lab.instance_id
  endpoint_security_group_id = module.lab.endpoint_security_group_id

  tags = {
    Lab      = var.lab
    Scenario = var.scenario
  }
}
