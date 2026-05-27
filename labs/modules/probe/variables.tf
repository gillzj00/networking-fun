variable "pr_number" {
  description = "Pull request number that owns this probe. Used in resource names and tags."
  type        = number
}

variable "ttl_iso" {
  description = "ISO 8601 UTC timestamp used as the AutoDelete tag."
  type        = string
}

variable "scenario" {
  description = "Fault scenario the probe should evaluate."
  type        = string
  default     = "happy-path"
}

variable "lab" {
  description = "Lab name the probe is wired into. Selects the probe matrix: layered-reachability (single-instance SSM checks) or three-tier-segmentation (N×N SSM-RunCommand TCP matrix)."
  type        = string
  default     = "layered-reachability"

  validation {
    condition     = contains(["layered-reachability", "three-tier-segmentation"], var.lab)
    error_message = "lab must be one of: layered-reachability, three-tier-segmentation."
  }
}

variable "vpc_id" {
  description = "Lab VPC the probe runs in."
  type        = string
}

variable "subnet_ids" {
  description = "Subnet(s) the probe runs in. Should match the subnet hosting the target instance so SSM endpoints are reachable."
  type        = list(string)
}

variable "target_instance_id" {
  description = "EC2 instance ID the probe should look up via SSM DescribeInstanceInformation. Only used for lab=layered-reachability; ignored for three-tier-segmentation."
  type        = string
  default     = ""
}

variable "tier_targets" {
  description = "Per-tier target map for the three-tier-segmentation probe. Keys are tier names (web/app/db); values carry the instance ID, private IP, and the destination port to probe. Empty for layered-reachability."
  type = map(object({
    instance_id = string
    private_ip  = string
    port        = number
  }))
  default = {}
}

variable "endpoint_security_group_id" {
  description = "Security group attached to the SSM family endpoints. The probe SG gets an egress rule pointing at this SG so the Lambda can call SSM."
  type        = string
}

variable "log_retention_days" {
  description = "Retention for the probe's CloudWatch log group."
  type        = number
  default     = 1
}

variable "tags" {
  description = "Tags merged onto every probe resource."
  type        = map(string)
  default     = {}
}
