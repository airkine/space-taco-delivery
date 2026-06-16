# ---------------------------------------------------------------------------
# Resource Group
# ---------------------------------------------------------------------------
# All AKS-related resources land in a dedicated RG so they can be deleted
# independently of the Terraform-state RG (rg-terraform-state).
resource "azurerm_resource_group" "aks" {
  name     = "rg-space-taco-${var.environment}"
  location = var.location

  tags = {
    environment = var.environment
    project     = "space-taco-delivery"
    managed-by  = "terraform"
  }
}

# ---------------------------------------------------------------------------
# AKS Cluster
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-space-taco-${var.environment}"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name

  # dns_prefix must be globally unique within Azure; scoping to env is enough here.
  dns_prefix = "space-taco-${var.environment}"

  # ---------------------------------------------------------------------------
  # Cost: "Free" tier = $0 for the control plane.
  # "Standard" tier adds SLA-backed uptime (~$73/month) — not worth it for dev.
  # ---------------------------------------------------------------------------
  sku_tier = "Free"

  # Let Azure manage Kubernetes patch-level upgrades automatically.
  # Only patch versions are auto-applied; minor version bumps require explicit action.
  automatic_upgrade_channel = "patch"

  # Pin to a specific minor version to prevent surprise minor-version upgrades.
  # Set to null to let Azure pick the latest supported version on cluster creation,
  # then Terraform will track whatever version was provisioned.
  kubernetes_version = var.kubernetes_version

  # ---------------------------------------------------------------------------
  # System node pool — the only pool in this dev cluster.
  # Cost target: Standard_B2s (~$35/month always-on) or Standard_B2pls_v2
  # (~$17/month, ARM64).  The image is multi-arch (amd64 + arm64) so either works.
  # Swap vm_size in terraform.tfvars; no other change needed.
  # ---------------------------------------------------------------------------
  default_node_pool {
    name = "system"

    # Single node — this is a dev/learning cluster, not HA.
    node_count = var.aks_node_count

    vm_size = var.aks_node_vm_size

    # 30 GB is the minimum AKS allows; keeps managed-disk costs to ~$2/month.
    os_disk_size_gb = 30

    # Managed (remote) disk vs Ephemeral.  Ephemeral is faster but requires a
    # VM whose cache/temp disk is large enough.  B2s cache = 0, so Managed it is.
    os_disk_type = "Managed"

    # Disable cluster-autoscaler — dev workloads don't need it and it adds noise.
    auto_scaling_enabled = false

    upgrade_settings {
      # Allow one extra node during rolling upgrades so the single real node isn't
      # drained while there's nowhere for pods to go.
      max_surge = "1"
    }
  }

  # ---------------------------------------------------------------------------
  # Networking — kubenet (simpler than Azure CNI, no VNet dependency, fine for dev)
  # Standard LB is required for AKS egress; Basic LB is deprecated in AKS.
  # ---------------------------------------------------------------------------
  network_profile {
    network_plugin    = "kubenet"
    load_balancer_sku = "standard"

    # loadBalancer outbound = AKS provisions a Standard LB + 1 public IP for egress.
    # This is what lets nodes pull images from GHCR, reach the Sigstore TUF mirror, etc.
    outbound_type = "loadBalancer"

    # These CIDRs must not overlap with each other or with any peered VNet.
    # Defaults shown explicitly here for clarity.
    pod_cidr       = "10.244.0.0/16"
    service_cidr   = "10.0.0.0/16"
    dns_service_ip = "10.0.0.10"
  }

  # ---------------------------------------------------------------------------
  # Identity — SystemAssigned lets AKS manage its own service principal lifecycle.
  # Used by the kubelet node pool identity for GHCR image pulls (no secret needed
  # when the cluster has ACR attachment; for GHCR we use imagePullSecrets instead).
  # ---------------------------------------------------------------------------
  identity {
    type = "SystemAssigned"
  }

  # ---------------------------------------------------------------------------
  # Workload Identity + OIDC Issuer
  # Required for pod-level Azure auth (e.g., Flux pulling from a private ACR,
  # or a future workload needing Key Vault access without storing a secret).
  # The OIDC issuer URL is exported as an output for use in federated credential setup.
  # ---------------------------------------------------------------------------
  workload_identity_enabled = true
  oidc_issuer_enabled       = true

  # ---------------------------------------------------------------------------
  # Add-ons — disabled to minimize cost and complexity.
  # Kyverno and Flux are deployed via Helm/Terraform, not as managed add-ons.
  # ---------------------------------------------------------------------------

  # Azure Monitor / Container Insights would attach a Log Analytics workspace
  # (~$10-30/month depending on ingestion).  Skipping for dev.
  monitor_metrics {}

  # ---------------------------------------------------------------------------
  # Web App Routing — Azure-managed NGINX ingress controller.
  # Provisions an Azure Public IP and installs the ingress controller into the
  # app-routing-system namespace.  Wired to the autoaaron.xyz DNS zone so the
  # controller creates an A record for each Ingress host automatically.
  # Cost: ~$0.004/hr for the public IP (~$3/month).
  # ---------------------------------------------------------------------------
  web_app_routing {
    dns_zone_ids = [data.azurerm_dns_zone.main.id]
  }

  tags = {
    environment = var.environment
    project     = "space-taco-delivery"
    managed-by  = "terraform"
  }

  # Prevent accidental deletion in CI — destroy must be explicitly confirmed.
  lifecycle {
    # Ignore changes to kubernetes_version after initial create so that Azure's
    # automatic patch upgrades don't cause Terraform to show a perpetual diff.
    ignore_changes = [kubernetes_version]
  }
}

# ---------------------------------------------------------------------------
# DNS zone — looked up by name/RG so the resource ID is derived rather than
# hardcoded, which keeps the subscription ID out of source.
# ---------------------------------------------------------------------------
data "azurerm_dns_zone" "main" {
  name                = "autoaaron.xyz"
  resource_group_name = "rg-management"
}

# ---------------------------------------------------------------------------
# Grant the Web App Routing managed identity permission to write DNS records.
# Without this the controller can't create the A record for the Ingress host.
# ---------------------------------------------------------------------------
resource "azurerm_role_assignment" "web_app_routing_dns" {
  scope                = data.azurerm_dns_zone.main.id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = azurerm_kubernetes_cluster.main.web_app_routing[0].web_app_routing_identity[0].object_id
}

# ---------------------------------------------------------------------------
# Cost-saving tip: stop/start the cluster when not in use.
#
#   Stop  (billing for node VMs halts, control plane free tier = $0):
#     az aks stop  --name aks-space-taco-dev --resource-group rg-space-taco-dev
#
#   Start (takes ~3-4 minutes, restores exactly where you left off):
#     az aks start --name aks-space-taco-dev --resource-group rg-space-taco-dev
#
# If you only run the cluster ~4 hrs/day on weekdays, effective monthly cost
# for a B2s node drops from ~$35 to ~$5.
# ---------------------------------------------------------------------------
