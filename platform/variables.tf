variable "region" {
  description = "AWS region for all platform resources."
  type        = string
  default     = "us-east-2"
}

variable "owner_email" {
  description = "Email tagged on every resource for contact/billing visibility."
  type        = string
  default     = "5639243+gillzj00@users.noreply.github.com"
}

variable "demo_log_group_retention_days" {
  description = "Retention for the trivial demo log group that proves the GitOps loop works."
  type        = number
  default     = 1
}

variable "janitor_schedule_expression" {
  description = "EventBridge schedule expression for the janitor Lambda."
  type        = string
  default     = "rate(15 minutes)"
}

variable "janitor_log_retention_days" {
  description = "Retention for the janitor Lambda's CloudWatch log group."
  type        = number
  default     = 7
}

variable "monthly_budget_usd" {
  description = "Account-wide monthly AWS Budget ceiling in USD."
  type        = string
  default     = "25"
}

variable "terratest_budget_usd" {
  description = "Monthly AWS Budget ceiling in USD for Workload=terratest tagged spend."
  type        = string
  default     = "5"
}

variable "labs_domain" {
  description = "Delegated subdomain of gillzhub.com used for lab vanity URLs (e.g. pr-42.labs.gillzhub.com)."
  type        = string
  default     = "labs.gillzhub.com"
}

variable "lab_vpc_cidr" {
  description = "CIDR for the static lab VPC. Labs modules use 10.20.0.0/24 and 10.30.0.0/24; keep this disjoint."
  type        = string
  default     = "10.40.0.0/24"
}

variable "lab_public_subnet_cidrs" {
  description = "CIDRs for the lab VPC public subnets, one per AZ starting at the region's first AZ. Must be inside lab_vpc_cidr and disjoint."
  type        = list(string)
  default     = ["10.40.0.0/26", "10.40.0.64/26"]
}

variable "lab_flow_log_retention_days" {
  description = "Retention for the lab VPC flow log group."
  type        = number
  default     = 1
}

variable "hello_image_tag" {
  description = "Image tag (git SHA) of apps/hello that the task definition pins. Pushed by the image-build workflow on merge to main."
  type        = string
  default     = "89bd2a240cf415643c0cfc0cafd3e04c2f29cd3f"
}

variable "hello_desired_count" {
  description = "Steady-state task count for the hello service. Defaults to 0 so idle cost is zero; demos use one-off run-task or bump this via PR."
  type        = number
  default     = 0
}

variable "hello_log_retention_days" {
  description = "Retention for the hello task log group."
  type        = number
  default     = 1
}

variable "enable_acm_validation" {
  description = "Flip to true after the parent-zone NS delegation for labs_domain has been added (manually) in the management account. Until then the ACM cert is created but cannot be validated."
  type        = bool
  default     = false
}
