# versions.tf — Terraform runtime and provider version constraints for the
# GitHub-resources module.
#
# This module's state is deliberately separate from infra/ (AKS + Flux) so
# that the Terraform Destroy workflow — which only ever targets infra/ — has
# no way to reach the github_repository resource and delete the repo itself.
# See ../README.md "Why two states" for the incident that prompted this split.
terraform {
  required_version = "~> 1.7"

  required_providers {
    # GitHub provider — manages the repo, branch protection, secrets, labels,
    # environments. This is the ONLY provider this module needs.
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }

  # Remote state stored in Azure Blob Storage, in its own key so it can never
  # be destroyed by an `infra` destroy run (different backend key = different
  # state file = terraform destroy in infra/ cannot see or touch this state).
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "terraformstate024"
    container_name       = "tfstate"
    key                  = "space-taco-delivery/github/terraform.tfstate"
  }
}
