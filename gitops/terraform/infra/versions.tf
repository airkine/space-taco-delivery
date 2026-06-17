# versions.tf — Terraform runtime and provider version constraints for the
# Azure/Flux infrastructure module.
#
# This module's state is deliberately separate from github/ (repo, branch
# protection, secrets, labels, environments) so that the Terraform Destroy
# workflow — which only targets this directory — can never delete the
# GitHub repository itself. See ../README.md "Why two states" for the
# incident that prompted this split.
terraform {
  required_version = "~> 1.7"

  required_providers {
    # Azure provider — manages the AKS cluster, resource group, public IP,
    # and the DNS role assignment for external-dns.
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

  # Remote state stored in Azure Blob Storage, in its own key so a destroy
  # run scoped to this directory can never see or touch the github/ state.
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "terraformstate024"
    container_name       = "tfstate"
    key                  = "space-taco-delivery/infra/terraform.tfstate"
  }
}
