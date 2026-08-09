#!/bin/bash

# setup-istio.sh - Install and configure the Istio service mesh via ArgoCD (GitOps)
#
# What it does, in order (idempotent — safe to re-run):
#   1. Preflight checks (kubectl, helm, argocd server, cluster reachable)
#   2. Apply Istio ArgoCD Applications (istio-base → istiod → gateway → kiali)
#   3. Wait for the control plane to become healthy (CRDs before workloads)
#   4. Wait for istio-config Application (STRICT mTLS, deny-all + allow-list authz, metrics)
#   5. Enable sidecar injection on app namespaces and restart workloads to inject sidecars
#   6. Print access + verification steps
#
# Prerequisites:
#   - ArgoCD installed (./infrastructure/setup-minikube.sh does this)
#   - kube-prometheus-stack installed (provides Prometheus for Kiali + monitors)
#
# Usage:
#   ./infrastructure/setup-istio.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GITOPS_DIR="$PROJECT_ROOT/gitops-config/clusters/local-cluster"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo "============================================="
echo "  Istio Service Mesh — GitOps Install"
echo "============================================="

# ---------------------------------------------------------------
# 1. Preflight checks
# ---------------------------------------------------------------
echo ""
echo "--- 1. Preflight checks ---"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo -e "${RED}Missing required command: $1${NC}"; exit 1; }
}
require_cmd kubectl
require_cmd helm

kubectl cluster-info >/dev/null 2>&1 || { echo -e "${RED}Cannot reach the cluster (kubectl).${NC}"; exit 1; }
echo -e "${GREEN}Cluster reachable.${NC}"

if ! kubectl get deployment argocd-server -n argocd >/dev/null 2>&1; then
  echo -e "${RED}ArgoCD not found in namespace 'argocd'. Run ./infrastructure/setup-minikube.sh first.${NC}"
  exit 1
fi
echo -e "${GREEN}ArgoCD present.${NC}"

# Prometheus is optional but recommended for Kiali + sidecar metrics.
if kubectl get deployment kube-prometheus-stack-operator -n monitoring >/dev/null 2>&1; then
  echo -e "${GREEN}kube-prometheus-stack detected (metrics enabled).${NC}"
else
  echo -e "${YELLOW}kube-prometheus-stack not found. Kiali/metrics will have no data source until it is installed.${NC}"
fi

# ---------------------------------------------------------------
# 2. Apply Istio control-plane Applications
# ---------------------------------------------------------------
echo ""
echo "--- 2. Applying Istio ArgoCD Applications ---"
kubectl apply -f "$GITOPS_DIR/istio.yaml"
echo "Applications created: istio-base, istiod, istio-ingressgateway, kiali"

# ---------------------------------------------------------------
# 3. Wait for control plane (ordered by sync-wave)
# ---------------------------------------------------------------
echo ""
echo "--- 3. Waiting for Istio control plane ---"

wait_app() {
  local app=$1
  local timeout=${2:-600}
  local elapsed=0
  echo "  Waiting for Application '$app' to be Healthy..."
  while [ "$elapsed" -lt "$timeout" ]; do
    local status
    status=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")
    if [ "$status" = "Healthy" ]; then
      echo -e "  ${GREEN}'$app' is Healthy.${NC}"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo -e "  ${YELLOW}'$app' not Healthy yet — check: kubectl get application $app -n argocd${NC}"
  return 1
}

wait_app istio-base
wait_app istiod

echo "  Waiting for istiod deployment..."
if ! kubectl wait --for=condition=available deployment/istiod -n istio-system --timeout=300s; then
  echo -e "  ${YELLOW}istiod deployment not available yet — continuing (Argo may still be syncing).${NC}"
fi
echo -e "${GREEN}Control plane ready.${NC}"

# Note: gateway + kiali settle after the control plane is healthy.
wait_app istio-ingressgateway
wait_app kiali
wait_app istio-config

# ---------------------------------------------------------------
# 4. Mesh config (GitOps via istio-config Application)
# ---------------------------------------------------------------
echo ""
echo "--- 4. Mesh config (istio-config Application) ---"
echo "  mTLS STRICT + deny-all allow-list authz + Prometheus monitors."
istio_cfg_health=$(kubectl get application istio-config -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")
if [ "$istio_cfg_health" != "Healthy" ] && [ -d "$GITOPS_DIR/istio-config" ]; then
  echo -e "  ${YELLOW}istio-config not synced from Git — applying local kustomize bootstrap.${NC}"
  echo "  Push gitops-config to GitHub for Argo to own mesh policy long-term."
  kubectl apply -k "$GITOPS_DIR/istio-config" --server-side --force-conflicts
fi

# ---------------------------------------------------------------
# 5. Enable sidecar injection and roll workloads
# ---------------------------------------------------------------
echo ""
echo "--- 5. Enabling sidecar injection ---"

# Meshed namespaces. Vault and monitoring stay OUT of the mesh to keep the
# secret store and the metrics stack independent of mesh config changes.
for ns in default; do
  kubectl label namespace "$ns" istio-injection=enabled --overwrite
  echo "  Labeled namespace '$ns' istio-injection=enabled"
done

echo "  Restarting demo app workloads to inject sidecars..."
for dep in frontend-dev backend-dev encryption-service-dev encryption-service-java-dev; do
  kubectl rollout restart "deployment/$dep" -n default 2>/dev/null || true
done
echo "  Waiting for rollouts..."
for dep in frontend-dev backend-dev encryption-service-dev encryption-service-java-dev; do
  kubectl rollout status "deployment/$dep" -n default --timeout=300s 2>/dev/null || true
done

# ---------------------------------------------------------------
# 6. Summary
# ---------------------------------------------------------------
echo ""
echo "============================================="
echo "  Istio Install Complete"
echo "============================================="
echo ""
echo "  Kiali UI:   kubectl port-forward svc/kiali -n istio-system 20001:20001"
echo "              Then open http://localhost:20001"
echo ""
echo "  Verify mesh:"
echo "    kubectl get pods -n default        # each app pod shows 2/2 (app + istio-proxy)"
echo "    kubectl get peerauthentication -A"
echo "    kubectl get authorizationpolicy -A"
echo ""
echo "  Migration note (zero-trust):"
echo "    STRICT mTLS with deny-all + explicit ALLOW policies (see istio-config/)."
echo "    mesh-local-ingress.yaml adds PERMISSIVE ports for the nginx addon only."
echo ""
echo "  Demo scripts note:"
echo "    The rotation demo scripts create throwaway curl pods. After enabling the mesh,"
echo "    those pods must opt out of sidecar injection. Use the override below in the"
echo "    script's kube_curl helper:"
echo ""
echo "      kubectl run curl-test --image=curlimages/curl --rm -i --restart=Never --quiet \\"
echo "        --overrides='{\"metadata\":{\"annotations\":{\"sidecar.istio.io/inject\":\"false\"}}}' \\"
echo "        -- \"\$@\""
