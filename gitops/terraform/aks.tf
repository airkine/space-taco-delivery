# moved block — renames the resource address from .main → .this without
# destroying and recreating the cluster. "this" is the correct convention
# for a genuine singleton resource (one cluster per stack).
moved {
  from = azurerm_kubernetes_cluster.main
  to   = azurerm_kubernetes_cluster.this
}

resource "azurerm_resource_group" "aks" {
  name     = "rg-space-taco-${var.environment}"
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-space-taco-${var.environment}"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  dns_prefix          = "space-taco-${var.environment}"

  # "Free" = $0 control plane; "Standard" adds an SLA for ~$73/month.
  sku_tier = "Free"

  automatic_upgrade_channel = "patch"
  kubernetes_version        = var.kubernetes_version

  # ---------------------------------------------------------------------------
  # System node pool — AKS infrastructure only (CoreDNS, konnectivity, etc.)
  # ---------------------------------------------------------------------------
  default_node_pool {
    name            = "system"
    node_count      = var.aks_node_count
    vm_size         = var.aks_node_vm_size
    os_disk_size_gb = 30
    # Ephemeral disk requires VM cache ≥ OS disk size; B-series cache = 0, so use Managed.
    os_disk_type         = "Managed"
    auto_scaling_enabled = false

    upgrade_settings {
      max_surge = "1"
    }
  }

  network_profile {
    network_plugin    = "kubenet"
    load_balancer_sku = "standard"
    outbound_type     = "loadBalancer"
    # These CIDRs must not overlap with each other or any peered VNet.
    pod_cidr       = "10.244.0.0/16"
    service_cidr   = "10.0.0.0/16"
    dns_service_ip = "10.0.0.10"
  }

  identity {
    type = "SystemAssigned"
  }

  # Required for pod-level Azure auth via federated credentials instead of stored secrets.
  workload_identity_enabled = true
  oidc_issuer_enabled       = true

  # Skipping Container Insights (~$10–30/month log ingestion) for this dev cluster.
  monitor_metrics {}

  web_app_routing {
    dns_zone_ids = [data.azurerm_dns_zone.main.id]
  }

  tags = local.common_tags

  lifecycle {
    # Azure auto-applies patch upgrades; ignoring prevents perpetual plan diffs.
    ignore_changes = [kubernetes_version]
  }
}

# ---------------------------------------------------------------------------
# User node pool — application workloads (Flux, Kyverno, space-taco)
# ---------------------------------------------------------------------------
# Separated from the system pool so AKS infrastructure components and app
# workloads never compete for the same node budget.
# AKS labels every node in this pool with:
#   kubernetes.azure.com/mode: user
# Deployments use nodeSelector on that label to target this pool explicitly.
resource "azurerm_kubernetes_cluster_node_pool" "apps" {
  name                  = "apps"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.aks_node_vm_size
  node_count            = var.aks_user_node_count
  mode                  = "User"

  os_disk_size_gb = 30
  # Ephemeral disk requires VM cache ≥ OS disk size; B-series cache = 0, so use Managed.
  os_disk_type         = "Managed"
  auto_scaling_enabled = false

  upgrade_settings {
    max_surge = "1"
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Supporting data sources and networking
# ---------------------------------------------------------------------------

# rg-management is provisioned outside this stack and pre-dates this Terraform config.
data "azurerm_resource_group" "management" {
  name = var.management_resource_group_name
}

data "azurerm_dns_zone" "main" {
  name                = var.dns_zone_name
  resource_group_name = data.azurerm_resource_group.management.name
}

resource "azurerm_public_ip" "ingress" {
  name                = "pip-ingress-${var.environment}"
  resource_group_name = azurerm_resource_group.aks.name
  location            = azurerm_resource_group.aks.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

# App Routing's external-dns needs DNS Zone Contributor to upsert A records in rg-management.
resource "azurerm_role_assignment" "external_dns_contributor" {
  scope                = data.azurerm_resource_group.management.id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}
