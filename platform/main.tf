terraform {
  # Backend config supplied at init time via -backend-config flags or
  # backend.hcl, so the account ID stays out of version control. See
  # platform/README.md and the platform-apply / platform-plan workflows.
  backend "s3" {}
}

# ---------- Trivial resource to prove the GitOps loop ----------
#
# This log group exists only to prove that PRs touching platform/ produce a
# terraform plan comment and that merges to main run terraform apply. It can
# be replaced or removed once real platform resources (janitor Lambda, ACM,
# Route53 zone, Budgets) land in later slices.
resource "aws_cloudwatch_log_group" "platform_demo" {
  name              = "/networking-fun/platform/demo"
  retention_in_days = var.demo_log_group_retention_days
}
