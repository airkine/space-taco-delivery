# 🌮🚀 Space Taco Delivery

> Intergalactic taco order microservice — GitOps practice repo

A fully production-patterned microservice demonstrating GitOps best practices:
**GitHub Actions · Terraform · Helm · Flux · Kyverno · Kind · signed OCI images · SBOMs**

---

## Architecture

```
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
     ┌─────────────────────┐
     │   kind cluster      │
     │  ┌───────────────┐  │
     │  │   Kyverno     │  │ ← verifies image signature
     │  │   (admit?)    │  │   before pod starts
     │  └───────────────┘  │
     │  ┌───────────────┐  │
     │  │  space-taco   │  │ ← 2 replicas, distroless,
     │  │  Deployment   │  │   nonroot, read-only FS
     │  └───────────────┘  │
     └─────────────────────┘
```

## Repo Structure

```
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
│   ├── terraform/              # GitHub repo IaC
│   │   ├── main.tf             # Repo, branch protection, labels
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── charts/
│       └── space-taco/         # Helm chart
│           ├── Chart.yaml
│           ├── values.yaml
│           └── templates/
│               ├── deployment.yaml
│               ├── service.yaml
│               ├── serviceaccount.yaml
│               ├── kyverno-policies.yaml  # Image signing + pod sec
│               └── flux-helmrelease.yaml
│
├── deploy/kind/
│   ├── kind-cluster.yaml       # 3-node local cluster config
│   └── bootstrap-local.sh     # One-shot local dev setup
│
└── .github/workflows/
    ├── build.yml               # Build → sign → SBOM → push image
    ├── chart.yml               # Package → sign → push Helm chart
    └── terraform.yml           # Plan on PR, apply on merge
```

## Local Development

### Prerequisites

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
5. Deploy the Helm chart

### Manual test commands

```bash
# Port-forward
kubectl port-forward svc/space-taco -n space-taco 8080:80 &

# Health checks
curl http://localhost:8080/healthz
curl http://localhost:8080/readyz

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

## GitHub Repo Bootstrap (Terraform)

```bash
cd gitops/terraform
cp terraform.tfvars.example terraform.tfvars  # fill in your values
terraform init
terraform plan
terraform apply
```

Required secrets to add after repo creation:

| Secret | Description |
|---|---|
| `TF_GITHUB_TOKEN` | GitHub PAT with `repo` + `admin:org` scopes |
| `COSIGN_PASSWORD` | Cosign key password (optional for keyless) |

## Supply Chain Security

Every image built in CI is:

1. **Built** in a multi-stage Dockerfile → distroless `nonroot` final image
2. **Scanned** with Trivy (CRITICAL/HIGH gate)
3. **Signed** with Cosign keyless signing (GitHub OIDC → Sigstore Rekor)
4. **SBOM generated** in SPDX-JSON format and attached to the image
5. **Verified** at admission by Kyverno before any pod starts

```bash
# Verify an image signature locally
cosign verify \
  --certificate-identity-regexp "https://github.com/your-org/space-taco-delivery" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  ghcr.io/your-org/space-taco-delivery/space-taco-delivery:latest

# Inspect attached SBOM
cosign download sbom \
  ghcr.io/your-org/space-taco-delivery/space-taco-delivery:latest
```

## API Reference

| Method | Path | Description |
|---|---|---|
| `GET` | `/healthz` | Liveness probe |
| `GET` | `/readyz` | Readiness probe |
| `GET` | `/api/v1/menu` | Galactic taco menu |
| `GET` | `/api/v1/orders` | List all orders |
| `POST` | `/api/v1/orders` | Place a new order |
| `GET` | `/api/v1/orders/{id}` | Get order by ID |
| `PATCH` | `/api/v1/orders/{id}/status` | Update order status |

---

*May your tacos arrive before heat death of the universe.* 🌮✨
