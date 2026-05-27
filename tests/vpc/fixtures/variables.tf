variable "region" {
  description = "AWS region the test fixture runs in."
  type        = string
}

variable "suffix" {
  description = "Short random suffix injected by the Terratest harness; used to derive a pr_number-shaped integer for the lab module."
  type        = string
}

variable "ttl_iso" {
  description = "AutoDelete TTL written by the harness (~1h from test start)."
  type        = string
}

variable "owner_email" {
  description = "OwnerEmail default tag value."
  type        = string
  default     = "5639243+gillzj00@users.noreply.github.com"
}
