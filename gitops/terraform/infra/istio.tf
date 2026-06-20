# istio.tf — Enables Istio CNI chaining mode for the AKS-managed Istio
# service mesh add-on (service_mesh_profile block in aks.tf).
#
# By default the add-on injects the legacy `istio-init` container into every
# meshed pod, which needs NET_ADMIN/NET_RAW capabilities and runs as root to
# set up iptables redirection. Kyverno's space-taco-pod-security
# ClusterPolicy rejects exactly that (allowPrivilegeEscalation,
# readOnlyRootFilesystem, runAsNonRoot) — the same failure mode that was hit
# and fixed for the self-managed upstream Istio install used in Kind (see
# deploy/kind/bootstrap-local.ps1). CNI chaining moves that setup to a
# per-node DaemonSet instead, so the sidecar itself stays unprivileged.
#
# The azurerm provider does not yet expose this as a `service_mesh_profile`
# field (https://github.com/hashicorp/terraform-provider-azurerm/issues/31177),
# so it's applied with a one-time `az aks mesh` CLI call via local-exec
# instead of a native resource.
#
# Requires an authenticated `az` CLI in whatever environment runs
# `terraform apply`:
#   - In CI, terraform.yml's terraform-infra job already runs `azure/login`
#     before any Terraform command, so this inherits that session.
#   - Locally, run `az login` first (see ../README.md "Local development").
resource "null_resource" "istio_cni_chaining" {
  triggers = {
    cluster_id = azurerm_kubernetes_cluster.this.id
    # Re-run if the pinned revision changes, since `az aks mesh
    # proxy-redirection-mechanism` is scoped to the currently active revision.
    revision = local.istio_revision
  }

  provisioner "local-exec" {
    command = "az aks mesh proxy-redirection-mechanism --resource-group ${azurerm_resource_group.aks.name} --name ${azurerm_kubernetes_cluster.this.name} --mechanism CNIChaining"
  }

  depends_on = [azurerm_kubernetes_cluster.this]
}
