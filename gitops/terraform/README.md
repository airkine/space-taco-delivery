# Space Taco Delivery — Terraform

This Terraform configuration manages two things:
1. **GitHub resources** — repo settings, branch protection, labels, secrets, environments
2. **Azure infrastructure** — AKS cluster (free tier, single node) + Flux bootstrap

## What it builds

### GitHub resources

| Resource | Details |
|----------|---------|
| `github_repository` | `space-taco-delivery`, squash-merge only, auto branch deletion |
| `github_branch_protection` | Protects `main`: requires `Lint & Test` + `Build & Publish`, 1 review, signed commits |
| `github_issue_label` | 10 labels across `area/`, `type/`, `priority/` prefixes |
| `github_actions_secret` | `COSIGN_PASSWORD`, Azure OIDC secrets |
| `github_repository_environment` | `dev` (unprotected) and `prod` (requires reviewer, protected branches only) |

### Azure infrastructure

| Resource | Details |
|----------|---------|
| `azurerm_resource_group` | `rg-space-taco-<env>` in `var.location` |
| `azurerm_kubernetes_cluster` | `aks-space-taco-<env>` — Free tier control plane, single `Standard_B2s` node, kubenet, workload identity + OIDC issuer enabled |
| `flux_bootstrap_git` | Installs Flux v2 controllers into the cluster and commits bootstrap manifests to `gitops/flux/flux-system/` |

### Flux app manifests (`gitops/flux/apps/`)

Managed as YAML; Flux reconciles them after bootstrap:

| Manifest | Purpose |
|----------|---------|
| `namespace.yaml` | `space-taco` namespace with Kyverno label |
| `helmrepository-ghcr.yaml` | OCI HelmRepository pointing at GHCR |
| `kustomization-kyverno.yaml` | Kyverno HelmRepository + HelmRelease (admission controller) |
| `helmrelease-space-taco.yaml` | HelmRelease for the app — latest chart from GHCR, single replica, no Redis |
| `kustomization.yaml` | Flux Kustomization wiring everything together, Kyverno health-checked before space-taco |

## Cost estimate (dev cluster, always-on)

| Component | Monthly cost |
|-----------|-------------|
| AKS control plane (Free tier) | $0 |
| 1× `Standard_B2s` node (2 vCPU / 4 GiB) | ~$35 |
| OS disk (30 GB managed) | ~$2 |
| Standard Load Balancer (egress) | ~$18 |
| Terraform state storage (existing) | ~$1 |
| **Total** | **~$56/month** |

### Cheaper: `Standard_B2pls_v2` (ARM64, ~$17/month node)

Set in `terraform.tfvars` — the app image is multi-arch so ARM is fine:
```hcl
location         = "eastus2"   # B2pls_v2 available in eastus2, westus2, westeurope
aks_node_vm_size = "Standard_B2pls_v2"
```
Effective total: ~$38/month.

### Cut costs further: stop the cluster when not in use

AKS stop/start halts node VM billing entirely. The Free-tier control plane has no charge either way.

```bash
# Stop (billing for nodes halts — takes ~1 min):
az aks stop  --name aks-space-taco-dev --resource-group rg-space-taco-dev

# Start (takes ~3-4 min, restores exactly where you left off):
az aks start --name aks-space-taco-dev --resource-group rg-space-taco-dev
```

Running ~4 hrs/day on weekdays drops effective node cost from ~$35 to ~$5/month.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.7
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) — for local auth (`az login`)
- GitHub PAT with `repo` + `workflow` scopes — see [Secrets](#secrets-and-variables)
- The `rg-terraform-state` resource group and `terraformstate024` storage account must already exist (one-time setup, not managed here)

## Secrets and variables

`terraform.tfvars` is committed and holds only non-sensitive config — Terraform auto-loads it for both local runs and CI.

| Variable | Description | Sensitive |
|----------|-------------|-----------|
| `github_owner` | GitHub org or username | No |
| `location` | Azure region (default: `eastus2`) | No |
| `environment` | Environment label appended to resource names (default: `dev`) | No |
| `aks_node_vm_size` | VM SKU for the node pool (default: `Standard_B2s`) | No |
| `aks_node_count` | Node count (default: `1`) | No |
| `kubernetes_version` | Kubernetes minor version to pin to, or `null` for latest | No |

**Never add secrets to `terraform.tfvars`.** These are supplied via `TF_VAR_*` environment variables instead:

| Variable | Description | Sensitive |
|----------|-------------|-----------|
| `github_token` | GitHub PAT — needs `repo`, `workflow` scopes (also used by flux provider to push bootstrap manifests) | Yes |
| `cosign_password` | Cosign key password — leave empty for keyless signing | Yes |
| `azure_client_id` | Azure App Registration client ID for OIDC auth | Yes |
| `azure_tenant_id` | Azure tenant ID | Yes |
| `azure_subscription_id` | Azure subscription ID | Yes |

### Local development

```bash
export TF_VAR_github_token=ghp_xxxxxxxxxxxxxxxxxxxx

# Authenticate to Azure
az login
az account set --subscription <subscription-id>
export TF_VAR_azure_subscription_id=<subscription-id>

terraform init
terraform plan
terraform apply
```

### GitHub Actions (CI)

AKS/Flux/GitHub config (`location`, `environment`, `aks_node_vm_size`, `aks_node_count`, `github_owner`, `kubernetes_version`) comes from the committed `terraform.tfvars` — edit that file to change them.

Secrets are stored as GitHub Actions **Secrets** and injected as `TF_VAR_*`:

| GitHub Secret | Purpose |
|--------------|---------|
| `TF_GITHUB_TOKEN` | PAT used by Terraform's GitHub + flux providers — needs `repo` + `workflow` scopes |
| `COSIGN_PASSWORD` | Cosign signing key password |
| `AZURE_CLIENT_ID` | App Registration client ID for OIDC auth |
| `AZURE_TENANT_ID` | Azure tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID |

## First-time apply

On first apply Terraform will:

1. Create GitHub repo resources
2. Provision the AKS cluster (~5-8 minutes)
3. Run `flux_bootstrap_git` — installs Flux controllers into the cluster and pushes manifests to `gitops/flux/flux-system/` (**this creates a new commit on `main`**)
4. Flux discovers `gitops/flux/apps/` and reconciles Kyverno then the space-taco HelmRelease

After apply, verify:

```bash
# Get kubeconfig
az aks get-credentials --name aks-space-taco-dev --resource-group rg-space-taco-dev

# Check Flux
flux get all -A

# Watch the app
kubectl get helmrelease -n space-taco
kubectl get pods -n space-taco

# Access the UI
kubectl port-forward -n space-taco svc/space-taco 8080:80
# → http://localhost:8080
```

## Destroying the cluster

```bash
terraform destroy
```
