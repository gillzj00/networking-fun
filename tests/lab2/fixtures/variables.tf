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
  default     = "zachary.gill@hotmail.com"
}

variable "scenario" {
  description = "Lab #2 scenario to provision. The Go test parameterises this per case."
  type        = string

  validation {
    condition = contains([
      "happy-path",
      "cidr-instead-of-sg",
      "nacl-stateless-return",
      "missing-chain-link",
    ], var.scenario)
    error_message = "scenario must be a three-tier-segmentation scenario."
  }
}
