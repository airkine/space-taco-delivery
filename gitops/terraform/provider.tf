terraform {
  required_version = ">= 1.7"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }

    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }

    flux = {
      source  = "fluxcd/flux"
      version = "~> 1.4"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "terraformstate024"
    container_name       = "tfstate"
    key                  = "space-taco-delivery/github/terraform.tfstate"
  }
}

provider "github" {
  token = var.github_token
  owner = var.github_owner
}

provider "azurerm" {
  # features {} block is required even when empty.
  features {}
  subscription_id = var.azure_subscription_id
}

provider "flux" {
  kubernetes = {
    host                   = azurerm_kubernetes_cluster.main.kube_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.main.kube_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.main.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.main.kube_config[0].cluster_ca_certificate)
  }
  git = {
    url = "https://github.com/${var.github_owner}/space-taco-delivery.git"
    http = {
      username = "git"
      password = var.github_token
    }
  }
}
