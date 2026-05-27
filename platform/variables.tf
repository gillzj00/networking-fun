variable "region" {
  description = "AWS region for all platform resources."
  type        = string
  default     = "us-east-2"
}

variable "owner_email" {
  description = "Email tagged on every resource for contact/billing visibility."
  type        = string
  default     = "5639243+gillzj00@users.noreply.github.com"
}

variable "demo_log_group_retention_days" {
  description = "Retention for the trivial demo log group that proves the GitOps loop works."
  type        = number
  default     = 1
}
