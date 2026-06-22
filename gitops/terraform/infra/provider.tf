# provider.tf — Provider configuration blocks only.
# Version constraints and the backend live in versions.tf.

provider "azurerm" {
  # features {} is required by the provider even when no feature flags are set.
  features {}

  # var.azure_subscription_id defaults to "" (see variables.tf) so that local
  # runs aren't forced to export TF_VAR_azure_subscription_id when az CLI /
  # OIDC context already implies a subscription. Passing "" through to the
  # provider literally, though, is NOT the same as omitting the argument —
  # the provider treats an explicit empty string as "set, and invalid"
  # rather than "unset, fall back to ARM_SUBSCRIPTION_ID / az CLI context".
  # Coalescing to null here restores the intended fallback behavior.
  subscription_id = var.azure_subscription_id != "" ? var.azure_subscription_id : null
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
    # The repo itself is managed in the separate github/ state — this module
    # only needs the plain clone URL + a token with push access, not the
    # github_repository resource.
    url = "https://github.com/${var.github_owner}/space-taco-delivery.git"
    http = {
      username = "git"
      # github_token is marked sensitive; Terraform will not print it in plan/apply output.
      password = var.github_token
    }
  }
}
