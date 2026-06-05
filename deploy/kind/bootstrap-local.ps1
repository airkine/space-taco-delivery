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
# NGINX Ingress Controller
# ---------------------------------------------------------------------------
# Deployed via Helm with NodePort 30080/30443 so traffic from localhost:8080
# and localhost:8443 reaches nginx via Kind's extraPortMappings.
# The controller is pinned to the control-plane node (ingress-ready=true label)
# with a toleration for the control-plane taint.
Write-Info "Installing NGINX ingress controller..."
Invoke-Exe helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
Invoke-Exe helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx `
    --namespace ingress-nginx `
    --create-namespace `
    '--set' 'controller.service.type=NodePort' `
    '--set' 'controller.service.nodePorts.http=30080' `
    '--set' 'controller.service.nodePorts.https=30443' `
    '--set-string' 'controller.nodeSelector.ingress-ready=true' `
    '--set' 'controller.tolerations[0].key=node-role.kubernetes.io/control-plane' `
    '--set' 'controller.tolerations[0].operator=Equal' `
    '--set' 'controller.tolerations[0].effect=NoSchedule' `
    '--set' 'controller.admissionWebhooks.enabled=false' `
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
# ingress.enabled=true creates an Ingress for nginx pointing at localhost.
# Traffic flow: browser -> localhost:8080 -> Kind NodePort 30080 -> nginx -> svc.
Invoke-Exe helm upgrade --install space-taco $ChartDir `
    --namespace $Namespace `
    '--set' 'image.registry=' `
    --set "image.repository=$ImageName" `
    --set "image.tag=$ImageTag" `
    '--set' 'imageVerification.enabled=false' `
    '--set' 'replicaCount=1' `
    '--set' 'ingress.enabled=true' `
    '--set' 'ingress.className=nginx' `
    '--set' 'ingress.hosts[0].host=localhost' `
    '--set' 'ingress.hosts[0].paths[0].path=/' `
    '--set' 'ingress.hosts[0].paths[0].pathType=Prefix' `
    --wait --timeout 3m

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Info "Space Taco is live! Test it with:"
Write-Host ""
Write-Host "  # Open in browser (ingress via nginx on Kind NodePort 30080 -> host 8080)" -ForegroundColor Cyan
Write-Host "  http://localhost:8080" -ForegroundColor Cyan
Write-Host ""
Write-Host "  # Health check" -ForegroundColor Cyan
Write-Host "  curl http://localhost:8080/healthz" -ForegroundColor Cyan
Write-Host ""
Write-Host "  # Menu" -ForegroundColor Cyan
Write-Host "  curl http://localhost:8080/api/v1/menu | jq ." -ForegroundColor Cyan
Write-Host ""
Write-Host "  # Place an order" -ForegroundColor Cyan
Write-Host '  curl -X POST http://localhost:8080/api/v1/orders \' -ForegroundColor Cyan
Write-Host '    -H "Content-Type: application/json" \' -ForegroundColor Cyan
Write-Host '    -d "{\"customer_id\":\"EARTHLING-001\",\"items\":[{\"filling\":\"black_hole_bbq\",\"quantity\":2}]}"' -ForegroundColor Cyan
Write-Host ""
Write-Info "Enjoy your intergalactic tacos!"
