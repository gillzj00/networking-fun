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

variable "labs_domain" {
  description = "Delegated subdomain of gillzhub.com used for lab vanity URLs (e.g. pr-42.labs.gillzhub.com)."
  type        = string
  default     = "labs.gillzhub.com"
}

variable "enable_acm_validation" {
  description = "Flip to true after the parent-zone NS delegation for labs_domain has been added (manually) in the management account. Until then the ACM cert is created but cannot be validated."
  type        = bool
  default     = false
}
