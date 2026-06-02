#!/usr/bin/env bash
# =============================================================================
# bootstrap-local.sh — Spin up a full Space Taco local dev environment
# =============================================================================
# Prerequisites: kind, kubectl, helm, flux, docker
# Usage: ./deploy/kind/bootstrap-local.sh
# =============================================================================
set -euo pipefail

CLUSTER_NAME="space-taco"
NAMESPACE="space-taco"
CHART_DIR="gitops/charts/space-taco"
IMAGE_NAME="space-taco-delivery"
IMAGE_TAG="local"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Check dependencies
for cmd in kind kubectl helm docker; do
  command -v "$cmd" &>/dev/null || error "Required tool not found: $cmd"
done

info "🚀 Launching Space Taco local cluster..."

# Create kind cluster if it doesn't exist
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  warn "Cluster '${CLUSTER_NAME}' already exists — skipping creation"
else
  kind create cluster \
    --name "${CLUSTER_NAME}" \
    --config deploy/kind/kind-cluster.yaml \
    --wait 120s
  info "✅ Kind cluster created"
fi

# Set kubectl context
kubectl config use-context "kind-${CLUSTER_NAME}"

# Build image locally
info "🔨 Building Space Taco image..."
docker build \
  --target final \
  -t "${IMAGE_NAME}:${IMAGE_TAG}" \
  -f app/Dockerfile \
  app/

# Load image into kind cluster (no registry needed locally)
info "📦 Loading image into kind cluster..."
kind load docker-image "${IMAGE_NAME}:${IMAGE_TAG}" --name "${CLUSTER_NAME}"

# Create namespace
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "${NAMESPACE}" \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted \
  --overwrite

# Install Kyverno
info "🛡️  Installing Kyverno..."
helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --set admissionController.replicas=1 \
  --wait --timeout 5m

# Install Flux (CRDs only for local — no git sync needed)
info "🔄 Installing Flux CRDs..."
flux install --components="source-controller,helm-controller" \
  --toleration-keys="" \
  --export | kubectl apply -f - || true

# Deploy the chart locally (override image to local build)
info "🌮 Deploying Space Taco via Helm..."
helm upgrade --install space-taco "${CHART_DIR}" \
  --namespace "${NAMESPACE}" \
  --set image.registry="" \
  --set image.repository="${IMAGE_NAME}" \
  --set image.tag="${IMAGE_TAG}" \
  --set imageVerification.enabled=false \
  --set replicaCount=1 \
  --wait --timeout 3m

info ""
info "✅ Space Taco is live! Test it with:"
info ""
info "  # Port-forward the service"
info "  kubectl port-forward svc/space-taco -n ${NAMESPACE} 8080:80 &"
info ""
info "  # Check health"
info "  curl http://localhost:8080/healthz"
info ""
info "  # Browse the galactic menu"
info "  curl http://localhost:8080/api/v1/menu | jq ."
info ""
info "  # Place an order"
info "  curl -X POST http://localhost:8080/api/v1/orders \\"
info "    -H 'Content-Type: application/json' \\"
info "    -d '{\"customer_id\":\"EARTHLING-001\",\"planet\":\"Earth\",\"galactic_quadrant\":\"Milky Way\",\"items\":[{\"filling\":\"black_hole_bbq\",\"quantity\":2,\"extra_hot\":true}]}'"
info ""
info "  # List all orders"
info "  curl http://localhost:8080/api/v1/orders | jq ."
info ""
info "🛸 Enjoy your intergalactic tacos!"
