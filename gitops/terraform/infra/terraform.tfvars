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

# System pool SKU (AKS infrastructure only — CoreDNS, konnectivity, etc.).
# Cost options (per node, always-on):
#   Standard_B2s       ~$35/month  x86  — available in all regions (default)
#   Standard_B2pls_v2  ~$25/month  ARM  — available in eastus2, westus2, westeurope
aks_node_vm_size = "Standard_B2pls_v2"
aks_node_count   = 1 # system pool — AKS infrastructure (CoreDNS, konnectivity, etc.)

# user/apps pool — Flux, Kyverno, cert-manager, istiod, space-taco.
#
# History of getting this pool's sizing wrong, in order:
#
# 1 node (Standard_B2pls_v2): Kyverno 3.8.1's 4 controller deployments + 2
# istiod replicas + Flux's 4 controllers left no CPU request headroom at
# all on a single 2-vCPU node — kyverno-reports-controller stuck
# FailedScheduling ("Insufficient cpu").
#
# 2 nodes (Standard_B2pls_v2): still not enough — the new node hit 99%
# MEMORY requests instead, so kyverno-background-controller/
# -reports-controller stayed Pending with the same FailedScheduling
# pattern, just memory- not CPU-bound this time.
#
# 3 nodes (Standard_B2pls_v2): enough combined CPU+memory headroom across
# the pool for Kyverno's 4 controllers — but this was a count-vs-ceiling
# coincidence, not a real fix: each Standard_B2pls_v2 node only has ~1.68Gi
# free after mandatory platform daemonsets, a ceiling that no amount of
# additional same-SKU nodes can cross. cert-manager (added later) ate the
# last of that margin; the next pod that needed real memory (istiod, 2Gi
# per replica) couldn't schedule on ANY node regardless of count, took the
# sidecar-injection webhook down, and broke the application in production.
#
# Fix: aks_apps_node_vm_size (variables.tf) decouples this pool's SKU from
# the system pool's and bumps it to Standard_B2ms (2 vCPU / 8 GiB) — see
# that variable's description for the full memory-ceiling math. With
# per-node headroom no longer the binding constraint, node count drops back
# down: 2 nodes gives istiod's 2 replicas (anti-affinity-separated) a node
# each, with everything else (Kyverno, cert-manager, Flux, the app) spread
# across both with real headroom to spare.
aks_user_node_count   = 2
aks_apps_node_vm_size = "Standard_B2ms"

kubernetes_version = null
