# versions.tf — Terraform runtime and provider version constraints.
# Keeping this separate from provider.tf follows the standard module layout:
#   versions.tf  = terraform {} block (required_version, required_providers, backend)
#   provider.tf  = provider "..." configuration blocks

terraform {
  # Pin to the 1.x line; ">= 1.7" would allow Terraform 2.0+ which may
  # introduce breaking changes incompatible with this configuration.
  required_version = "~> 1.7"

  required_providers {
    # GitHub provider — manages repos, branch protection, secrets, environments.
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }

    # Azure provider — manages AKS cluster, resource groups, DNS, public IPs.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }

    # Flux provider — bootstraps Flux CD onto the AKS cluster via Git.
    flux = {
      source  = "fluxcd/flux"
      version = "~> 1.4"
    }
  }

  # Remote state stored in Azure Blob Storage.
  # Azure Storage encrypts at rest by default (AES-256); no extra flag needed.
  # For CI authentication, configure ARM_USE_OIDC=true as an environment variable
  # rather than storing credentials in this file.
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "terraformstate024"
    container_name       = "tfstate"
    key                  = "space-taco-delivery/github/terraform.tfstate"
  }
}
