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

variable "scenario" {
  description = "Lab #1 scenario to provision. The Go test parameterises this per case."
  type        = string

  validation {
    condition = contains([
      "happy-path",
      "nacl-deny-egress",
      "missing-vpc-endpoint",
      "dns-disabled",
    ], var.scenario)
    error_message = "scenario must be a layered-reachability scenario."
  }
}
