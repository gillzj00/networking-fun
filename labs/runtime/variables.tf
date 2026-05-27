variable "region" {
  description = "AWS region for the lab."
  type        = string
  default     = "us-east-2"
}

variable "owner_email" {
  description = "Email tagged on every resource for contact/billing visibility."
  type        = string
  default     = "zachary.gill@hotmail.com"
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
  description = "Lab to provision. Must match the manifest enum (v1: layered-reachability)."
  type        = string

  validation {
    condition     = contains(["layered-reachability"], var.lab)
    error_message = "lab must be one of: layered-reachability."
  }
}

variable "scenario" {
  description = "Fault scenario. happy-path baseline plus three fault scenarios (nacl-deny-egress, missing-vpc-endpoint, dns-disabled) for layered-reachability."
  type        = string

  validation {
    condition = contains([
      "happy-path",
      "nacl-deny-egress",
      "missing-vpc-endpoint",
      "dns-disabled",
    ], var.scenario)
    error_message = "scenario must be one of: happy-path, nacl-deny-egress, missing-vpc-endpoint, dns-disabled."
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
