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
location    = "eastus2" # Change to westus2 / westeurope for B2pls_v2 availability
environment = "dev"

# Cost options (single node, always-on):
#   Standard_B2s       ~$35/month  x86  — available in all regions (default)
#   Standard_B2pls_v2  ~$17/month  ARM  — available in eastus2, westus2, westeurope
aks_node_vm_size = "Standard_B2pls_v2"
aks_node_count   = 1

kubernetes_version = null
