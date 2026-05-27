variable "pr_number" {
  description = "Pull request number that owns this probe. Used in resource names and tags."
  type        = number
}

variable "ttl_iso" {
  description = "ISO 8601 UTC timestamp used as the AutoDelete tag."
  type        = string
}

variable "scenario" {
  description = "Fault scenario the probe should evaluate. v1: happy-path."
  type        = string
  default     = "happy-path"
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
  description = "EC2 instance ID the probe should look up via SSM DescribeInstanceInformation."
  type        = string
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
