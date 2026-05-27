# ---------- labs/runtime/ ----------
#
# Per-PR root module composed of one lab module + one probe module. The
# lab-provision workflow runs `terraform apply` here with per-PR state at
# s3://<bucket>/labs/<pr-number>/terraform.tfstate. Closing the PR runs
# `terraform destroy`.
#
# Lab dispatch: each lab module is wrapped in count = (var.lab == X ? 1 : 0)
# so exactly one module instance materialises per apply. The probe
# module reads from whichever lab is active.

module "lab_layered" {
  count  = var.lab == "layered-reachability" ? 1 : 0
  source = "../modules/layered-reachability"

  pr_number = var.pr_number
  ttl_iso   = var.ttl_iso
  scenario  = var.scenario
}

module "lab_three_tier" {
  count  = var.lab == "three-tier-segmentation" ? 1 : 0
  source = "../modules/three-tier-segmentation"

  pr_number = var.pr_number
  ttl_iso   = var.ttl_iso
  scenario  = var.scenario
}

locals {
  layered_active    = length(module.lab_layered) > 0
  three_tier_active = length(module.lab_three_tier) > 0

  vpc_id                     = local.layered_active ? module.lab_layered[0].vpc_id : module.lab_three_tier[0].vpc_id
  probe_subnet_ids           = local.layered_active ? [module.lab_layered[0].private_subnet_id] : [module.lab_three_tier[0].subnet_ids["app"]]
  endpoint_security_group_id = local.layered_active ? module.lab_layered[0].endpoint_security_group_id : module.lab_three_tier[0].endpoint_security_group_id

  target_instance_id = local.layered_active ? module.lab_layered[0].instance_id : ""

  tier_targets = local.three_tier_active ? {
    for tier, id in module.lab_three_tier[0].instance_ids :
    tier => {
      instance_id = id
      private_ip  = module.lab_three_tier[0].instance_private_ips[tier]
      port        = module.lab_three_tier[0].tier_ports[tier]
    }
  } : {}

  flow_log_group_name = local.layered_active ? module.lab_layered[0].flow_log_group_name : module.lab_three_tier[0].flow_log_group_name
}

module "probe" {
  source = "../modules/probe"

  pr_number                  = var.pr_number
  ttl_iso                    = var.ttl_iso
  scenario                   = var.scenario
  lab                        = var.lab
  vpc_id                     = local.vpc_id
  subnet_ids                 = local.probe_subnet_ids
  target_instance_id         = local.target_instance_id
  tier_targets               = local.tier_targets
  endpoint_security_group_id = local.endpoint_security_group_id

  tags = {
    Lab      = var.lab
    Scenario = var.scenario
  }
}
