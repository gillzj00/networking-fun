variable "pr_number" {
  description = "Pull request number owning this lab environment."
  type        = number
}

variable "scenario" {
  description = "Fault scenario to inject into the task definition, security group, or execution role."
  type        = string
}

variable "region" {
  description = "AWS region, needed by the awslogs driver configuration."
  type        = string
}

variable "log_retention_days" {
  description = "Retention for the per-PR container log group."
  type        = number
  default     = 1
}
