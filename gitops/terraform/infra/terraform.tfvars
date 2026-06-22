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
# With system=1, apps=3 nodes:
#   Standard_B2pls_v2 → ~$68/month total node cost
#   Standard_B2s      → ~$140/month total node cost
aks_node_vm_size = "Standard_B2pls_v2"
aks_node_count   = 1 # system pool — AKS infrastructure (CoreDNS, konnectivity, etc.)
# user/apps pool — Flux, Kyverno, space-taco.
#
# 1 node: Kyverno 3.8.1's 4 controller deployments + 2 istiod replicas +
# Flux's 4 controllers left no CPU request headroom at all on a single
# 2-vCPU node — kyverno-reports-controller stuck FailedScheduling
# ("Insufficient cpu").
#
# 2 nodes: still not enough — the new node hit 99% MEMORY requests instead
# (B2pls_v2 is 2 vCPU / 4 GiB; istiod + Flux alone consume most of one
# node's headroom), so kyverno-background-controller/-reports-controller
# stayed Pending with the same FailedScheduling pattern, just memory- not
# CPU-bound this time.
#
# 3 nodes gives enough combined CPU+memory headroom across the pool for
# Kyverno's 4 controllers to actually schedule alongside everything else.
aks_user_node_count = 3

kubernetes_version = null
