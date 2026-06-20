# =============================================================================
# bootstrap-local.ps1 -- Spin up a full Space Taco local dev environment
# =============================================================================
# Prerequisites: kind, kubectl, helm, flux, docker
# Run from anywhere -- the script resolves the repo root automatically:
#   .\deploy\kind\bootstrap-local.ps1   (from repo root)
#   .\bootstrap-local.ps1               (from deploy\kind\)
# =============================================================================
#Requires -Version 5.1

# 'Continue' instead of 'Stop': native executables (kind, docker, helm) write
# to stderr for warnings even on success, which PS converts to ErrorRecords.
# Stop would throw on those warnings. Exit-code checking is handled by Invoke-Exe.
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Info { param([string]$Msg) Write-Host "[INFO]  $Msg" -ForegroundColor Green  }
function Write-Warn { param([string]$Msg) Write-Host "[WARN]  $Msg" -ForegroundColor Yellow }
function Write-Err  {
    param([string]$Msg)
    Write-Host "[ERROR] $Msg" -ForegroundColor Red
    exit 1
}

# Wrapper for native executables: throws if exit code is non-zero.
# $ErrorActionPreference = Stop only covers PowerShell cmdlets, not exes.
function Invoke-Exe {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Exe,
        [Parameter(ValueFromRemainingArguments)][string[]]$Args
    )
    & $Exe @Args
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Command failed (exit $LASTEXITCODE): $Exe $Args"
    }
}

# ---------------------------------------------------------------------------
# Resolve repo root from script location
# ---------------------------------------------------------------------------
# $PSScriptRoot = deploy\kind\  =>  go up two levels to get the repo root.
# This lets the script run from any working directory.
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $RepoRoot
Write-Info "Repo root: $RepoRoot"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$ClusterName = 'space-taco'
$Namespace   = 'space-taco'
$ChartDir    = 'gitops/charts/space-taco'
$ImageName   = 'space-taco-delivery'
$ImageTag    = 'local'

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
foreach ($tool in @('kind', 'kubectl', 'helm', 'docker', 'flux')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Err "Required tool not found: $tool"
    }
}

Write-Info "Checking Docker daemon..."
# docker info writes blkio/cgroup warnings to stderr even on success.
# Catch any ErrorRecords those warnings produce so they don't surface as errors.
try { docker info *>&1 | Out-Null } catch { }
if ($LASTEXITCODE -ne 0) {
    Write-Err "Docker daemon is not running. Start Docker Desktop and retry."
}

# Warn if Docker Desktop has less than 4 GB -- kind needs it for 3 nodes.
$memBytes = docker info --format '{{.MemTotal}}' 2>$null
if ($memBytes -and ([long]$memBytes -lt 4GB)) {
    $memGB = [math]::Round([long]$memBytes / 1GB, 1)
    Write-Warn "Docker only has ${memGB} GB RAM. Kind needs at least 4 GB."
    Write-Warn "Increase memory in Docker Desktop > Settings > Resources."
}

# ---------------------------------------------------------------------------
# Kind cluster
# ---------------------------------------------------------------------------
Write-Info "Checking for existing cluster..."

$clusterFound = $false
$clusterList  = kind get clusters 2>$null
if ($clusterList) {
    foreach ($name in ($clusterList -split '\r?\n')) {
        if ($name.Trim() -eq $ClusterName) {
            $clusterFound = $true
            break
        }
    }
}

if ($clusterFound) {
    Write-Warn "Cluster '$ClusterName' already exists -- skipping creation."
} else {
    Write-Info "Creating kind cluster '$ClusterName'..."
    Invoke-Exe kind create cluster `
        --name $ClusterName `
        --config deploy/kind/kind-cluster.yaml `
        --wait 120s
    Write-Info "Kind cluster created."
}

# ---------------------------------------------------------------------------
# kubectl context
# ---------------------------------------------------------------------------
Invoke-Exe kubectl config use-context "kind-$ClusterName"

# ---------------------------------------------------------------------------
# Build Docker image
# ---------------------------------------------------------------------------
Write-Info "Building Space Taco image..."
Invoke-Exe docker build `
    --target final `
    -t "${ImageName}:${ImageTag}" `
    -f app/Dockerfile `
    app/

# ---------------------------------------------------------------------------
# Load image into kind (no registry needed locally)
# ---------------------------------------------------------------------------
Write-Info "Loading image into kind cluster..."
Invoke-Exe kind load docker-image "${ImageName}:${ImageTag}" --name $ClusterName

# ---------------------------------------------------------------------------
# Namespace + Pod Security Standards
# ---------------------------------------------------------------------------
Write-Info "Creating namespace '$Namespace'..."
$nsYaml = kubectl create namespace $Namespace --dry-run=client -o yaml
if ($LASTEXITCODE -ne 0) {
    Write-Err "Failed to generate namespace manifest."
}
$nsYaml | kubectl apply -f -
if ($LASTEXITCODE -ne 0) {
    Write-Err "Failed to apply namespace manifest."
}

Invoke-Exe kubectl label namespace $Namespace `
    'pod-security.kubernetes.io/enforce=restricted' `
    'pod-security.kubernetes.io/warn=restricted' `
    --overwrite

# istio-injection=enabled tells istiod's mutating webhook to add the
# istio-proxy sidecar to every pod created in this namespace from now on.
Invoke-Exe kubectl label namespace $Namespace `
    'istio-injection=enabled' `
    --overwrite

# ---------------------------------------------------------------------------
# Kyverno
# ---------------------------------------------------------------------------
Write-Info "Installing Kyverno..."
Invoke-Exe helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update
Invoke-Exe helm upgrade --install kyverno kyverno/kyverno `
    --namespace kyverno `
    --create-namespace `
    --set admissionController.replicas=1 `
    --wait --timeout 5m

# ---------------------------------------------------------------------------
# Istio service mesh
# ---------------------------------------------------------------------------
# Replaces the NGINX ingress controller. Installed in dependency order:
#   base    -> CRDs (Gateway, VirtualService, DestinationRule, ...)
#   istiod  -> control plane (sidecar injection webhook, config distribution).
#              cni.enabled=true here is required, not just installing the cni
#              chart below: without it istiod's injection webhook doesn't
#              know a CNI plugin exists and still injects the legacy
#              privileged istio-init container, which the space-taco
#              namespace's "restricted" Pod Security Standard rejects
#              (NET_ADMIN/NET_RAW, runAsUser=0) — verified by hitting that
#              exact PodSecurity violation during local testing.
#   cni     -> per-node DaemonSet that does the iptables redirect setup for
#              injected sidecars instead. Once istiod knows about it, the
#              istio-proxy sidecar itself needs no elevated capabilities, so
#              it also passes Kyverno's space-taco-pod-security ClusterPolicy
#              unmodified.
#   gateway -> the actual ingress gateway Service/Deployment, exposed via
#              NodePort 30080/30443 (see istio-values/gateway-values.yaml) so
#              http://localhost:8080 keeps working exactly like it did with
#              NGINX.
Write-Info "Installing Istio..."
Invoke-Exe helm repo add istio https://istio-release.storage.googleapis.com/charts --force-update

Invoke-Exe helm upgrade --install istio-base istio/base `
    --namespace istio-system `
    --create-namespace `
    --wait --timeout 5m

Invoke-Exe helm upgrade --install istiod istio/istiod `
    --namespace istio-system `
    '--set' 'cni.enabled=true' `
    --wait --timeout 5m

Invoke-Exe helm upgrade --install istio-cni istio/cni `
    --namespace istio-system `
    --wait --timeout 5m

Invoke-Exe helm upgrade --install istio-ingressgateway istio/gateway `
    --namespace istio-system `
    -f deploy/kind/istio-values/gateway-values.yaml `
    --wait --timeout 5m

# ---------------------------------------------------------------------------
# Flux CRDs (source-controller + helm-controller only)
# ---------------------------------------------------------------------------
Write-Info "Installing Flux CRDs..."
$fluxYaml = flux install `
    '--components=source-controller,helm-controller' `
    '--toleration-keys=' `
    --export
# Some flux versions exit 1 even on success with --export; only hard-fail on
# empty output which means the binary itself is broken.
if (-not $fluxYaml) {
    Write-Err "flux install --export produced no output."
}
$fluxYaml | kubectl apply -f -
if ($LASTEXITCODE -ne 0) {
    Write-Err "kubectl apply of Flux CRDs failed."
}

# ---------------------------------------------------------------------------
# Deploy Space Taco via Helm
# ---------------------------------------------------------------------------
Write-Info "Deploying Space Taco via Helm..."
# ingress.enabled stays false -- the plain k8s Ingress bypasses Istio's
# routing entirely (kube-proxy resolves it before Envoy is involved), so it
# can't enforce a blue/green split. istio.enabled=true renders a Gateway +
# VirtualService + DestinationRule instead; traffic flow is now:
#   browser -> localhost:8080 -> Kind NodePort 30080 -> istio-ingressgateway
#     -> Envoy applies the VirtualService weight -> blue or green pod
# blueGreen.enabled=true renders both the "blue" and "green" Deployments.
# Both slots start on the same locally-built image/tag; bump
# blueGreen.slots.green.image.tag to a different tag later to practice a
# real version rollout, then cut over with blueGreen.activeSlot=green.
Invoke-Exe helm upgrade --install space-taco $ChartDir `
    --namespace $Namespace `
    '--set' 'image.registry=' `
    --set "image.repository=$ImageName" `
    --set "image.tag=$ImageTag" `
    '--set' 'imageVerification.enabled=false' `
    '--set' 'ingress.enabled=false' `
    '--set' 'istio.enabled=true' `
    '--set' 'istio.gateway.hosts[0]=*' `
    '--set' 'blueGreen.enabled=true' `
    '--set' 'blueGreen.activeSlot=blue' `
    --set "blueGreen.slots.blue.image.tag=$ImageTag" `
    --set "blueGreen.slots.green.image.tag=$ImageTag" `
    '--set' 'blueGreen.slots.blue.replicaCount=1' `
    '--set' 'blueGreen.slots.green.replicaCount=1' `
    --wait --timeout 3m

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Info "Space Taco is live! Test it with:"
Write-Host ""
Write-Host "  # Traffic now flows through the Istio ingress gateway, not nginx:" -ForegroundColor Cyan
Write-Host "  # browser -> localhost:8080 -> Kind NodePort 30080 -> istio-ingressgateway -> blue/green pod" -ForegroundColor Cyan
Write-Host "  # The Gateway accepts any hostname ('*') in Kind, so plain http://localhost:8080 works" -ForegroundColor Cyan
Write-Host "  # in a browser -- no Host header needed." -ForegroundColor Cyan
Write-Host ""
Write-Host "  # Health check (x-taco-slot response header shows which slot answered)" -ForegroundColor Cyan
Write-Host "  curl -i http://localhost:8080/healthz" -ForegroundColor Cyan
Write-Host ""
Write-Host "  # Menu" -ForegroundColor Cyan
Write-Host "  curl http://localhost:8080/api/v1/menu | jq ." -ForegroundColor Cyan
Write-Host ""
Write-Host "  # Place an order" -ForegroundColor Cyan
Write-Host '  curl -X POST http://localhost:8080/api/v1/orders \' -ForegroundColor Cyan
Write-Host '    -H "Content-Type: application/json" \' -ForegroundColor Cyan
Write-Host '    -d "{\"customer_id\":\"EARTHLING-001\",\"items\":[{\"filling\":\"black_hole_bbq\",\"quantity\":2}]}"' -ForegroundColor Cyan
Write-Host ""
Write-Info "Practice a blue/green cutover:"
Write-Host ""
Write-Host "  # 1. Roll out a new version to the idle 'green' slot (bump the tag to anything" -ForegroundColor Cyan
Write-Host "  #    different from `$ImageTag once you build a second image) -- it receives 0% of" -ForegroundColor Cyan
Write-Host "  #    traffic until you cut over, so this is safe to do live." -ForegroundColor Cyan
Write-Host "  helm upgrade space-taco $ChartDir -n $Namespace --reuse-values --set blueGreen.slots.green.image.tag=<new-tag>" -ForegroundColor Cyan
Write-Host ""
Write-Host "  # 2. Cut traffic over to green once it looks healthy" -ForegroundColor Cyan
Write-Host "  helm upgrade space-taco $ChartDir -n $Namespace --reuse-values --set blueGreen.activeSlot=green" -ForegroundColor Cyan
Write-Host ""
Write-Host "  # 3. Confirm the switch" -ForegroundColor Cyan
Write-Host "  curl -i http://localhost:8080/healthz   # x-taco-slot: green" -ForegroundColor Cyan
Write-Host ""
Write-Info "Enjoy your intergalactic tacos!"
