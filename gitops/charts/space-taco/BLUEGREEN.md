# Blue/Green Deployment Runbook

This chart already implements blue/green deployments end to end
(`blueGreen.*` + `istio.*` values). This document is the operational
process for using it — how it works, and the exact steps to roll out a new
version and cut traffic over, for both the local Kind environment and the
AKS/Flux-managed production environment.

## 1. How it works

- **`templates/service.yaml`** — a single `Service` whose selector has no
  `version` label, so it matches pods from both slots at once.
- **`templates/deployment.yaml`** (+ the `space-taco.deployment` helper in
  `_helpers.tpl`) — when `blueGreen.enabled: true`, renders **two**
  Deployments instead of one, pod-labeled `version: blue` and
  `version: green`. Both run at their full configured replica count
  **at all times** — the idle slot is a hot standby, not scaled to zero, so
  a cutover is instant with no cold start.
- **`templates/istio-destinationrule.yaml`** — when Istio is also enabled,
  defines two subsets (`blue`, `green`) keyed on that `version` pod label.
- **`templates/istio-virtualservice.yaml`** — routes 100% of traffic to
  `blueGreen.activeSlot`'s subset and 0% to the other, and stamps every
  response with an `x-taco-slot: <slot>` header so you can verify which
  slot actually answered a request.
- **Plain Ingress→Service traffic bypasses Envoy entirely** (kube-proxy
  resolves it before Istio is involved) and round-robins both slots
  regardless of `activeSlot`. **Only traffic through the Istio Gateway
  honors the blue/green weighting.** On AKS that's the
  `aks-istio-ingressgateway-external` LoadBalancer Service, a second entry
  point alongside the Web App Routing Ingress — see root `README.md`'s
  "Blue/Green with Istio" section.

Current live AKS values (`gitops/flux/apps/helmrelease-space-taco.yaml`):
`blueGreen.enabled: true`, `activeSlot: blue`, both slots at
`replicaCount: 1`, image tag inherited from the global `tag: "latest"`.

## 2. Picking an image tag

`latest` is what **both** slots already track by default — setting
`blueGreen.slots.green.image.tag=latest` is a no-op, not a real test.

`.github/workflows/build.yml` pushes, on every push to `main`:
- `sha-<shortsha>` — immutable, available immediately after the build
- the branch name (e.g. `main`)
- `latest`
- `vX.Y.Z` — a semver tag, added slightly later once the `release` job
  computes the next version from Conventional Commits

**Use `sha-<shortsha>` or `vX.Y.Z` for the idle slot — never `latest`.**
Find the right `sha-` tag from the `build.yml` run for the commit you want,
or the `vX.Y.Z` tag from the corresponding GitHub Release.

## 3. Process

The mechanism differs by environment — pick the right one.

### Kind / local

No Flux is managing this release locally, so `helm upgrade` directly
against the cluster is correct here.

```bash
# 1. Roll the new tag out to the idle slot — it's at 0% traffic, safe to do live
helm upgrade space-taco gitops/charts/space-taco -n space-taco \
  --reuse-values --set blueGreen.slots.green.image.tag=sha-<shortsha>

# 2. Verify the idle slot before cutting traffic — see "Verification" below

# 3. Cut over
helm upgrade space-taco gitops/charts/space-taco -n space-taco \
  --reuse-values --set blueGreen.activeSlot=green

# 4. Rollback if needed — blue is still running at full capacity, instant
helm upgrade space-taco gitops/charts/space-taco -n space-taco \
  --reuse-values --set blueGreen.activeSlot=blue
```

### AKS (production)

**Do not run `helm upgrade` directly against the AKS cluster.** Flux
reconciles `helmrelease-space-taco.yaml` every 10 minutes (`spec.interval`)
and owns this release — any direct change will be silently reverted on the
next reconcile. The change has to go through Git, the same review process
as every other change in this repo.

```bash
# 1. Edit gitops/flux/apps/helmrelease-space-taco.yaml — under values.blueGreen:
#      slots:
#        green:
#          image:
#            tag: "sha-<shortsha>"   # or "vX.Y.Z" — never "latest"
#    Commit, push, open a PR, get it reviewed and merged to main.

# 2. Force an immediate reconcile instead of waiting up to 10 minutes:
kubectl annotate helmrelease space-taco -n space-taco \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite

# 3. Verify the idle (green) slot's pods — it's at 0% of real traffic, safe
#    to check directly. See "Verification" below.

# 4. Cut over: edit the same file, set
#      blueGreen:
#        activeSlot: "green"
#    Commit, push, PR, merge, then force-reconcile again (step 2's command).

# 5. Rollback if needed: revert activeSlot back to "blue" the same way —
#    blue is still running at full capacity, this is instant.
```

## 4. Verification

```bash
# Confirm pods on the idle slot are healthy BEFORE cutting traffic
kubectl get pods -n space-taco -l version=green
kubectl logs -n space-taco -l version=green --tail=50

# Confirm which slot is actually serving traffic, post-cutover
curl -i https://taco-delivery.autoaaron.xyz/healthz   # look for: x-taco-slot: green

# Confirm Kyverno didn't reject the new image — verify-space-taco-image-signature
# (kyverno-policies.yaml) enforces a Sigstore/Cosign signature + Rekor
# attestation on every pod in this namespace before it's even admitted
kubectl get events -n space-taco --field-selector reason=FailedCreate

# Confirm Istio is actually weighting traffic (not just round-robin via the
# plain Web App Routing Ingress, which ignores activeSlot entirely)
GATEWAY_IP=$(kubectl get svc aks-istio-ingressgateway-external -n aks-istio-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
for i in $(seq 1 10); do
  curl -s -o /dev/null -w "%{header_x-taco-slot}\n" \
    -H "Host: taco-delivery.autoaaron.xyz" "https://${GATEWAY_IP}/healthz"
done
```

## 5. Caveats

- **The in-memory order store is per-slot, not shared.**
  `app/internal/store`'s `MemoryStore` is a per-process map — blue and
  green each hold their own independent order list. AKS dev runs with
  `REDIS_URL: ""` (cost-saving, see `helmrelease-space-taco.yaml`), so
  **cutting traffic over loses/splits order history**: green starts with
  only its seed data, and orders placed against blue won't show up. Even
  with Redis configured, `ListOrders` still reads from the inner memory
  store — Redis only shares individual order lookups, not the full list.
  This is an accepted trade-off for this dev/demo app, not a bug — just
  don't be surprised by it mid-cutover.
- Both slots run at full replica count permanently, so blue/green roughly
  doubles steady-state pod count and resource requests versus a single
  Deployment. Already accounted for in this repo's per-pod Istio sidecar
  resource overrides (`helmrelease-space-taco.yaml`'s `podAnnotations`).
- A new image must pass Kyverno's `verify-space-taco-image-signature`
  ClusterPolicy before its pod is admitted — automatic for anything built
  via `build.yml`, no manual signing step required.
