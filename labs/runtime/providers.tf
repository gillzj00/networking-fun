provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "networking-fun"
      Environment = "lab-pr-${var.pr_number}"
      ManagedBy   = "terraform"
      Layer       = "lab"
      Lab         = var.lab
      Scenario    = var.scenario
      OwnerEmail  = var.owner_email
      AutoDelete  = var.ttl_iso
    }
  }
}
