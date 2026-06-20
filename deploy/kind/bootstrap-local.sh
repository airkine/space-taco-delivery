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

# istio-injection=enabled tells istiod's mutating webhook to add the
# istio-proxy sidecar to every pod created in this namespace from now on.
kubectl label namespace "${NAMESPACE}" \
  istio-injection=enabled \
  --overwrite

# Install Kyverno
info "🛡️  Installing Kyverno..."
helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --set admissionController.replicas=1 \
  --wait --timeout 5m

# Install Istio
# Dependency order: base (CRDs) -> istiod (control plane) -> cni (per-node
# DaemonSet that does iptables redirect setup for injected sidecars) ->
# gateway (the ingress gateway itself).
#
# cni.enabled=true on istiod is required, not just installing the cni chart
# below: without it istiod's injection webhook doesn't know a CNI plugin
# exists and still injects the legacy privileged istio-init container, which
# the space-taco namespace's "restricted" Pod Security Standard rejects
# (NET_ADMIN/NET_RAW, runAsUser=0) — verified by hitting that exact
# PodSecurity violation during local testing. Once istiod knows about the
# CNI plugin, the istio-proxy sidecar itself needs no elevated capabilities,
# so it also passes Kyverno's space-taco-pod-security ClusterPolicy
# unmodified.
#
# The gateway is exposed on NodePort 30080/30443 (see
# deploy/kind/istio-values/gateway-values.yaml), reusing the same Kind
# extraPortMappings the old NGINX ingress controller used.
info "🕸️  Installing Istio..."
helm repo add istio https://istio-release.storage.googleapis.com/charts --force-update

helm upgrade --install istio-base istio/base \
  --namespace istio-system \
  --create-namespace \
  --wait --timeout 5m

helm upgrade --install istiod istio/istiod \
  --namespace istio-system \
  --set cni.enabled=true \
  --wait --timeout 5m

helm upgrade --install istio-cni istio/cni \
  --namespace istio-system \
  --wait --timeout 5m

helm upgrade --install istio-ingressgateway istio/gateway \
  --namespace istio-system \
  -f deploy/kind/istio-values/gateway-values.yaml \
  --wait --timeout 5m

# Install Flux (CRDs only for local — no git sync needed)
info "🔄 Installing Flux CRDs..."
flux install --components="source-controller,helm-controller" \
  --toleration-keys="" \
  --export | kubectl apply -f - || true

# Deploy the chart locally (override image to local build)
# ingress.enabled stays false -- a plain k8s Ingress bypasses Istio's routing
# entirely (kube-proxy resolves it before Envoy is involved), so it can't
# enforce a blue/green split. istio.enabled=true renders a Gateway +
# VirtualService + DestinationRule instead. blueGreen.enabled=true renders
# both the "blue" and "green" Deployments — both start on the same locally
# built image/tag; bump blueGreen.slots.green.image.tag to practice a real
# version rollout, then cut over with blueGreen.activeSlot=green.
info "🌮 Deploying Space Taco via Helm..."
helm upgrade --install space-taco "${CHART_DIR}" \
  --namespace "${NAMESPACE}" \
  --set image.registry="" \
  --set image.repository="${IMAGE_NAME}" \
  --set image.tag="${IMAGE_TAG}" \
  --set imageVerification.enabled=false \
  --set ingress.enabled=false \
  --set istio.enabled=true \
  --set 'istio.gateway.hosts[0]=*' \
  --set blueGreen.enabled=true \
  --set blueGreen.activeSlot=blue \
  --set blueGreen.slots.blue.image.tag="${IMAGE_TAG}" \
  --set blueGreen.slots.green.image.tag="${IMAGE_TAG}" \
  --set blueGreen.slots.blue.replicaCount=1 \
  --set blueGreen.slots.green.replicaCount=1 \
  --wait --timeout 3m

info ""
info "✅ Space Taco is live! Test it with:"
info ""
info "  # Traffic now flows through the Istio ingress gateway, not a plain Ingress:"
info "  # browser -> localhost:8080 -> Kind NodePort 30080 -> istio-ingressgateway -> blue/green pod"
info "  # The Gateway accepts any hostname ('*') in Kind, so plain http://localhost:8080 works"
info "  # in a browser -- no Host header needed."
info ""
info "  # Health check (x-taco-slot response header shows which slot answered)"
info "  curl -i http://localhost:8080/healthz"
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
info "🔄 Practice a blue/green cutover:"
info ""
info "  # 1. Roll out a new version to the idle 'green' slot — it receives 0% of"
info "  #    traffic until you cut over, so this is safe to do live."
info "  helm upgrade space-taco ${CHART_DIR} -n ${NAMESPACE} --reuse-values --set blueGreen.slots.green.image.tag=<new-tag>"
info ""
info "  # 2. Cut traffic over to green once it looks healthy"
info "  helm upgrade space-taco ${CHART_DIR} -n ${NAMESPACE} --reuse-values --set blueGreen.activeSlot=green"
info ""
info "  # 3. Confirm the switch"
info "  curl -i http://localhost:8080/healthz   # x-taco-slot: green"
info ""
info "🛸 Enjoy your intergalactic tacos!"
