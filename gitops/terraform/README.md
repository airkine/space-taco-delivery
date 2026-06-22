# Space Taco Delivery — Terraform

This directory contains **two independent Terraform root modules**, each with
its own state:

| Module | Manages | State (backend key) |
|--------|---------|----------------------|
| [`github/`](github/) | GitHub repo settings, branch protection, labels, secrets, environments | `space-taco-delivery/github/terraform.tfstate` |
| [`infra/`](infra/) | Azure infrastructure — AKS cluster + Flux bootstrap | `space-taco-delivery/infra/terraform.tfstate` |

## Why two states

Both modules used to live together in this directory as a single Terraform
root with one shared state. The **Terraform Destroy** workflow ran
`terraform destroy` against that combined state to tear down the AKS
cluster — and because `github_repository.space_taco` lived in the same
state, destroy deleted the GitHub repository itself along with the cluster.

Terraform has no built-in way to say "destroy everything except this
resource" within a single state — `lifecycle.prevent_destroy` aborts the
*entire* plan (including the resources you actually want destroyed) the
moment it hits a protected resource, and per-resource `-target`/`-exclude`
flags are easy to forget when new resources are added later. The only
guardrail that can't be bypassed by a future edit to the destroy workflow is
putting the repository in a state file the destroy workflow's
working-directory can never open. That's why `infra/` and `github/` are
separate root modules with separate backend keys: **the destroy workflow's
`working-directory` is pinned to `gitops/terraform/infra` and has no
provider configuration or state reference that could reach the GitHub repo.**

## File layout (per module)

Both `github/` and `infra/` follow the same file layout:

| File | Purpose |
|------|---------|
| `versions.tf` | `terraform {}` block — `required_version`, `required_providers`, `backend "azurerm"` (own key per module) |
| `provider.tf` | `provider "..."` configuration blocks |
| `variables.tf` | Input variable declarations for this module |
| `locals.tf` | Module-local values |
| `main.tf` / `aks.tf` + `flux.tf` | Resource definitions |
| `outputs.tf` | Output values |
| `terraform.tfvars` | Non-sensitive defaults committed to source control |
| `.terraform.lock.hcl` | Provider checksum lock — **committed**, ensures reproducible provider downloads |

## What it builds

### `github/` — GitHub resources

| Resource | Details |
|----------|---------|
| `github_repository` | `space-taco-delivery`, squash-merge only, auto branch deletion |
| `github_branch_protection` | Protects `main`: requires `Lint & Test` + `Build & Publish`, 1 review, signed commits |
| `github_issue_label` | 10 labels across `area/`, `type/`, `priority/` prefixes |
| `github_actions_secret` | Azure OIDC secrets — uses current `value` field (deprecated `plaintext_value` removed in github provider v6) |
| `github_repository_environment` | `dev` — the only GitHub Environment in this repo; requires reviewer approval, protected branches only |

`github_token` here also needs `repo` + `admin:org` scopes (repo administration, secrets, branch protection).

### `infra/` — Azure infrastructure

| Resource | Details |
|----------|---------|
| `azurerm_resource_group` | `rg-space-taco-<env>` in `var.location` |
| `azurerm_kubernetes_cluster` | `aks-space-taco-<env>` — Free tier control plane, **Azure CNI Overlay** networking, workload identity + OIDC issuer enabled, Web App Routing addon with `autoaaron.xyz` DNS zone wired, Istio service mesh add-on (`service_mesh_profile`) enabled. `default_node_pool.temporary_name_for_rotation` is set so changing `aks_node_vm_size` rotates the system pool instead of destroying the whole cluster (see "Swap to x86 if ARM is unavailable" below) |
| `azurerm_kubernetes_cluster_node_pool` | `apps` user pool (1 node) — hosts Flux, Kyverno, and the space-taco application; separated from the system pool so AKS infrastructure and app workloads never compete |
| `azurerm_role_assignment.external_dns_contributor` | Grants **DNS Zone Contributor** on `rg-management` to the **web app routing managed identity** (`web_app_routing[0].web_app_routing_identity[0].object_id`) — this is the MSI that the AKS-managed `external-dns` pod authenticates with; it is distinct from `kubelet_identity` |
| `null_resource.istio_cni_chaining` (`istio.tf`) | One-time `az aks mesh proxy-redirection-mechanism` CLI call — see "Istio service mesh add-on" below for why this can't be a native Terraform resource yet |
| `flux_bootstrap_git` | Installs Flux v2 controllers into the cluster and commits bootstrap manifests to `gitops/flux/flux-system/` |

### Pod networking — Azure CNI Overlay

`network_profile` in `aks.tf` uses **Azure CNI Overlay** (`network_plugin = "azure"`, `network_plugin_mode = "overlay"`), not kubenet. Pod IPs come from `pod_cidr` (`10.244.0.0/16`), a private range that isn't routable on the VNet — same address-space benefit as kubenet, but via the modern CNI dataplane instead of per-node UDRs, which scales further and supports Network Policy enforcement (not currently enabled here, but available without a cluster rebuild if needed later).

**`network_plugin` and `network_plugin_mode` are Day-0, force-new settings** — there is no in-place migration between kubenet/CNI/Overlay. Changing either on an existing cluster makes Terraform destroy and recreate the entire `azurerm_kubernetes_cluster.this` resource (losing the Flux bootstrap state, node pools, and public IP association in the process), not just reconfigure networking. Plan carefully before applying a change here against a live cluster.

### Istio service mesh add-on

The cluster uses the **AKS-managed Istio service mesh add-on**
(`service_mesh_profile` in `aks.tf`) rather than installing upstream Istio
via Helm — that approach is used for the local Kind cluster instead (see
`deploy/kind/bootstrap-local.ps1`/`.sh`), where there's no managed add-on
available.

- **Revision is pinned explicitly** via `local.istio_revision` (`locals.tf`),
  currently `asm-1-28`. This must stay in sync with the `istio.io/rev` label
  on the `space-taco` namespace in `gitops/flux/apps/namespace.yaml` — the
  add-on's injection webhook keys off that exact revision string (the
  generic upstream `istio-injection: enabled` label is a documented no-op
  for the add-on). Before bumping the revision, confirm availability and
  Kubernetes-version compatibility:
  ```bash
  az aks mesh get-revisions --location eastus2 -o table
  ```
- **CNI chaining isn't exposed by the azurerm provider yet**
  ([hashicorp/terraform-provider-azurerm#31177](https://github.com/hashicorp/terraform-provider-azurerm/issues/31177)),
  so `istio.tf` runs `az aks mesh proxy-redirection-mechanism --mechanism
  CNIChaining` via a `null_resource` + `local-exec` provisioner as a
  stopgap. Without it, injected sidecars use the privileged legacy
  `istio-init` container, which Kyverno's `space-taco-pod-security`
  ClusterPolicy rejects — the exact failure mode hit (and fixed) for the
  self-managed Kind install. This requires an authenticated `az` CLI in
  whatever environment runs `terraform apply` — already true in CI
  (`terraform.yml`'s `terraform-infra` job runs `azure/login` first) and
  true locally after `az login`.
- **`external_ingress_gateway_enabled = true`** provisions
  `aks-istio-ingressgateway-external` (a `LoadBalancer` Service in the
  `aks-istio-ingress` namespace) automatically — no separate Helm/Flux
  gateway needed. This is purely additive: the existing Web App Routing
  Ingress keeps serving `taco-delivery.autoaaron.xyz` unchanged. The mesh
  gateway is a *second* entry point for practicing blue/green — find its IP
  with:
  ```bash
  kubectl get svc aks-istio-ingressgateway-external -n aks-istio-ingress
  ```

`infra/` still needs `var.github_token` and `var.github_owner` — not to manage any `github_*` resource (there are none here), but because the `flux` provider authenticates its git push with a plain HTTP username/password (the token), and builds the clone URL from the owner.

### Flux app manifests (`gitops/flux/apps/`)

Managed as YAML; Flux reconciles them after bootstrap:

| Manifest | Purpose |
|----------|---------|
| `namespace.yaml` | `space-taco` namespace with Kyverno label and `istio.io/rev` sidecar-injection label |
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
| Istio external ingress gateway public IP (Standard) | ~$4 |
| Terraform state storage (existing) | ~$1 |
| **Total** | **~$61/month** |

### Swap to x86 if ARM is unavailable

```hcl
# infra/terraform.tfvars
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

- [Terraform](https://developer.hashicorp.com/terraform/install) `~> 1.7` (pinned in each module's `versions.tf`; `>= 1.7` was intentionally narrowed to exclude potential breaking changes in 2.x)
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) — for local auth (`az login`)
- GitHub PAT with `repo` + `workflow` scopes (and `admin:org` for the `github/` module) — see [Secrets](#secrets-and-variables)
- The `rg-terraform-state` resource group and `terraformstate024` storage account must already exist (one-time setup, not managed here)
- **`.terraform.lock.hcl` is committed in both `github/` and `infra/`** — run `terraform init` in each directory to use the pinned provider checksums; do not delete or `.gitignore` them

## Secrets and variables

Each module's `terraform.tfvars` is committed and holds only non-sensitive
config — Terraform auto-loads it for both local runs and CI.

| Variable | Module(s) | Description | Sensitive |
|----------|-----------|-------------|-----------|
| `github_owner` | both | GitHub org or username | No |
| `location` | `infra` | Azure region (default: `eastus2`) | No |
| `environment` | `infra` | Environment label appended to resource names (default: `dev`) | No |
| `aks_node_vm_size` | `infra` | VM SKU for the node pools | No |
| `aks_node_count` / `aks_user_node_count` | `infra` | Node counts per pool | No |
| `kubernetes_version` | `infra` | Kubernetes minor version to pin to, or `null` for latest | No |

**Never add secrets to `terraform.tfvars`.** These are supplied via `TF_VAR_*` environment variables instead:

| Variable | Module(s) | Description | Sensitive |
|----------|-----------|--------------|-----------|
| `github_token` | both | GitHub PAT — needs `repo`, `workflow`, `admin:org` scopes (also used by the `flux` provider in `infra/` to push bootstrap manifests) | Yes |
| `azure_client_id` | `github` | Azure App Registration client ID for OIDC auth (stored as a repo secret, not used by the `github` provider itself) | Yes |
| `azure_tenant_id` | `github` | Azure tenant ID (stored as a repo secret) | Yes |
| `azure_subscription_id` | both | Azure subscription ID — used by the `azurerm` provider in `infra/`, and stored as a repo secret by `github/` | Yes |

### Static security/compliance scanning

Both `terraform-github-plan` and `terraform-infra-plan` (in `terraform.yml`) run `checkov` and `trivy config` against their module's HCL before `terraform init`. Both are **report-only** (`soft_fail` / `exit-code: "0"`) — findings are printed to the job log but never fail the build.

This is deliberate, not a placeholder: this cluster makes several intentional dev-tier cost trade-offs (Free SKU instead of Standard, kubenet instead of Azure CNI, no private cluster / API server IP ranges, no disk encryption set — see "Cost estimate" above) that both scanners flag as findings. Making the step blocking today would fail every run on things this project has already decided not to fix. To promote it to a blocking gate later, add an explicit skip-list for the known/intentional findings first (e.g. a `.checkov.yaml` with `skip-check` entries), then drop `soft_fail`/`exit-code`.

### Local development

```bash
export TF_VAR_github_token=ghp_xxxxxxxxxxxxxxxxxxxx

# Authenticate to Azure
az login
az account set --subscription <subscription-id>
export TF_VAR_azure_subscription_id=<subscription-id>

# Apply github/ first so the repo exists before infra/ tries to push to it
cd gitops/terraform/github
terraform init && terraform plan && terraform apply

cd ../infra
terraform init && terraform plan && terraform apply
```

### GitHub Actions (CI)

Non-sensitive config comes from each module's committed `terraform.tfvars` —
edit the relevant file to change it.

#### Workflow trigger matrix (`terraform.yml`)

The workflow runs **four** jobs — a plan job and an apply job per state:
`terraform-github-plan` → `terraform-github-apply`, and
`terraform-infra-plan` → `terraform-infra-apply` (`needs:` ordering only;
there's no Terraform resource dependency between the states).

Plan jobs carry no `environment:` and always run immediately. Apply jobs
carry `environment: dev`, which requires a reviewer to click **Approve and
deploy** before any apply step runs — see [Approving an
apply](#approving-an-apply) below.

| Trigger | Branch | Plan jobs | Apply jobs |
|---------|--------|-----------|------------|
| `push` | `main` | ✓ | ✓ (after reviewer approval) |
| `pull_request` | any → `main` | ✓ (comment on PR) | ✗ (skipped — not queued for review) |
| `workflow_dispatch` | `main` (apply input = true) | ✓ | ✓ (after reviewer approval) |
| `workflow_dispatch` | `main` (apply input = false) | ✓ | ✗ (skipped) |
| `workflow_dispatch` | non-main | ✓ | ✗ always — branch guard |

**Manual dispatch** is useful to force-apply after an out-of-band change (e.g. a role assignment applied via `az rest`), or to verify drift without committing anything. Navigate to **Actions → Terraform → Run workflow**, select the branch, and uncheck `apply` if you only want a plan.

#### Approving an apply

Because the apply jobs run under the `dev` GitHub Environment (which has a
required reviewer — see `gitops/terraform/github/main.tf`), a queued apply
shows up as a **pending deployment** rather than running immediately. The
plan it would apply is *already visible* by then: the matching plan job
(`terraform-github-plan` or `terraform-infra-plan`) has already finished in
the same workflow run, so its output is sitting in the job log (and, for PR
runs, as a comment on the PR). Read that plan, then approve the apply job
from **Actions → \<run\> → Review deployments**.

Secrets are stored as GitHub Actions **Secrets** and injected as `TF_VAR_*`:

| GitHub Secret | Used by | Purpose |
|--------------|---------|---------|
| `TF_GITHUB_TOKEN` | both jobs | PAT used by Terraform's GitHub + flux providers — needs `repo` + `workflow` + `admin:org` scopes |
| `AZURE_CLIENT_ID` | both jobs | App Registration client ID for OIDC auth (`infra` uses it to log in to Azure; `github` writes it as a repo secret) |
| `AZURE_TENANT_ID` | both jobs | Azure tenant ID |
| `AZURE_SUBSCRIPTION_ID` | both jobs | Azure subscription ID |

## First-time apply

On first apply (in order):

1. `terraform-github-plan` produces the plan, then (after reviewer approval) `terraform-github-apply` creates the repo, branch protection, labels, secrets, the `dev` environment
2. `terraform-infra-plan` produces the plan, then (after reviewer approval) `terraform-infra-apply` provisions the AKS cluster (~5-8 minutes), including the Istio service mesh add-on
3. `terraform-infra-apply` runs the `null_resource.istio_cni_chaining` `az aks mesh` call to switch the add-on to CNI chaining mode
4. `terraform-infra-apply` runs `flux_bootstrap_git` — installs Flux controllers into the cluster and pushes manifests to `gitops/flux/flux-system/` (**this creates a new commit on `main`**)
5. Flux discovers `gitops/flux/apps/` and reconciles Kyverno then the space-taco HelmRelease

After apply, verify:

```bash
# Get kubeconfig
az aks get-credentials --name aks-space-taco-dev --resource-group rg-space-taco-dev

# Check Flux
flux get all -A

# Check the Istio add-on
az aks show --resource-group rg-space-taco-dev --name aks-space-taco-dev --query 'serviceMeshProfile.mode'
kubectl get pods -n aks-istio-system

# Watch the app
kubectl get helmrelease -n space-taco
kubectl get pods -n space-taco   # expect 2/2 (app + istio-proxy sidecar)

# Access the UI
kubectl port-forward -n space-taco svc/space-taco 8080:80
# → http://localhost:8080

# Access the public URL (once DNS propagates, ~60s after Ingress is admitted)
curl http://taco-delivery.autoaaron.xyz/healthz

# Access the Istio gateway directly (second entry point, for blue/green practice)
GATEWAY_IP=$(kubectl get svc aks-istio-ingressgateway-external -n aks-istio-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -H "Host: taco-delivery.autoaaron.xyz" "http://${GATEWAY_IP}/healthz"
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
| `terraform destroy` deleted the GitHub repository | `github_repository` lived in the same state as the AKS cluster, so a destroy run against the combined state removed both | Fixed: split into `github/` and `infra/` modules with separate state files; the Terraform Destroy workflow's `working-directory` is pinned to `gitops/terraform/infra` and can never reach the repo's state. See "Why two states" above. |
| `space-taco` pods stuck with the `istio-init` container rejected by Kyverno (`NET_ADMIN`/`NET_RAW`/`runAsUser=0` forbidden) | CNI chaining wasn't applied — `null_resource.istio_cni_chaining`'s `local-exec` either didn't run (no `az` CLI session) or ran before the add-on finished installing | Run manually: `az aks mesh proxy-redirection-mechanism --resource-group rg-space-taco-dev --name aks-space-taco-dev --mechanism CNIChaining`, then `kubectl rollout restart deployment -n space-taco` |
| Sidecar not injected into `space-taco` pods at all | Namespace label `istio.io/rev` doesn't match the revision actually installed (e.g. `locals.tf`'s `istio_revision` was bumped without checking `az aks mesh get-revisions` first) | Check `az aks show ... --query 'serviceMeshProfile.istio.revisions'` and make sure `gitops/flux/apps/namespace.yaml`'s `istio.io/rev` label matches exactly |

## Destroying infrastructure

### AKS / Flux (`infra/`) — via GitHub Actions (recommended)

Use the **Terraform Destroy** workflow (`.github/workflows/terraform-destroy.yml`) for a fully audited teardown of the AKS cluster and Flux bootstrap. **This workflow cannot delete the GitHub repository** — it only ever runs against `gitops/terraform/infra`, a separate state with no `github_*` resources in it.

1. Navigate to **Actions → Terraform Destroy → Run workflow**
2. Leave the branch set to `main`
3. Type `destroy` in the confirmation field (exact, case-sensitive)
4. Click **Run workflow**

The workflow runs two jobs:
- **`destroy-plan`** — runs the branch/confirmation gates, then logs every resource that will be removed (permanent audit trail in the run log)
- **`destroy-apply`** — gated by the `dev` GitHub Environment (requires reviewer approval, same as `terraform.yml`'s apply jobs); applies the exact plan `destroy-plan` produced. By the time you're prompted to approve, `destroy-plan`'s output is already sitting in the job log/summary, so you're never approving a teardown blind.

Safety gates that abort before touching any infrastructure:
- Branch must be `main` (feature branches are rejected)
- Confirmation input must equal `destroy` exactly
- A reviewer must approve the `destroy-apply` job's pending deployment

### AKS / Flux (`infra/`) — locally

```bash
cd gitops/terraform/infra
terraform destroy
```

### GitHub repository (`github/`) — locally only

There is intentionally no GitHub Actions workflow for destroying the
`github/` state — repo deletion should always be a deliberate, local,
human-run action:

```bash
cd gitops/terraform/github
terraform destroy
```
