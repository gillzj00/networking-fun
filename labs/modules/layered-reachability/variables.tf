variable "pr_number" {
  description = "Pull request number that owns this lab environment. Used in resource names and the Env tag."
  type        = number

  validation {
    condition     = var.pr_number > 0
    error_message = "pr_number must be a positive integer."
  }
}

variable "ttl_iso" {
  description = "ISO 8601 UTC timestamp (e.g. 2026-05-26T14:00:00Z) used as the AutoDelete tag. The janitor Lambda destroys resources past this time."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", var.ttl_iso))
    error_message = "ttl_iso must look like 2026-05-26T14:00:00Z."
  }
}

variable "scenario" {
  description = "Fault scenario name. happy-path is the baseline; the other three deliberately break one layer (NACL, endpoint, DNS) so the probe can demonstrate the failure mode."
  type        = string
  default     = "happy-path"

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

variable "vpc_cidr" {
  description = "CIDR for the lab VPC."
  type        = string
  default     = "10.20.0.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR for the private compute subnet (instance + probe Lambda)."
  type        = string
  default     = "10.20.0.0/27"
}

variable "endpoint_subnet_cidr" {
  description = "CIDR for the SSM endpoint subnet. Kept separate from the compute subnet so the nacl-deny-egress scenario actually exercises the subnet boundary."
  type        = string
  default     = "10.20.0.32/27"
}

variable "instance_type" {
  description = "EC2 instance type for the lab compute. Default t4g.nano (Graviton, ~$0.0042/hr)."
  type        = string
  default     = "t4g.nano"
}

variable "flow_log_retention_days" {
  description = "Retention for the VPC Flow Logs CloudWatch log group."
  type        = number
  default     = 1
}
