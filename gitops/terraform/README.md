# Space Taco Delivery — Terraform

This Terraform configuration manages two things:
1. **GitHub resources** — repo settings, branch protection, labels, secrets, environments
2. **Azure infrastructure** — AKS cluster (free tier, single node) + Flux bootstrap

## File layout

| File | Purpose |
|------|---------|
| `versions.tf` | `terraform {}` block — `required_version`, `required_providers`, `backend "azurerm"` |
| `provider.tf` | `provider "..."` configuration blocks |
| `variables.tf` | All input variable declarations |
| `locals.tf` | Shared `common_tags` local |
| `main.tf` | GitHub resources (repo, branch protection, labels, secrets, environments) |
| `aks.tf` | Azure resources (resource group, AKS cluster, public IP, DNS role assignment) |
| `flux.tf` | Flux bootstrap via `flux_bootstrap_git` |
| `outputs.tf` | All output values |
| `terraform.tfvars` | Non-sensitive defaults committed to source control |
| `.terraform.lock.hcl` | Provider checksum lock — **committed**, ensures reproducible provider downloads |

## What it builds

### GitHub resources

| Resource | Details |
|----------|---------|
| `github_repository` | `space-taco-delivery`, squash-merge only, auto branch deletion |
| `github_branch_protection` | Protects `main`: requires `Lint & Test` + `Build & Publish`, 1 review, signed commits |
| `github_issue_label` | 10 labels across `area/`, `type/`, `priority/` prefixes |
| `github_actions_secret` | `COSIGN_PASSWORD`, Azure OIDC secrets — uses current `value` field (deprecated `plaintext_value` removed in github provider v6) |
| `github_repository_environment` | `dev` (unprotected) and `prod` (requires reviewer, protected branches only) |

### Azure infrastructure

| Resource | Details |
|----------|---------|
| `azurerm_resource_group` | `rg-space-taco-<env>` in `var.location` |
| `azurerm_kubernetes_cluster` | `aks-space-taco-<env>` — Free tier control plane, kubenet, workload identity + OIDC issuer enabled, Web App Routing addon with `autoaaron.xyz` DNS zone wired |
| `azurerm_kubernetes_cluster_node_pool` | `apps` user pool (1 node) — hosts Flux, Kyverno, and the space-taco application; separated from the system pool so AKS infrastructure and app workloads never compete |
| `azurerm_role_assignment.external_dns_contributor` | Grants **DNS Zone Contributor** on `rg-management` to the **web app routing managed identity** (`web_app_routing[0].web_app_routing_identity[0].object_id`) — this is the MSI that the AKS-managed `external-dns` pod authenticates with; it is distinct from `kubelet_identity` |
| `flux_bootstrap_git` | Installs Flux v2 controllers into the cluster and commits bootstrap manifests to `gitops/flux/flux-system/` |

### Flux app manifests (`gitops/flux/apps/`)

Managed as YAML; Flux reconciles them after bootstrap:

| Manifest | Purpose |
|----------|---------|
| `namespace.yaml` | `space-taco` namespace with Kyverno label |
| `helmrepository-ghcr.yaml` | OCI HelmRepository pointing at GHCR |
| `kustomization-kyverno.yaml` | Kyverno HelmRepository + HelmRelease (admission controller). `retries` is nested under `remediation:` — placing it directly under `install:` or `upgrade:` is a Flux v2 schema validation error that blocks the entire `apps` kustomization. |
| `helmrelease-space-taco.yaml` | HelmRelease for the app — latest chart from GHCR, single replica, no Redis. Same `retries`-under-`remediation` convention applies. |
| `kustomization.yaml` | Flux Kustomization wiring everything together, Kyverno health-checked before space-taco |

## Node pool architecture

Two node pools keep AKS infrastructure and application workloads on separate nodes:

| Pool | Name | Mode | Nodes | Workloads |
|------|------|------|-------|-----------|
| System | `system` | `System` | 1 | CoreDNS, konnectivity-agent, azure-cni (AKS-managed) |
| User | `apps` | `User` | 1 | Flux controllers, Kyverno, space-taco |

AKS automatically labels every user-pool node with `kubernetes.azure.com/mode: user`. All application deployments carry `nodeSelector: kubernetes.azure.com/mode: user` to target this pool explicitly.

## Cost estimate (dev cluster, always-on)

| Component | Monthly cost |
|-----------|-------------|
| AKS control plane (Free tier) | $0 |
| 1× system node `Standard_B2pls_v2` (ARM64, 2 vCPU / 4 GiB) | ~$17 |
| 1× user node `Standard_B2pls_v2` (ARM64, 2 vCPU / 4 GiB) | ~$17 |
| OS disks (2× 30 GB managed) | ~$4 |
| Standard Load Balancer (egress) | ~$18 |
| Terraform state storage (existing) | ~$1 |
| **Total** | **~$57/month** |

### Swap to x86 if ARM is unavailable

```hcl
# terraform.tfvars
aks_node_vm_size = "Standard_B2s"   # ~$35/month per node → ~$88/month total
```

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

- [Terraform](https://developer.hashicorp.com/terraform/install) `~> 1.7` (pinned in `versions.tf`; `>= 1.7` was intentionally narrowed to exclude potential breaking changes in 2.x)
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) — for local auth (`az login`)
- GitHub PAT with `repo` + `workflow` scopes — see [Secrets](#secrets-and-variables)
- The `rg-terraform-state` resource group and `terraformstate024` storage account must already exist (one-time setup, not managed here)
- **`.terraform.lock.hcl` is committed** — run `terraform init` to use the pinned provider checksums; do not delete or `.gitignore` it

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

#### Workflow trigger matrix

| Trigger | Branch | Plan | Apply |
|---------|--------|------|-------|
| `push` | `main` | ✓ | ✓ |
| `pull_request` | any → `main` | ✓ (comment on PR) | ✗ |
| `workflow_dispatch` | `main` (apply input = true) | ✓ | ✓ |
| `workflow_dispatch` | `main` (apply input = false) | ✓ | ✗ |
| `workflow_dispatch` | non-main | ✓ | ✗ always — branch guard |

**Manual dispatch** is useful to force-apply after an out-of-band change (e.g. a role assignment applied via `az rest`), or to verify drift without committing anything. Navigate to **Actions → Terraform → Run workflow**, select the branch, and uncheck `apply` if you only want a plan.

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

# Access the public URL (once DNS propagates, ~60s after Ingress is admitted)
curl http://taco-delivery.autoaaron.xyz/healthz
```

## Troubleshooting — AKS-specific

| Symptom | Cause | Fix |
|---------|-------|-----|
| `external-dns` pod CrashLoopBackOff with 403 Forbidden | `azurerm_role_assignment.external_dns_contributor` was targeting `kubelet_identity` instead of `web_app_routing_identity` | Fixed: principal_id now uses `web_app_routing[0].web_app_routing_identity[0].object_id`. Apply the role immediately with `az rest --method PUT` if Terraform can't run. |
| Flux kustomization stuck: `.spec.install.retries field not declared in schema` | Flux v2 requires `retries` under `.spec.install.remediation.retries`, not directly under `.spec.install` | Fixed: moved `retries` under `remediation` in `kustomization-kyverno.yaml` and `helmrelease-space-taco.yaml`. |
| `HelmRepository` not found (v1beta2) | Flux v2.4.0 removed `source.toolkit.fluxcd.io/v1beta2`; all HelmRepository resources must use `v1` | Fixed: updated `apiVersion` in both `helmrepository-ghcr.yaml` and `kustomization-kyverno.yaml`. |
| Kyverno HelmRelease: `ClusterPolicy NotFound` | Space-taco HelmRelease was applying simultaneously with Kyverno, before its CRDs were registered | Fixed: added `dependsOn: kyverno` to `helmrelease-space-taco.yaml`. |
| `exec format error` in space-taco pod | `GOARCH=amd64` was hardcoded in the Dockerfile, producing an amd64 binary even in the arm64 image layer | Fixed: switched to `ARG TARGETARCH` so each platform in the multi-arch build compiles the correct binary. |
| Kyverno pods `Pending` with node affinity error | Chart default `nodeSelector: {kubernetes.azure.com/mode: user}` matched nothing when the user node pool isn't provisioned | Fixed: changed chart default to `nodeSelector: {}`. Override per environment if a user pool exists. |

## Destroying the cluster

```bash
terraform destroy
```
