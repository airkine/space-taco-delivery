output "repo_clone_url" {
  description = "HTTPS clone URL"
  value       = github_repository.space_taco.http_clone_url
}

output "repo_ssh_url" {
  description = "SSH clone URL"
  value       = github_repository.space_taco.ssh_clone_url
}

output "repo_full_name" {
  description = "Full repository name (org/repo)"
  value       = github_repository.space_taco.full_name
}

# ---------------------------------------------------------------------------
# AKS outputs
# ---------------------------------------------------------------------------

output "aks_cluster_name" {
  description = "AKS cluster name — use with: az aks get-credentials --name <value> --resource-group <aks_resource_group_name>"
  value       = azurerm_kubernetes_cluster.main.name
}

output "aks_resource_group_name" {
  description = "Resource group containing the AKS cluster"
  value       = azurerm_resource_group.aks.name
}

output "aks_oidc_issuer_url" {
  description = "OIDC issuer URL for the AKS cluster — needed when creating federated credentials for workload identity"
  value       = azurerm_kubernetes_cluster.main.oidc_issuer_url
}

output "aks_kubelet_identity_object_id" {
  description = "Object ID of the kubelet managed identity — currently assigned DNS Zone Contributor on rg-management for external-dns"
  value       = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}

# The raw kubeconfig gives cluster-admin access.  Mark sensitive so Terraform
# never prints it in plan/apply output or CI logs.
output "kube_config" {
  description = "Raw kubeconfig for the AKS cluster (cluster-admin). Retrieve with: terraform output -raw kube_config"
  value       = azurerm_kubernetes_cluster.main.kube_config_raw
  sensitive   = true
}

output "app_url" {
  description = "Public URL of the space-taco app (live once Flux has reconciled the Ingress)"
  value       = "http://taco-delivery.${var.dns_zone_name}"
}

output "ingress_public_ip" {
  description = "Static public IP assigned to the Web App Routing ingress controller"
  value       = azurerm_public_ip.ingress.ip_address
}
