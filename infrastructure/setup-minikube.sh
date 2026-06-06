#!/bin/bash

# setup-minikube.sh - Full local setup: Minikube + ArgoCD + Vault + Encryption Services
#
# Prerequisites:
#   - minikube installed
#   - helm installed
#   - kubectl installed
#   - Docker images pushed (or we build them locally in minikube)
#
# Git Repos:
#   - https://github.com/shaileshp0110/kubernetes.git     (app source code)
#   - https://github.com/shaileshp0110/gitops-config.git  (GitOps config - ArgoCD reads this)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "============================================="
echo "  Full GitOps Demo - Minikube Setup"
echo "============================================="

# --- 1. Start Minikube ---
echo ""
echo "--- 1. Starting Minikube ---"
if minikube status 2>/dev/null | grep -q "Running"; then
  echo "Minikube is already running."
else
  minikube start --cpus 4 --memory 8192
fi

# --- 2. Build Docker Images inside Minikube ---
echo ""
echo "--- 2. Building Docker Images in Minikube ---"
eval $(minikube docker-env)

echo "Building encryption-service (Node.js)..."
docker build -t encryption-service:latest "$PROJECT_ROOT/apps/encryption-service"

echo "Building encryption-service-java (Java/Spring Boot)..."
docker build -t encryption-service-java:latest "$PROJECT_ROOT/apps/encryption-service-java"

echo "Docker images built successfully."

# --- 3. Install ArgoCD ---
echo ""
echo "--- 3. Installing ArgoCD ---"
kubectl create namespace argocd 2>/dev/null || echo "Namespace 'argocd' already exists"
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for ArgoCD server to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# Get ArgoCD admin password
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo ""
echo "  ArgoCD Admin Credentials:"
echo "    Username: admin"
echo "    Password: $ARGOCD_PASSWORD"
echo ""

# --- 4. Deploy Core Infrastructure via ArgoCD ---
echo ""
echo "--- 4. Deploying Core Infrastructure ---"

# Apply Vault (uses Helm chart repo directly, no git needed)
kubectl apply -f "$PROJECT_ROOT/gitops-config/clusters/local-cluster/vault.yaml"
echo "Vault Application created."

# Apply core infrastructure (postgres, prometheus - also from Helm chart repos)
kubectl apply -f "$PROJECT_ROOT/gitops-config/clusters/local-cluster/core-infrastructure.yaml"
echo "Core infrastructure Applications created."

# --- 5. Deploy Dev Environment via ArgoCD (App of Apps) ---
echo ""
echo "--- 5. Deploying Dev Environment (App of Apps) ---"

# This is the ArgoCD "App of Apps" pattern.
# It reads from https://github.com/shaileshp0110/gitops-config.git
# and discovers all Application.yaml files under environments/dev/
kubectl apply -f "$PROJECT_ROOT/gitops-config/clusters/local-cluster/dev-environment.yaml"
echo "Dev environment Application created."
echo ""
echo "ArgoCD will now:"
echo "  1. Pull from https://github.com/shaileshp0110/gitops-config.git"
echo "  2. Discover all Application manifests in environments/dev/"
echo "  3. Deploy: frontend, backend, encryption-service, encryption-service-java"

# --- 6. Wait for Vault ---
echo ""
echo "--- 6. Waiting for Vault to be ready ---"
echo "This may take a few minutes on first run..."
kubectl wait --for=condition=Ready pod/vault-0 -n vault --timeout=300s 2>/dev/null || echo "Vault pod not ready yet. Check: kubectl get pods -n vault"

# --- 7. Setup Vault Transit Engine ---
echo ""
echo "--- 7. Configuring Vault Transit Engine ---"
kubectl exec -n vault vault-0 -- vault secrets enable transit 2>/dev/null || echo "Transit engine already enabled"
kubectl exec -n vault vault-0 -- vault write -f transit/keys/demo-key-symmetric type=aes256-gcm96 2>/dev/null || echo "Key 'demo-key-symmetric' already exists"
kubectl exec -n vault vault-0 -- vault write -f transit/keys/demo-key-asymmetric type=rsa-2048 2>/dev/null || echo "Key 'demo-key-asymmetric' already exists"
echo "Vault Transit engine configured with symmetric and asymmetric keys."

# --- 8. Summary ---
echo ""
echo "============================================="
echo "  Setup Complete!"
echo "============================================="
echo ""
echo "  ArgoCD UI:  Run 'kubectl port-forward svc/argocd-server -n argocd 8080:443'"
echo "              Then open https://localhost:8080"
echo "              Username: admin"
echo "              Password: $ARGOCD_PASSWORD"
echo ""
echo "  Check pods: kubectl get pods -A"
echo ""
echo "  Next step:  Once encryption-service pods are running, run:"
echo "              ./infrastructure/demo-rotation.sh"
