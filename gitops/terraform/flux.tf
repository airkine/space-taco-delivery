resource "flux_bootstrap_git" "main" {
  path    = "gitops/flux"
  version = "v2.4.0"

  # Bundles Flux CRDs/controllers into the provider binary — avoids GitHub rate limits in CI.
  embedded_manifests = true

  depends_on = [azurerm_kubernetes_cluster.this]
}
