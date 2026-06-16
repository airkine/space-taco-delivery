locals {
  common_tags = {
    environment = var.environment
    project     = "space-taco-delivery"
    managed-by  = "terraform"
  }
  labels = {
    "area/app"      = { color = "0075ca", description = "Application code changes" }
    "area/gitops"   = { color = "e4e669", description = "GitOps / Helm / Kyverno changes" }
    "area/infra"    = { color = "d93f0b", description = "Terraform / infrastructure changes" }
    "area/ci"       = { color = "1d76db", description = "CI/CD workflow changes" }
    "type/bug"      = { color = "ee0701", description = "Something is broken in the galaxy" }
    "type/feature"  = { color = "84b6eb", description = "A new taco offering" }
    "type/chore"    = { color = "fef2c0", description = "Maintenance work" }
    "type/security" = { color = "e11d48", description = "Security improvements" }
    "priority/high" = { color = "b60205", description = "High priority — taco emergency" }
    "priority/low"  = { color = "0e8a16", description = "Low priority — slow burn" }
  }
}
