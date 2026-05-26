variable "region" {
  description = "AWS region for all platform resources."
  type        = string
  default     = "us-east-2"
}

variable "owner_email" {
  description = "Email tagged on every resource for contact/billing visibility."
  type        = string
  default     = "zachary.gill@hotmail.com"
}

variable "demo_log_group_retention_days" {
  description = "Retention for the trivial demo log group that proves the GitOps loop works."
  type        = number
  default     = 1
}

variable "janitor_schedule_expression" {
  description = "EventBridge schedule expression for the janitor Lambda."
  type        = string
  default     = "rate(15 minutes)"
}

variable "janitor_log_retention_days" {
  description = "Retention for the janitor Lambda's CloudWatch log group."
  type        = number
  default     = 7
}

variable "monthly_budget_usd" {
  description = "Account-wide monthly AWS Budget ceiling in USD."
  type        = string
  default     = "25"
}

variable "terratest_budget_usd" {
  description = "Monthly AWS Budget ceiling in USD for Workload=terratest tagged spend."
  type        = string
  default     = "5"
}
