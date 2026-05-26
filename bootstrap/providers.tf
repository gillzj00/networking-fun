provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "networking-fun"
      Environment = "bootstrap"
      ManagedBy   = "terraform"
      Layer       = "bootstrap"
      OwnerEmail  = var.owner_email
    }
  }
}
