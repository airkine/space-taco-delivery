# ---------------------------------------------------------------------------
# Credentials needed by this module even though the *resources* they
# authenticate live in the github/ module.
# ---------------------------------------------------------------------------

variable "github_token" {
  description = "GitHub personal access token — used only for git push auth by the flux provider (no github_* resources live in this module)"
  type        = string
  nullable    = false
  sensitive   = true
}

variable "github_owner" {
  description = "GitHub organization or user that owns the repository — used to build the flux bootstrap git URL"
  type        = string
  nullable    = false
}

variable "azure_subscription_id" {
  description = "Azure subscription ID — used by the azurerm provider"
  type        = string
  default     = ""

  validation {
    condition     = var.azure_subscription_id == "" || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.azure_subscription_id))
    error_message = "azure_subscription_id must be a valid UUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx) or an empty string."
  }
}

# ---------------------------------------------------------------------------
# AKS variables
# ---------------------------------------------------------------------------

variable "location" {
  description = "Azure region for the AKS resource group and cluster"
  type        = string
  default     = "eastus2" # Consistently one of the cheapest US regions for Bsv2 SKUs
}

variable "environment" {
  description = "Deployment environment label — appended to resource names (e.g. dev, staging)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "aks_node_vm_size" {
  description = <<-EOT
    VM SKU for the system node pool only (AKS infrastructure — CoreDNS,
    konnectivity, etc.). See aks_apps_node_vm_size for the user/apps pool,
    which has a much larger memory footprint and is intentionally sized
    differently — see that variable's description for why.

    Cost-optimized options (single node, always-on):
      Standard_B2pls_v2  ~$25/month  ARM64  — cheapest; requires eastus2 / westus2 / westeurope
      Standard_B2s       ~$35/month  x86_64 — available in all regions

    The app image is multi-arch (linux/amd64 + linux/arm64), so ARM is fine.
    Swap this value in terraform.tfvars; no other change needed.
  EOT
  type        = string
  default     = "Standard_B4pls_v2" # x86 default for broadest region availability
}

variable "aks_apps_node_vm_size" {
  description = <<-EOT
    VM SKU for the user/apps node pool (Flux, Kyverno, cert-manager, the
    AKS-managed Istio add-on's istiod, and the space-taco application).

    Deliberately decoupled from aks_node_vm_size (the system pool's SKU):
    istiod alone requests 2Gi memory per replica (2 replicas, not
    Helm/Terraform-tunable — it's entirely managed by the AKS Istio add-on,
    see gitops/terraform/README.md "Istio service mesh add-on"). On
    Standard_B2pls_v2 (2 vCPU / 4 GiB), mandatory per-node platform
    daemonsets (CNI, CSI drivers, kube-proxy, metrics, etc.) consume ~1.1Gi
    of the ~2.79Gi allocatable, leaving a hard ceiling of ~1.68Gi free per
    node — under istiod's 2Gi requirement. This ceiling is per-NODE, so it
    cannot be fixed by adding more nodes of the same SKU, only a larger SKU.
    This was discovered the hard way: scaling aks_user_node_count 3→4 on
    Standard_B2pls_v2 did not let istiod schedule and caused a real outage
    (sidecar-injection webhook unreachable → space-taco pods failed to
    create). Standard_B2ms (2 vCPU / 8 GiB, ~$60/month) is the cheapest SKU
    with enough per-node memory headroom — cheaper than even the ARM
    Standard_B4pls_v2 (4 vCPU / 8 GiB, ~$87/month) for the same memory.
  EOT
  type        = string
  default     = "Standard_B2ms"
}

variable "aks_node_count" {
  description = "Number of nodes in the system node pool (AKS infrastructure only). 1 is sufficient for dev."
  type        = number
  default     = 1

  validation {
    condition     = var.aks_node_count >= 1 && var.aks_node_count <= 3
    error_message = "aks_node_count must be between 1 and 3 for the dev tier."
  }
}

variable "aks_user_node_count" {
  description = "Number of nodes in the user (apps) node pool. Hosts Flux, Kyverno, and the space-taco application."
  type        = number
  default     = 1

  validation {
    condition     = var.aks_user_node_count >= 1 && var.aks_user_node_count <= 5
    error_message = "aks_user_node_count must be between 1 and 5."
  }
}

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes minor version to pin the cluster to (e.g. "1.30").
    Set to null to let Azure select the latest supported version on initial creation.
    After creation, the cluster version is tracked in state and the lifecycle
    ignore_changes rule prevents Terraform from flagging auto-applied patch upgrades.
  EOT
  type        = string
  default     = null
}

variable "management_resource_group_name" {
  description = "Resource group containing shared resources (DNS zones) provisioned outside this stack."
  type        = string
  default     = "rg-management"
}

variable "dns_zone_name" {
  description = "Azure DNS zone used for ingress hostnames."
  type        = string
  default     = "autoaaron.xyz"
}
