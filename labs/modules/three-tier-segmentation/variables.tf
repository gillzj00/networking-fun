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
  description = "Scenario for three-tier-segmentation. happy-path is the baseline; the three fault scenarios each break one layer (SG-by-CIDR blast radius, NACL stateless return, missing inbound chain link)."
  type        = string
  default     = "happy-path"

  validation {
    condition = contains([
      "happy-path",
      "cidr-instead-of-sg",
      "nacl-stateless-return",
      "missing-chain-link",
    ], var.scenario)
    error_message = "scenario must be one of: happy-path, cidr-instead-of-sg, nacl-stateless-return, missing-chain-link."
  }
}

variable "vpc_cidr" {
  description = "CIDR for the lab VPC."
  type        = string
  default     = "10.30.0.0/24"
}

variable "subnet_cidrs" {
  description = "Per-tier subnet CIDR blocks. Must all be inside vpc_cidr and disjoint."
  type        = map(string)
  default = {
    web = "10.30.0.0/27"
    app = "10.30.0.32/27"
    db  = "10.30.0.64/27"
  }

  validation {
    condition     = alltrue([for k in ["web", "app", "db"] : contains(keys(var.subnet_cidrs), k)])
    error_message = "subnet_cidrs must contain keys: web, app, db."
  }
}

variable "instance_type" {
  description = "EC2 instance type for each tier. Default t4g.nano (Graviton, ~$0.0042/hr × 3 instances)."
  type        = string
  default     = "t4g.nano"
}

variable "flow_log_retention_days" {
  description = "Retention for the VPC Flow Logs CloudWatch log group."
  type        = number
  default     = 1
}
