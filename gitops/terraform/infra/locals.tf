locals {
  common_tags = {
    environment = var.environment
    project     = "space-taco-delivery"
    managed-by  = "terraform"
  }
}
