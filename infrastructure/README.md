# Local Kubernetes Environment Setup

This guide walks you through deploying the scalable architecture on a local Kubernetes cluster using `kind` or `minikube`.

## Prerequisites
- Docker
- `kubectl`
- `kind` or `minikube`
- `helm`
- `argocd` CLI (optional, for debugging)

## 1. Create a Local Cluster

**Using Minikube (Option A):**
Start your minikube cluster and enable the standard NGINX Ingress addon.

```bash
minikube start
minikube addons enable ingress
```

In a separate terminal, run the following command and leave it open so it exposes the Ingress to your localhost:
```bash
minikube tunnel
```

---

**Using Kind (Option B):**
Create a cluster that maps ports 80/443 to your localhost to allow Ingress access.

```bash
cat <<EOF | kind create cluster --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
EOF
```

**Install NGINX Ingress Controller:**
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
```

Wait until the ingress is ready:
```bash
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s
```

## 2. Install ArgoCD

Install ArgoCD in your cluster:

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Port-forward the ArgoCD UI if you want to inspect via browser:
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```
Login using username `admin`. The password can be retrieved via:
```bash
argocd admin initial-password -n argocd
```

# Infrastructure & Security Demo

This project demonstrates a secure encryption workflow in Kubernetes using HashiCorp Vault's Transit Secret Engine with automatic key rotation.

## Local Setup with Minikube

To run this entire stack on your local machine:

1.  **Run the setup script**:
    This will start minikube, build the container images locally, and install ArgoCD + Vault.
    ```bash
    chmod +x infrastructure/setup-minikube.sh
    ./infrastructure/setup-minikube.sh
    ```

2.  **Run the Key Rotation Demo**:
    Once all pods are running (`kubectl get pods -A`), demonstrate the key rotation:
    ```bash
    chmod +x infrastructure/demo-rotation.sh
    ./infrastructure/demo-rotation.sh
    ```

## 3. Deploy the Application Stack (GitOps)

Since ArgoCD expects a Git repository, you need to push this code to a Git repository and update the `repoURL` in the `argocd/*.yaml` files.

Once pushed, apply the root ArgoCD manifests:

```bash
kubectl apply -f argocd/postgres.yaml
kubectl apply -f argocd/backend.yaml
kubectl apply -f argocd/frontend.yaml
kubectl apply -f argocd/observability.yaml
```

ArgoCD will automatically sync the Helm charts, deploy PostgreSQL, create the Backend and Frontend with their HPAs, and set up Prometheus for observability.

## 4. Access the Application

Add the following to your `/etc/hosts` file to map `myapp.local` to localhost:
```
127.0.0.1   myapp.local
```

Access the Frontend:
- Navigating to `http://myapp.local/` will show the React interface.
- Navigating to `http://myapp.local/api/users` will hit the Node.js backend.

## 5. View Metrics

To access Grafana (deployed by the observability stack):
```bash
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
```
Login with `admin` / `admin`. You will see Prometheus automatically picking up targets for pods with `ServiceMonitor` attached.
