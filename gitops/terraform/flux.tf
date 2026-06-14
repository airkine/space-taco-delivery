# ---------------------------------------------------------------------------
# Flux Bootstrap
# ---------------------------------------------------------------------------
# flux_bootstrap_git does everything `flux bootstrap github` does:
#   1. Installs the Flux controllers into the cluster (flux-system namespace)
#   2. Creates a GitRepository source pointing at this repo
#   3. Commits the Flux component manifests to gitops/flux/flux-system/ and
#      pushes them to main so the cluster self-reconciles from Git going forward.
#
# After this resource is created, Flux owns its own manifests — future Flux
# upgrades happen by bumping the `version` attribute here and re-applying.
# ---------------------------------------------------------------------------
resource "flux_bootstrap_git" "main" {
  # Flux will watch this path inside the repo for Kustomizations to apply.
  # gitops/flux/flux-system/   ← written by Flux itself (controllers, CRDs)
  # gitops/flux/apps/          ← our HelmReleases, written below
  path = "gitops/flux"

  # Pin to a specific Flux version so upgrades are intentional.
  # Check latest: https://github.com/fluxcd/flux2/releases
  version = "v2.4.0"

  # embedded_manifests bundles the Flux CRDs/controllers into the provider
  # binary instead of downloading them from GitHub at apply time.
  # Faster, air-gappable, and avoids rate-limit issues in CI.
  embedded_manifests = true

  # Flux needs to push the bootstrap manifests to the repo.
  # The provider's git block (in main.tf) supplies the GitHub token.

  # depends_on ensures the cluster exists and is healthy before we attempt to
  # connect to its API server.
  depends_on = [azurerm_kubernetes_cluster.main]
}

# ---------------------------------------------------------------------------
# Kyverno — installed via Helm before the app HelmRelease so that admission
# policies are in place before the first space-taco pod is scheduled.
# ---------------------------------------------------------------------------
# We manage Kyverno as a flux HelmRelease (see gitops/flux/apps/) rather than
# a Terraform helm_release so that Flux owns the full reconciliation loop.
# No Terraform resources needed here beyond what flux_bootstrap_git sets up.
