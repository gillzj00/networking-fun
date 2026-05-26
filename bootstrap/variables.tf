variable "region" {
  description = "AWS region for all bootstrap resources."
  type        = string
  default     = "us-east-2"
}

variable "owner_email" {
  description = "Email to tag on every resource for contact/billing visibility."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository allowed to assume the OIDC role, in 'owner/name' form."
  type        = string
  default     = "gillzj00/networking-fun"
}

variable "github_role_name" {
  description = "Name of the IAM role GitHub Actions assumes."
  type        = string
  default     = "gha-terraform"
}

variable "github_role_session_hours" {
  description = "Max session duration (hours) for the GitHub Actions role. Matches the project's 4h lab TTL."
  type        = number
  default     = 4
}
