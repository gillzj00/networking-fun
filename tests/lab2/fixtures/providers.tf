provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project    = "networking-fun"
      Layer      = "test"
      ManagedBy  = "terratest"
      OwnerEmail = var.owner_email
      AutoDelete = var.ttl_iso
      Terratest  = "true"
      Workload   = "terratest"
    }
  }
}
