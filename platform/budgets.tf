# ---------- AWS Budgets ----------
#
# G3 cost ceiling: $25/mo for the whole sub-account, plus a $5/mo guard on
# Terratest-driven spend so a runaway integration test doesn't quietly burn
# the budget. Both alerts route to OwnerEmail via Budgets' native email
# notifications.

resource "aws_budgets_budget" "monthly" {
  name              = "networking-fun-monthly"
  budget_type       = "COST"
  limit_amount      = var.monthly_budget_usd
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-05-01_00:00"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.owner_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.owner_email]
  }
}

# The Terratest budget filters on the `Workload=terratest` cost-allocation
# tag, set by the Terratest harness in slice #9. Until that tag is
# activated as a cost-allocation tag in the Billing console AND slice #9
# starts emitting it, this budget will read $0 and never fire — that's the
# intended idle state.
resource "aws_budgets_budget" "terratest" {
  name              = "networking-fun-terratest"
  budget_type       = "COST"
  limit_amount      = var.terratest_budget_usd
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-05-01_00:00"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Workload$terratest"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.owner_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.owner_email]
  }
}
