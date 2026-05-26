provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "networking-fun"
      Environment = "platform"
      ManagedBy   = "terraform"
      Layer       = "platform"
      OwnerEmail  = var.owner_email
    }
  }
}
