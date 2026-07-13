# ---------- labs/runtime/ ----------
#
# Per-PR root module. The lab-provision workflow runs `terraform apply` here
# with per-PR state at s3://<bucket>/labs/<pr-number>/terraform.tfstate.
# Closing the PR (or a `/lab destroy` comment) runs `terraform destroy`.
#
# Since Amendment A1 the only lab is the container lab: a per-PR Fargate
# service on the shared cluster. The VPC lab modules (layered-reachability,
# three-tier-segmentation, probe) remain in labs/modules/ as reference but
# are no longer provisioned.

module "lab" {
  source = "../modules/container-lab"

  pr_number = var.pr_number
  scenario  = var.scenario
  region    = var.region
}
