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
| `azurerm_kubernetes_cluster_node_pool` | `apps` user pool — hosts Flux, Kyverno, cert-manager, istiod, and the space-taco application; separated from the system pool so AKS infrastructure and app workloads never compete. Sized via the independent `aks_apps_node_vm_size` variable (not `aks_node_vm_size`) — see "Cost estimate" below. Also carries `temporary_name_for_rotation` for the same reason as `default_node_pool`, since changing its `vm_size` is force-new |
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

**Sidecar resource sizing.** The add-on's mesh-wide `ProxyConfig` default (100m CPU / 128Mi request, 2 CPU / 1Gi limit per sidecar) is sized for production, not this dev cluster — there's no `service_mesh_profile` field or other Terraform/Helm lever to change that default, since it lives in the AKS-managed add-on's own config. `helmrelease-space-taco.yaml`'s `podAnnotations` overrides it per-pod instead, via the standard `sidecar.istio.io/proxyCPU`/`proxyMemory`/`proxyCPULimit`/`proxyMemoryLimit` annotations (down to 20m CPU / 64Mi request, 500m CPU / 256Mi limit). `istiod` itself (500m CPU / 2Gi request × 2 replicas) has the same "can't tune it, it's managed" problem but no per-pod annotation workaround — it's the largest single resource consumer on this cluster and just has to be budgeted for.

### Flux app manifests (`gitops/flux/apps/`)

Managed as YAML; Flux reconciles them after bootstrap:

| Manifest | Purpose |
|----------|---------|
| `namespace.yaml` | `space-taco` namespace with Kyverno label and `istio.io/rev` sidecar-injection label |
| `helmrepository-ghcr.yaml` | OCI HelmRepository pointing at GHCR |
| `kustomization-kyverno.yaml` | Kyverno HelmRepository + HelmRelease (admission controller). `retries` is nested under `remediation:` — placing it directly under `install:` or `upgrade:` is a Flux v2 schema validation error that blocks the entire `apps` kustomization. |
| `helmrelease-space-taco.yaml` | HelmRelease for the app — latest chart from GHCR, single replica, no Redis. Same `retries`-under-`remediation` convention applies. |
| `kustomization.yaml` | Flux Kustomization wiring everything together, Kyverno health-checked before space-taco |

### TLS — cert-manager + Let's Encrypt (`gitops/flux/cert-manager/`, `gitops/flux/cert-manager-issuers/`)

Both public entry points (the Web App Routing Ingress and the Istio Gateway)
terminate TLS with a free, auto-renewing Let's Encrypt certificate via
[cert-manager](https://cert-manager.io/), rather than an Azure-native option.
Why: Azure's "native" TLS path for Web App Routing (Key Vault-backed
certs via the `kubernetes.azure.com/tls-cert-keyvault-uri` annotation)
doesn't generate a certificate — Key Vault only *stores* one, so you'd still
need a cert from a paid CA via Key Vault's partner integration, or you'd be
manually importing a Let's Encrypt cert anyway, which is cert-manager's job
with extra steps. Azure Front Door/Application Gateway managed certificates
are the other "native" option, but both add $35–125+/month of infrastructure
this dev cluster doesn't otherwise need. cert-manager's only cost is the
small compute footprint of its own controller/webhook/cainjector pods,
running on nodes this cluster already pays for.

Split into two Flux Kustomizations (siblings of `apps`, wired in
`gitops/flux/kustomization.yaml`), not folded into one, because the
ClusterIssuer/Certificate objects in the second are Custom Resources that
don't exist until the first's HelmRelease has installed cert-manager's CRDs:

| Kustomization / path | Contents |
|----------|---------|
| `cert-manager` → `gitops/flux/cert-manager/` | `namespace.yaml`, `helmrepository-jetstack.yaml`, `helmrelease-cert-manager.yaml` — the cert-manager controller/webhook/cainjector, with `crds.enabled: true` and trimmed resource requests (see "Cost estimate" below) |
| `cert-manager-issuers` → `gitops/flux/cert-manager-issuers/` (`dependsOn: cert-manager`) | `clusterissuer-letsencrypt-staging.yaml`, `clusterissuer-letsencrypt-prod.yaml`, `certificate-istio-gateway-tls.yaml` |

Both ClusterIssuers solve the ACME HTTP-01 challenge through the **same**
Web App Routing ingress class (`webapprouting.kubernetes.azure.com`) — the
only controller that the `taco-delivery.autoaaron.xyz` DNS record (managed
by external-dns) actually resolves to. This is also how the Istio Gateway's
certificate gets validated, even though the Istio gateway itself is reached
by raw IP + Host header, not DNS (see root `README.md`'s "Blue/Green with
Istio") — ACME only validates domain ownership over HTTP, independent of
which service the resulting certificate is later mounted into.

**Promoted to `letsencrypt-prod`** as of 2026-06-22, after `letsencrypt-staging`
(no rate limits, untrusted root) proved the HTTP-01 chain end to end on both
entry points. The two places that were switched, in case a future hostname
needs the same staging-first treatment:

- `gitops/flux/apps/helmrelease-space-taco.yaml`'s `ingress.annotations["cert-manager.io/cluster-issuer"]`
- `gitops/flux/cert-manager-issuers/certificate-istio-gateway-tls.yaml`'s `spec.issuerRef.name`

The staging `ClusterIssuer` is left in place (not deleted) as the fastest
rollback path if production issuance ever breaks.

The Istio Gateway's certificate is a standalone `Certificate` object (not
the Ingress-annotation shortcut) in the **`aks-istio-ingress`** namespace —
Istio's gateway pods read TLS secrets via SDS from their own namespace, not
the namespace the `Gateway` resource happens to live in. See
`certificate-istio-gateway-tls.yaml`'s comment for the full reasoning.

## Node pool architecture

Two node pools keep AKS infrastructure and application workloads on separate nodes, **with different VM SKUs** — see "Cost estimate" below for why they're no longer the same size:

| Pool | Name | Mode | Nodes | SKU | Workloads |
|------|------|------|-------|-----|-----------|
| System | `system` | `System` | 1 | `Standard_B2pls_v2` (2 vCPU / 4 GiB) | CoreDNS, konnectivity-agent, azure-cni (AKS-managed) |
| User | `apps` | `User` | 2 | `Standard_B2ms` (2 vCPU / 8 GiB) | Flux controllers, Kyverno, cert-manager, istiod, space-taco |

AKS automatically labels every user-pool node with `kubernetes.azure.com/mode: user`. All application deployments carry `nodeSelector: kubernetes.azure.com/mode: user` to target this pool explicitly.

## Cost estimate (dev cluster, always-on)

| Component | Monthly cost |
|-----------|-------------|
| AKS control plane (Free tier) | $0 |
| 1× system node `Standard_B2pls_v2` (ARM64, 2 vCPU / 4 GiB) | ~$25 |
| 2× apps node `Standard_B2ms` (x86, 2 vCPU / 8 GiB) | ~$121 |
| OS disks (3× 30 GB managed) | ~$6 |
| Standard Load Balancer (egress) | ~$18 |
| Istio external ingress gateway public IP (Standard) | ~$4 |
| Terraform state storage (existing) | ~$1 |
| cert-manager (controller/webhook/cainjector pods) | $0 — runs on existing nodes |
| Let's Encrypt certificates (Web App Routing + Istio Gateway) | $0 — free, auto-renewing |
| **Total** | **~$175/month** |

**The apps pool runs a bigger VM SKU, not more nodes of the same one — this
was a real production incident, not a preemptive choice.** `istiod` (the
AKS-managed Istio add-on's control plane) requests 2Gi memory per replica
(2 replicas; not tunable via Helm/Terraform — see "Istio service mesh
add-on" above). On `Standard_B2pls_v2` (2 vCPU / 4 GiB), mandatory per-node
platform daemonsets (CNI, CSI drivers, kube-proxy, metrics, etc.) consume
~1.1Gi of the ~2.79Gi allocatable, leaving a **hard ceiling of ~1.68Gi free
per node** — under istiod's 2Gi ask, regardless of node count. This was
discovered when scaling `aks_user_node_count` 3→4 on `Standard_B2pls_v2`
(an attempted fix for an unrelated capacity squeeze) didn't let istiod
reschedule after both replicas were torn down simultaneously, took the
sidecar-injection webhook down, and broke `space-taco` in production —
`FailedCreate` on its ReplicaSets with `no endpoints available for service
"istiod-asm-1-28"`. `Standard_B2ms` (2 vCPU / 8 GiB, ~$60/month) is the
cheapest SKU with enough per-node headroom — cheaper than even the ARM
`Standard_B4pls_v2` (4 vCPU / 8 GiB, ~$87/month) for the same memory. With
the per-node ceiling no longer binding, node count actually *drops* from 3
to 2: istiod's 2 replicas (anti-affinity-separated onto different nodes)
each get a node to themselves, with Kyverno/cert-manager/Flux/the app
spread across both and real headroom to spare. See `aks_apps_node_vm_size`
in `variables.tf` for the full math, and the troubleshooting table below
for the exact symptom.

### Swap to x86 if ARM is unavailable

```hcl
# infra/terraform.tfvars
aks_node_vm_size = "Standard_B2s"   # system pool only — ~$35/month instead of ~$25/month
```

(`aks_apps_node_vm_size` is already x86 — `Standard_B2ms` — so the apps pool needs no change for ARM unavailability.)

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
| `aks_node_vm_size` | `infra` | VM SKU for the system pool only | No |
| `aks_apps_node_vm_size` | `infra` | VM SKU for the apps pool only — deliberately decoupled from the system pool's SKU, see "Cost estimate" above | No |
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

### Bootstrapping from a truly empty state (disaster recovery)

Step 4 above only works if `azurerm_kubernetes_cluster.this` already exists
in state by the time `flux_bootstrap_git` is planned — the `flux` provider
block in `provider.tf` reads `kube_config` straight off that resource, and
that value is unknown until the cluster is actually created. If the state is
completely empty (e.g. the resource group was deleted out-of-band and
Terraform is rebuilding from zero), a single `terraform plan` can't succeed:
it fails with `Error: Kubernetes Client — invalid configuration` the moment
it reaches `flux_bootstrap_git`.

`terraform-infra-plan`'s "Terraform Plan" step detects exactly this failure
and automatically falls back to a `-target` plan that creates everything
*except* `flux_bootstrap_git` (resource group, cluster, node pool, public
IP, role assignment, the Istio CNI-chaining `null_resource`). The PR
comment is flagged with a "⚠️ Bootstrap mode" note when this happens. Once
that plan is reviewed and applied, the cluster exists with a concrete
`kube_config` — **re-run the workflow** (push again, or `workflow_dispatch`)
and the second pass will plan/apply `flux_bootstrap_git` normally, no
special-casing needed.

This never showed up before because `flux.tf` (commit `cb34380`) was only
ever introduced onto a state where the cluster already existed — this repo
had never actually planned the cluster and Flux together from a genuinely
empty state until a manual out-of-band deletion forced it.

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
| `null_resource.istio_cni_chaining`'s `az aks mesh` call fails with `AKSOperationPreempted` | The CNI-chaining call only depended on the cluster, so Terraform ran it in parallel with `azurerm_kubernetes_cluster_node_pool.apps`'s creation — AKS only allows one control-plane operation in flight per cluster | Fixed: `istio.tf` now also `depends_on` the node pool, forcing the call to run strictly after it. |
| Kyverno HelmRelease stuck `InstallFailed`/`Stalled (RetriesExceeded)`; `kubectl get events -n kyverno` shows `FailedScheduling: Insufficient cpu` or `Insufficient memory` | Kyverno's 4 controller deployments at chart-default resource *requests* (~410m CPU / ~384Mi memory total) + 2 `istiod` replicas + Flux's 4 controllers + per-node AKS/Istio daemonsets left no scheduling headroom on small `Standard_B2pls_v2` nodes. Growing `aks_user_node_count` from 1→2→3 kept shifting which single pod was unschedulable (CPU, then memory, then one pod short again) instead of resolving it — each additional tiny node also adds its own daemonset overhead, so node count alone has diminishing returns | Fixed at the root cause: `kustomization-kyverno.yaml`'s `values` now overrides each controller's resource *requests* down to 5-20m CPU / 32-64Mi memory (limits untouched — this only lowers what the scheduler reserves up front, not the usable ceiling). Check `kubectl describe nodes \| grep -A5 "Allocated resources"` before assuming a node-count fix will help. If the HelmRelease is `Stalled (RetriesExceeded)`, a values/capacity fix alone won't restart it — suspend/resume (`kubectl patch helmrelease kyverno -n kyverno --type=merge -p '{"spec":{"suspend":true}}'` then `false`) to reset the retry counter; if the prior install never succeeded even once, also delete its `sh.helm.release.v1.kyverno.v*` secrets in the `kyverno` namespace first so Flux treats it as a fresh install instead of an upgrade with `MissingRollbackTarget`. |
| `Certificate` stuck `Pending`; `kubectl describe` shows a `cm-acme-http-solver-*` pod `Forbidden` by admission | The ACME HTTP-01 self-check pod for the Ingress-driven certificate is created in the `space-taco` namespace (same namespace as the Certificate/Ingress that requested it — cert-manager always does this, not configurable), making it subject to `space-taco-pod-security`'s rules (`gitops/charts/space-taco/templates/kyverno-policies.yaml`), which match every Pod in that namespace unconditionally. cert-manager ≥1.16 (pinned in `helmrelease-cert-manager.yaml`) already hardens the solver pod's default `securityContext` to satisfy this (`cert-manager/cert-manager#6462`), so this shouldn't trigger — but if a future chart bump or custom `podTemplate` regresses it | Add an `exclude` block (matching label `acme.cert-manager.io/http01-solver: "true"`) to each rule in `space-taco-pod-security`, the same narrowly-scoped-exception pattern used for the Istio CNI-chaining fix above — don't disable the policy outright |
| `ClusterIssuer`/`Certificate` exists but no `Secret` appears after several minutes | `kubectl describe challenge -A` — almost always either (a) DNS for the requested hostname doesn't point at the Web App Routing ingress IP yet (external-dns lag, or a stale record), or (b) the temporary self-check `Ingress` cert-manager creates isn't using `ingressClassName: webapprouting.kubernetes.azure.com` because a `ClusterIssuer` was hand-edited without it | Confirm `dig taco-delivery.autoaaron.xyz` resolves to the same IP as `kubectl get svc -n app-routing-system` (or wherever Web App Routing's controller Service lives), and that both ClusterIssuers in `gitops/flux/cert-manager-issuers/` still set `solvers[0].http01.ingress.ingressClassName` |
| `istiod-*` pods stuck `Pending` (`0/N nodes are available: ... Insufficient memory`); `space-taco` ReplicaSets `FailedCreate` with `no endpoints available for service "istiod-asm-1-28"`; site returns 503 | Each `Standard_B2pls_v2` node has a hard ceiling of ~1.68Gi free memory after mandatory platform daemonsets — under istiod's 2Gi-per-replica request, **no matter how many nodes of that SKU exist**. Hit in production after cert-manager's pods ate the last of a 3-node pool's margin; scaling node *count* further (3→4) did not help, as expected once you know it's a per-node ceiling, not an aggregate one | Fixed at the root cause: `aks_apps_node_vm_size` (`variables.tf`) sizes the apps pool independently of the system pool, now `Standard_B2ms` (8 GiB) — see "Cost estimate" above for the full math. Mid-incident, `az aks mesh disable-ingress-gateway` / `enable-ingress-gateway` (to try forcing re-reconciliation of an unrelated stuck add-on) made this *worse* by tearing down both istiod replicas at once instead of one at a time — avoid that command while istiod is already degraded. A temporary extra node pool (`az aks nodepool add --node-vm-size Standard_B2ms --node-count 1`) is the fastest live mitigation if this recurs before a Terraform apply can land; remove it only after the permanent pool resize is confirmed applied and istiod has rescheduled onto it. |

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
