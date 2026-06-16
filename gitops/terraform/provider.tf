# provider.tf — Provider configuration blocks only.
# Version constraints and the backend live in versions.tf.

provider "github" {
  token = var.github_token
  owner = var.github_owner
}

provider "azurerm" {
  # features {} is required by the provider even when no feature flags are set.
  features {}
  subscription_id = var.azure_subscription_id
}

provider "flux" {
  kubernetes = {
    host = azurerm_kubernetes_cluster.this.kube_config[0].host

    # kube_config values are base64-encoded by the AKS API; decode before use.
    client_certificate     = base64decode(azurerm_kubernetes_cluster.this.kube_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.this.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate)
  }

  git = {
    url = "https://github.com/${var.github_owner}/space-taco-delivery.git"
    http = {
      username = "git"
      # github_token is marked sensitive; Terraform will not print it in plan/apply output.
      password = var.github_token
    }
  }
}
