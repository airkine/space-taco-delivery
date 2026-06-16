# Non-sensitive Terraform config — committed to source control and auto-loaded
# by Terraform for both local runs and CI.
#
# github_token is NOT set here (it's sensitive). Supply it via the
# TF_VAR_github_token environment variable — CI reads it from the
# TF_GITHUB_TOKEN secret; for local runs, export it yourself.

# ---------------------------------------------------------------------------
# GitHub
# ---------------------------------------------------------------------------
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
# With two pools at 1 node each:
#   Standard_B2pls_v2 → ~$34/month total node cost
#   Standard_B2s      → ~$70/month total node cost
aks_node_vm_size    = "Standard_B2pls_v2"
aks_node_count      = 1 # system pool — AKS infrastructure (CoreDNS, konnectivity, etc.)
aks_user_node_count = 1 # user/apps pool — Flux, Kyverno, space-taco

kubernetes_version = null
