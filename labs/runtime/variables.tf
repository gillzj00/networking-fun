variable "region" {
  description = "AWS region for the lab."
  type        = string
  default     = "us-east-2"
}

variable "owner_email" {
  description = "Email tagged on every resource for contact/billing visibility."
  type        = string
  default     = "5639243+gillzj00@users.noreply.github.com"
}

variable "pr_number" {
  description = "Pull request number owning this lab environment."
  type        = number

  validation {
    condition     = var.pr_number > 0
    error_message = "pr_number must be a positive integer."
  }
}

variable "lab" {
  description = "Lab to provision. Must match the manifest enum."
  type        = string

  validation {
    condition     = contains(["layered-reachability", "three-tier-segmentation"], var.lab)
    error_message = "lab must be one of: layered-reachability, three-tier-segmentation."
  }
}

variable "scenario" {
  description = "Fault scenario for the chosen lab. The manifest validator enforces the per-lab whitelist before Terraform runs; this variable validation guards against direct apply with an unsupported value."
  type        = string

  validation {
    condition = contains([
      "happy-path",
      "nacl-deny-egress",
      "missing-vpc-endpoint",
      "dns-disabled",
      "cidr-instead-of-sg",
      "nacl-stateless-return",
      "missing-chain-link",
    ], var.scenario)
    error_message = "scenario must be one of: happy-path, nacl-deny-egress, missing-vpc-endpoint, dns-disabled, cidr-instead-of-sg, nacl-stateless-return, missing-chain-link."
  }
}

variable "ttl_iso" {
  description = "ISO 8601 UTC timestamp used as the AutoDelete tag (e.g. 2026-05-26T14:00:00Z)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", var.ttl_iso))
    error_message = "ttl_iso must look like 2026-05-26T14:00:00Z."
  }
}
