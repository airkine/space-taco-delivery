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

    # Without this, the azurerm provider treats vm_size (and zones) on the
    # default_node_pool as force-new: changing aks_node_vm_size in
    # terraform.tfvars (see ../README.md "Swap to x86 if ARM is unavailable")
    # would destroy and recreate the ENTIRE cluster, not just the pool. With
    # it set, Terraform spins up a temporary pool under this name, migrates
    # workloads, then deletes the old one — a non-disruptive in-place resize.
    # The name just needs to be unused and ≤ 12 chars; it only exists transiently
    # during a resize and is never referenced anywhere else.
    temporary_name_for_rotation = "systemtmp"

    upgrade_settings {
      max_surge = "1"
    }
  }

  network_profile {
    # Azure CNI Overlay: pod IPs come from pod_cidr (below), a private range
    # that's NOT routable on the VNet — unlike "vanilla" Azure CNI, which
    # assigns pods real VNet IPs and burns through subnet address space fast.
    # kubenet (the previous setting) gave the same "private pod range" benefit
    # but does so via per-node UDRs, which don't scale past ~400 nodes and
    # don't support Network Policy enforcement at the dataplane. Overlay is
    # the modern replacement for kubenet for exactly that reason.
    #
    # network_plugin and network_plugin_mode are both Day-0 / force-new
    # settings on azurerm_kubernetes_cluster — changing either one after the
    # cluster exists destroys and recreates the whole cluster, not just a
    # node pool. There is no in-place migration path.
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
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

  # Istio-based service mesh add-on — the AKS-managed Istio control plane
  # (istiod, CNI, ingress gateway), as opposed to installing upstream Istio
  # via Helm ourselves. https://learn.microsoft.com/azure/aks/istio-about
  #
  # external_ingress_gateway_enabled provisions a LoadBalancer Service
  # (aks-istio-ingressgateway-external, in the aks-istio-ingress namespace)
  # automatically — no separate Helm/Flux-managed gateway needed. This is
  # purely additive: the existing Web App Routing ingress above is untouched
  # and keeps serving taco-delivery.autoaaron.xyz exactly as before. The
  # mesh gateway is a *second* entry point to practice blue/green against —
  # find its IP with:
  #   kubectl get svc aks-istio-ingressgateway-external -n aks-istio-ingress
  #
  # NOTE: this block does NOT enable Istio CNI chaining — the azurerm
  # provider doesn't expose that setting yet
  # (https://github.com/hashicorp/terraform-provider-azurerm/issues/31177).
  # See istio.tf for the one-time `az aks mesh` CLI call that enables it;
  # without it, injected sidecars use the privileged legacy istio-init
  # container, which Kyverno's space-taco-pod-security ClusterPolicy rejects.
  service_mesh_profile {
    mode                             = "Istio"
    revisions                        = [local.istio_revision]
    external_ingress_gateway_enabled = true
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

# App Routing's external-dns pod runs as the web_app_routing managed identity, NOT the
# kubelet identity.  Granting DNS Zone Contributor to the wrong principal was the root
# cause of the CrashLoopBackOff on external-dns (403 on dnsZones/read in rg-management).
resource "azurerm_role_assignment" "external_dns_contributor" {
  scope                = data.azurerm_resource_group.management.id
  role_definition_name = "DNS Zone Contributor"
  # web_app_routing_identity is the MSI that external-dns authenticates with;
  # it is distinct from kubelet_identity and created automatically by AKS.
  principal_id = azurerm_kubernetes_cluster.this.web_app_routing[0].web_app_routing_identity[0].object_id
}
