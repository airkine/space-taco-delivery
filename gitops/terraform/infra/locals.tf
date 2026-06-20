locals {
  common_tags = {
    environment = var.environment
    project     = "space-taco-delivery"
    managed-by  = "terraform"
  }

  # Istio service mesh add-on control plane revision (see aks.tf
  # service_mesh_profile). Pinned explicitly (rather than left to the addon's
  # "pick a default" behavior) so gitops/flux/apps/namespace.yaml's
  # istio.io/rev=<revision> sidecar-injection label always matches the
  # control plane that's actually installed.
  #
  # Before bumping this, confirm the new revision is available for
  # var.location and compatible with the cluster's Kubernetes version:
  #   az aks mesh get-revisions --location eastus2 -o table
  istio_revision = "asm-1-28"
}
