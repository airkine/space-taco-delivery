# 🌮🚀 Space Taco Delivery

> Intergalactic taco order microservice — GitOps practice repo

A fully production-patterned microservice demonstrating GitOps best practices:
**GitHub Actions · Terraform · Helm · Flux · Kyverno · Istio · Kind · signed OCI images · SBOMs**

---

## Architecture

```text
┌─────────────────────────────────────────────────────────┐
│                     GitHub Actions                      │
│  ┌──────────┐  ┌──────────┐  ┌─────────────────────┐  │
│  │  build   │  │  chart   │  │     terraform        │  │
│  │ test→push│  │lint→push │  │  plan→apply (main)   │  │
│  └────┬─────┘  └────┬─────┘  └─────────────────────┘  │
│       │signed        │signed                            │
└───────┼──────────────┼──────────────────────────────────┘
        │              │
        ▼              ▼
   ghcr.io OCI    ghcr.io OCI
   (image+SBOM)   (helm chart)
        │              │
        └──────┬────────┘
               │ Flux watches
               ▼
     ┌──────────────────────────────────────────┐
     │               kind cluster                │
     │  ┌───────────────┐                        │
     │  │   Kyverno     │  ← verifies image       │
     │  │   (admit?)    │    signature before     │
     │  └───────────────┘    pod starts           │
     │            │                               │
     │            ▼                               │
     │  ┌───────────────┐   Gateway +              │
     │  │ istio-ingress  │   VirtualService weight │
     │  │   -gateway     │   100/0 by activeSlot   │
     │  └───────┬───────┘                          │
     │     ┌─────┴─────┐                            │
     │     ▼           ▼                            │
     │  ┌──────┐    ┌──────┐                         │
     │  │ blue │    │green │  ← each: distroless,    │
     │  │ Dep. │    │ Dep. │    nonroot, read-only FS,│
     │  └──────┘    └──────┘    istio-proxy sidecar  │
     └──────────────────────────────────────────┘
```

Traffic enters through the Istio ingress gateway, not a plain Ingress — only
requests routed through Istio's Envoy proxy honor the blue/green weight; see
[Blue/Green with Istio](#bluegreen-with-istio) below.

## Repo Structure

```text
.
├── app/                        # Go microservice
│   ├── cmd/server/main.go      # Entry point
│   ├── internal/
│   │   ├── handler/            # HTTP handlers
│   │   ├── model/              # Domain models
│   │   └── store/              # In-memory store
│   ├── Dockerfile              # Multi-stage, distroless
│   └── go.mod
│
├── gitops/                     # GitOps root
│   ├── terraform/
│   │   ├── github/             # GitHub repo IaC — repo, branch protection, labels, secrets
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   └── infra/               # Azure IaC — AKS cluster + Flux bootstrap
│   │       ├── aks.tf            # Cluster + Istio service mesh add-on (service_mesh_profile)
│   │       ├── istio.tf          # One-time az CLI call enabling Istio CNI chaining mode
│   │       ├── flux.tf
│   │       ├── variables.tf
│   │       └── outputs.tf
│   │       # github/ and infra/ are separate Terraform states on purpose —
│   │       # see gitops/terraform/README.md "Why two states"
│   └── charts/
│       └── space-taco/         # Helm chart
│           ├── Chart.yaml
│           ├── values.yaml
│           └── templates/
│               ├── deployment.yaml          # Single Deployment, or blue+green pair
│               ├── service.yaml
│               ├── serviceaccount.yaml
│               ├── ingress.yaml             # ingress.enabled — Web App Routing on AKS
│               ├── kyverno-policies.yaml    # Image signing + pod sec
│               ├── istio-gateway.yaml       # istio.enabled; +HTTPS server when istio.tls.enabled
│               ├── istio-virtualservice.yaml # istio.enabled (blue/green weighting)
│               └── istio-destinationrule.yaml # istio.enabled + blueGreen.enabled
│
│   ├── flux/
│   │   ├── apps/                       # space-taco + Kyverno HelmReleases
│   │   ├── cert-manager/               # cert-manager controller/webhook/cainjector
│   │   └── cert-manager-issuers/       # Let's Encrypt ClusterIssuers + Istio Gateway Certificate
│       # See gitops/terraform/README.md "TLS — cert-manager + Let's Encrypt"
│
├── deploy/kind/
│   ├── kind-cluster.yaml          # 3-node local cluster config
│   ├── istio-values/              # Helm values for the local Istio install
│   ├── bootstrap-local.sh         # One-shot local dev setup (Git Bash/WSL/macOS)
│   └── bootstrap-local.ps1        # One-shot local dev setup (Windows PowerShell)
│
└── .github/workflows/
    ├── build.yml               # Build → sign → SBOM → push image
    ├── chart.yml               # Package → sign → push Helm chart
    ├── terraform.yml           # Plan on PR, apply on merge (github/ then infra/)
    └── terraform-destroy.yml   # Manual-only teardown, scoped to infra/ only
```

## Local Development

### Docker Compose (fastest path)

Builds the image locally and starts the app alongside Redis:

```bash
docker compose up --build
```

The app is available at `http://localhost:8080`. Redis runs on `localhost:6379` with the cache layer enabled (`REDIS_URL` is set automatically).

To stop and clean up:

```bash
docker compose down
```

### Prerequisites (kind cluster)

```bash
# Install required tools
brew install kind kubectl helm cosign
brew install fluxcd/tap/flux
```

### One-command bootstrap

```bash
./deploy/kind/bootstrap-local.sh
```

This will:

1. Create a 3-node kind cluster
2. Build the Go app image locally
3. Load it into the cluster (no registry needed)
4. Install Kyverno
5. Install Istio (base, istiod, the `istio-cni` plugin, and the ingress gateway — replaces the old NGINX ingress controller)
6. Deploy the Helm chart with `istio.enabled=true` and `blueGreen.enabled=true`

### Manual test commands

Traffic flows through the Istio ingress gateway, not a plain Ingress:
`localhost:8080` → Kind NodePort 30080 → `istio-ingressgateway` → blue/green
pod. The Gateway accepts any hostname (`*`) in Kind, so plain
`http://localhost:8080` works directly in a browser or curl — no `Host`
header needed. The `x-taco-slot` response header shows which slot answered.

```bash
# Health checks
curl -i http://localhost:8080/healthz
curl -i http://localhost:8080/readyz

# Galactic menu
curl http://localhost:8080/api/v1/menu | jq .

# Place an order
curl -X POST http://localhost:8080/api/v1/orders \
  -H 'Content-Type: application/json' \
  -d '{
    "customer_id": "EARTHLING-001",
    "planet": "Earth",
    "galactic_quadrant": "Milky Way",
    "items": [
      {"filling": "black_hole_bbq", "quantity": 2, "extra_hot": true},
      {"filling": "stardust_shrimp", "quantity": 1, "extra_hot": false}
    ]
  }' | jq .

# List orders
curl http://localhost:8080/api/v1/orders | jq .

# Update order status
curl -X PATCH http://localhost:8080/api/v1/orders/TACO-000001/status \
  -H 'Content-Type: application/json' \
  -d '{"status": "launched"}'
```

### Blue/Green with Istio

The chart renders two Deployments (`space-taco-blue`, `space-taco-green`)
behind one Service. An Istio `VirtualService`/`DestinationRule` sends 100% of
traffic to `blueGreen.activeSlot` and 0% to the other slot — both run at full
replica count the whole time, so a cutover is instant with no cold start.

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

This same `blueGreen.activeSlot` mechanism is wired into the AKS Flux
deployment (`gitops/flux/apps/helmrelease-space-taco.yaml`) as a *second*,
additive entry point alongside the existing Web App Routing Ingress. AKS uses
the **AKS-managed Istio service mesh add-on** rather than the self-managed
Helm install used in Kind (see
[`gitops/terraform/README.md`](gitops/terraform/README.md#istio-service-mesh-add-on))
— find the gateway's external IP with `kubectl get svc
aks-istio-ingressgateway-external -n aks-istio-ingress` and curl it with a
`Host: taco-delivery.autoaaron.xyz` header the same way.

### TLS on AKS

Both AKS entry points terminate HTTPS with a free Let's Encrypt certificate,
issued and auto-renewed by [cert-manager](https://cert-manager.io/) — see
[`gitops/terraform/README.md`](gitops/terraform/README.md#tls--cert-manager--lets-encrypt)
for the full picture (why Let's Encrypt over an Azure-native option, how the
two Flux Kustomizations in `gitops/flux/cert-manager*` are ordered, and the
staging→production promotion steps).

```bash
# Web App Routing Ingress
curl https://taco-delivery.autoaaron.xyz/healthz

# Istio Gateway (reached by IP + Host header, same as the plain-HTTP example above)
curl -k -H "Host: taco-delivery.autoaaron.xyz" "https://${GATEWAY_IP}/healthz"
```

Currently issued via the **staging** ClusterIssuer while the chain is being
validated end to end — expect an untrusted-certificate warning (hence `-k`
above) until it's promoted to `letsencrypt-prod`.

## GitHub Repo Bootstrap (Terraform)

`gitops/terraform/github/` and `gitops/terraform/infra/` are independent
Terraform root modules with independent state — apply `github/` first so the
repo exists before `infra/`'s Flux bootstrap tries to push to it. See
[`gitops/terraform/README.md`](gitops/terraform/README.md) for the full
picture, including why they're split.

```bash
cd gitops/terraform/github
terraform init
terraform plan
terraform apply

cd ../infra
terraform init
terraform plan
terraform apply
```

Required secrets to add after repo creation:

| Secret | Description |
| --- | --- |
| `TF_GITHUB_TOKEN` | GitHub PAT with `repo` + `admin:org` scopes |
| `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` | Azure OIDC auth for the `infra` module and CI |

Image/chart signing is keyless (Sigstore Fulcio + Rekor via OIDC) — no signing-key secret is needed.

## Supply Chain Security

The `main` branch enforces `require_signed_commits`, required PR review, and required status checks, with no bypass for `github-actions[bot]`. CI never commits or pushes to the repo — after a build, a human bumps the image tag in `gitops/charts/space-taco/values.yaml` via a signed, reviewed PR.

Every artifact built in CI is:

1. **Built** in a multi-stage Dockerfile → distroless `nonroot` final image
2. **Scanned** with Trivy pinned to `v0.35.0` (CRITICAL/HIGH gate, `ignore-unfixed: true` so only patchable CVEs break the build; `@master` removed after the March 2026 Trivy supply-chain incident)
3. **Signed** with Cosign keyless signing (GitHub OIDC → Fulcio CA → Sigstore Rekor transparency log; no long-lived keys)
4. **SBOM generated** in SPDX-JSON via both BuildKit (`sbom: true`) and Syft, then **attested** with `cosign attest` (modern replacement for the deprecated `cosign attach sbom`)
5. **Helm chart signed and SBOM-attested** — chart is signed by immutable digest (not mutable tag), and a Syft-generated SBOM is attested against the chart digest
6. **Verified** at admission by Kyverno before any pod starts

```bash
# Verify a container image signature
cosign verify \
  --certificate-identity-regexp "https://github.com/your-org/space-taco-delivery" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  ghcr.io/your-org/space-taco-delivery/space-taco-delivery:latest

# Verify the SBOM attestation on the image (cosign attest — not cosign attach sbom)
cosign verify-attestation \
  --type spdxjson \
  --certificate-identity-regexp "https://github.com/your-org/space-taco-delivery" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  ghcr.io/your-org/space-taco-delivery/space-taco-delivery:latest | jq '.payload | @base64d | fromjson'

# Verify the Helm chart signature (by digest)
cosign verify \
  --certificate-identity-regexp "https://github.com/your-org/space-taco-delivery" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  ghcr.io/your-org/space-taco-delivery/charts/space-taco@sha256:<digest>

# Verify the Helm chart SBOM attestation
cosign verify-attestation \
  --type spdxjson \
  --certificate-identity-regexp "https://github.com/your-org/space-taco-delivery" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  ghcr.io/your-org/space-taco-delivery/charts/space-taco@sha256:<digest> | jq '.payload | @base64d | fromjson'
```

## API Reference

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/` | Browser UI — menu, order form, order tracker |
| `GET` | `/healthz` | Liveness probe |
| `GET` | `/readyz` | Readiness probe |
| `GET` | `/api/v1/menu` | Galactic taco menu |
| `GET` | `/api/v1/orders` | List all orders |
| `POST` | `/api/v1/orders` | Place a new order |
| `GET` | `/api/v1/orders/{id}` | Get order by ID |
| `PATCH` | `/api/v1/orders/{id}/status` | Update order status |

---

*May your tacos arrive before heat death of the universe.* 🌮✨
