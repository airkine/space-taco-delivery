# Non-sensitive Terraform config — committed to source control and auto-loaded
# by Terraform for both local runs and CI.
#
# github_token is NOT set here (it's sensitive). Supply it via the
# TF_VAR_github_token environment variable — CI reads it from the
# TF_GITHUB_TOKEN secret; for local runs, export it yourself. It is only used
# here for git push auth by the flux provider (no github_* resources live in
# this module).

github_owner = "airkine"

# ---------------------------------------------------------------------------
# AKS
# ---------------------------------------------------------------------------
location    = "eastus2"
environment = "dev"

# VM SKU is shared by both the system and user node pools.
# Cost options (per node, always-on):
#   Standard_B2s       ~$35/month  x86  — available in all regions (default)
#   Standard_B2pls_v2  ~$17/month  ARM  — available in eastus2, westus2, westeurope
# With system=1, apps=2 nodes:
#   Standard_B2pls_v2 → ~$51/month total node cost
#   Standard_B2s      → ~$105/month total node cost
aks_node_vm_size = "Standard_B2pls_v2"
aks_node_count   = 1 # system pool — AKS infrastructure (CoreDNS, konnectivity, etc.)
# user/apps pool — Flux, Kyverno, space-taco. 2 nodes (not 1): on a single
# 2-vCPU node, Kyverno 3.8.1's 4 controller deployments + 2 istiod replicas +
# Flux's 4 controllers leave no CPU request headroom, so kyverno-reports-controller
# gets stuck FailedScheduling ("Insufficient cpu") and the HelmRelease's install
# retries (remediation.retries: 3) all fail the same way. A second node gives
# the scheduler somewhere else to place the overflow.
aks_user_node_count = 2

kubernetes_version = null
