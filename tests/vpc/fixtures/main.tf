# tests/vpc/fixtures/ — Terratest root for the layered-reachability VPC test.
#
# We invoke the lab module exactly the way labs/runtime/ does, but with a
# pr_number derived from the test's random suffix (Terratest's UniqueId is
# 6 alphanumeric chars; we map it to a stable integer above the PR-number
# range so test resources never collide with real PR provisions).

locals {
  # Derive a deterministic pr_number from the suffix. Range [900000, 999999]
  # is well above any plausible GitHub PR number for this repo.
  pr_number = 900000 + (parseint(substr(sha256(var.suffix), 0, 4), 16) % 100000)
}

module "lab" {
  source = "../../../labs/modules/layered-reachability"

  pr_number = local.pr_number
  ttl_iso   = var.ttl_iso
  scenario  = "happy-path"
}
