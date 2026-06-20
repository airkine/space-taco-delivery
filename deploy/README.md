# Deploy — Local Development Environment

This directory contains everything needed to spin up a full Space Taco Delivery
environment on your local machine using [Kind](https://kind.sigs.k8s.io/)
(Kubernetes in Docker), as well as guides for setting up production Azure deployment
via GitHub Actions + Terraform.

---

## 🚀 GitHub Actions + Terraform (Azure Deployment)

To enable `terraform apply` via GitHub Actions, you need to create an Azure service
principal and configure OIDC federation. This is a **one-time setup** that takes ~10 minutes.

### Quick Start

1. **New to this?** Start with [GITHUB_SECRETS_CHECKLIST.md](GITHUB_SECRETS_CHECKLIST.md)
   - Lists the 4 secrets you need
   - Quick copy-paste PowerShell commands
   - 5-minute setup

2. **Want the full picture?** Read [SERVICE_PRINCIPAL_SETUP.md](SERVICE_PRINCIPAL_SETUP.md)
   - Step-by-step walkthrough with detailed explanations
   - Covers OIDC federation, Terraform state storage, and RBAC
   - Includes troubleshooting and security best practices

### After Setup

Once secrets are added to GitHub, any push to these paths automatically triggers the workflow:
- `gitops/terraform/**`
- `gitops/flux/**`
- `.github/workflows/terraform.yml`

The workflow runs `terraform plan` on pull requests and `terraform apply` on merges to `main`.

---

## Directory Structure

```
deploy/
├── SERVICE_PRINCIPAL_SETUP.md      # 📖 Full Azure setup guide for Terraform + GitHub Actions
├── GITHUB_SECRETS_CHECKLIST.md     # 🔑 Quick reference for GitHub secrets
├── README.md                       # (this file)
└── kind/
    ├── kind-cluster.yaml           # Kind cluster topology (1 control-plane + 2 workers)
    ├── istio-values/
    │   └── gateway-values.yaml     # NodePort 30080/30443 mapping for the Istio ingress gateway
    ├── bootstrap-local.sh          # One-shot bootstrap script for Git Bash / WSL / macOS
    └── bootstrap-local.ps1         # One-shot bootstrap script for Windows PowerShell
```

---

## Prerequisites

Install all of the following tools before running the bootstrap script.

| Tool | Minimum Version | Purpose |
|------|----------------|---------|
| [Docker](https://docs.docker.com/get-docker/) | 24.x | Container runtime — Kind wraps Docker |
| [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) | 0.22+ | Creates Kubernetes clusters inside Docker containers |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | 1.29+ | Kubernetes CLI for interacting with the cluster |
| [helm](https://helm.sh/docs/intro/install/) | 3.14+ | Deploys the Space Taco Helm chart |
| [flux](https://fluxcd.io/flux/installation/) | 2.x | Installs Flux CRDs (no live git sync needed locally) |

Verify all tools are on your `PATH` before continuing:

```bash
kind version && kubectl version --client && helm version && flux version && docker version
```

---

## Quick Start — Bootstrap Script

The bootstrap script performs every step end-to-end:

1. Creates the Kind cluster (if it does not already exist)
2. Builds the Space Taco container image locally with Docker
3. Loads the image directly into Kind (no registry push needed)
4. Creates the `space-taco` namespace with Pod Security Standards enforced and `istio-injection=enabled`
5. Installs [Kyverno](https://kyverno.io/) for policy enforcement
6. Installs [Istio](https://istio.io/) — `base`, `istiod`, the `istio-cni` plugin, and the ingress gateway (NodePort 30080/30443, replacing the old NGINX ingress controller)
7. Installs Flux CRDs (source-controller + helm-controller only)
8. Deploys the Space Taco Helm chart with the locally built image, `istio.enabled=true`, and `blueGreen.enabled=true` (blue + green Deployments behind one Service)

### Run from the repository root

> **Important:** Always run the script from the repository root, not from
> inside the `deploy/kind/` directory. The script references paths such as
> `deploy/kind/kind-cluster.yaml` and `gitops/charts/space-taco` relative to
> the repo root.

**Windows — PowerShell (recommended on Windows):**

```powershell
# Run the bootstrap
.\deploy\kind\bootstrap-local.ps1
```

**Git Bash / WSL / macOS — bash:**

```bash
# Make executable (first time only)
chmod +x deploy/kind/bootstrap-local.sh

# Run the bootstrap
./deploy/kind/bootstrap-local.sh
```

Both scripts are identical in behaviour. The PowerShell version uses
`$ErrorActionPreference = 'Stop'` (equivalent to `set -e`) and native
`Write-Host` colour output so no Git Bash dependency is required on Windows.

---

## Manual Steps — Create the Kind Cluster Only

If you only want to create the cluster without deploying the application, run
`kind create cluster` directly with the provided config file:

```bash
# Create the 'space-taco' cluster using the config in this repo
kind create cluster \
  --name space-taco \
  --config deploy/kind/kind-cluster.yaml \
  --wait 120s

# Point kubectl at the new cluster
kubectl config use-context kind-space-taco

# Verify the nodes are Ready
kubectl get nodes
```

Expected output — three nodes (one control-plane, two workers):

```
NAME                        STATUS   ROLES           AGE   VERSION
space-taco-control-plane    Ready    control-plane   Xs    v1.x.x
space-taco-worker           Ready    <none>          Xs    v1.x.x
space-taco-worker2          Ready    <none>          Xs    v1.x.x
```

---

## Cluster Topology

The Kind cluster is defined in [kind/kind-cluster.yaml](kind/kind-cluster.yaml).

| Node | Role | Notes |
|------|------|-------|
| `space-taco-control-plane` | control-plane | Hosts ingress; ports 8080 → 30080 and 8443 → 30443 are mapped to `localhost` |
| `space-taco-worker` | worker | Labelled `workload=app` |
| `space-taco-worker2` | worker | Labelled `workload=app` |

**Feature gates enabled:**
- `ValidatingAdmissionPolicy: true` — required for Kyverno compatibility

**Network CIDRs:**
- Pod subnet: `10.244.0.0/16`
- Service subnet: `10.96.0.0/16`

---

## Testing the Running Application

After a successful bootstrap, traffic flows through the Istio ingress
gateway rather than a plain Ingress: `localhost:8080` → Kind NodePort 30080 →
`istio-ingressgateway` → blue/green pod. The Gateway accepts any hostname
(`*`) in Kind, so plain `http://localhost:8080` works directly in a browser
or curl — no `Host` header needed. The `x-taco-slot` response header shows
which slot answered.

```bash
# Health check
curl -i http://localhost:8080/healthz

# Browse the galactic menu
curl http://localhost:8080/api/v1/menu | jq .

# Place an order
curl -X POST http://localhost:8080/api/v1/orders \
  -H 'Content-Type: application/json' \
  -d '{
    "customer_id": "EARTHLING-001",
    "planet": "Earth",
    "galactic_quadrant": "Milky Way",
    "items": [{"filling": "black_hole_bbq", "quantity": 2, "extra_hot": true}]
  }'

# List all orders
curl http://localhost:8080/api/v1/orders | jq .
```

---

## Blue/Green Cutover

Both `space-taco-blue` and `space-taco-green` Deployments run at all times,
behind the same Service. An Istio `VirtualService`/`DestinationRule` sends
100% of traffic to `blueGreen.activeSlot` and 0% to the other — switching is
instant, no cold start:

```bash
# 1. Roll out a new version to the idle "green" slot — it receives 0% of
#    traffic until you cut over, so this is safe to do live.
helm upgrade space-taco gitops/charts/space-taco -n space-taco \
  --reuse-values --set blueGreen.slots.green.image.tag=<new-tag>

# 2. Cut traffic over to green once it looks healthy
helm upgrade space-taco gitops/charts/space-taco -n space-taco \
  --reuse-values --set blueGreen.activeSlot=green

# 3. Confirm the switch
curl -i http://localhost:8080/healthz   # x-taco-slot: green
```

---

## Teardown

```bash
# Delete the Kind cluster and all resources inside it
kind delete cluster --name space-taco
```

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `Required tool not found: <cmd>` | Missing prerequisite | Install the tool listed in the Prerequisites table |
| `Cluster already exists` warning | Previous run left the cluster up | Expected behaviour — the script skips creation and continues |
| Helm deploy times out | Image not loaded into Kind | Re-run the script from the repo root; ensure Docker is running |
| `kubectl` targets the wrong cluster | Wrong context active | Run `kubectl config use-context kind-space-taco` |
| Kyverno install fails | Docker resources too low | Increase Docker Desktop memory to at least 4 GB |
| `space-taco-*` pods rejected by Kyverno/PSS after Istio install | `istio-cni` DaemonSet not yet Ready on the node, so injection fell back to the privileged init-container path | `kubectl get pods -n istio-system -l k8s-app=istio-cni-node`; wait for it to be `Running`, then re-run the Helm upgrade |
| `curl http://localhost:8080/...` returns 404 from the gateway | Gateway/VirtualService weren't deployed with `istio.gateway.hosts[0]=*`, or are stuck on an old value | `kubectl get gateway,virtualservice -n space-taco -o yaml \| grep -A2 hosts:` to confirm `"*"`; re-run the bootstrap script if not |
| Istio install fails / times out | Docker resources too low, or stale `istio` Helm repo cache | Increase Docker Desktop memory; run `helm repo update istio` and re-run the bootstrap script |
