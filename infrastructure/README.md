# Local Kubernetes Environment Setup

This guide deploys the full stack on a local `minikube` cluster: ArgoCD (GitOps), Vault
Transit encryption, the demo apps, Prometheus/Grafana, and an Istio service mesh whose
ingress gateway is the only way into the cluster.

> **Architecture & diagrams:** [`ARCHITECTURE.md`](./ARCHITECTURE.md)
> **Guided demo:** [`walkthrough.md`](./walkthrough.md)

## Prerequisites

- Docker (running)
- `minikube`
- `kubectl`
- `helm`

## Repository layout

The scripts expect this repo and the GitOps config repo to sit side by side:

```
<parent>/
  kubernetes/      # this repo — app source + infrastructure/ scripts
  gitops-config/   # https://github.com/shaileshp0110/gitops-config — charts + ArgoCD Applications
```

ArgoCD reads `gitops-config` **from GitHub**, not from your local folder. Changes there take
effect only after they are pushed.

## 1. Create the cluster and deploy the stack

From the root of this repo:

```bash
./infrastructure/setup-minikube.sh
```

The script:

1. Starts minikube (4 CPUs, up to 8 GB).
2. Builds the four app images inside minikube's Docker daemon (`pullPolicy: Never`).
3. Installs ArgoCD.
4. Applies the root Application `gitops-config/clusters/root-local.yaml` (app-of-apps). It
   creates and owns every other Application: `vault`, `postgres`, `kube-prometheus-stack`,
   `frontend-dev`, `backend-dev`, and `dev-environment` (which owns the two encryption
   services). A deleted child Application is recreated automatically.
5. Waits for Vault and creates the Transit keys `demo-key-symmetric` and `demo-key-asymmetric`.

Check progress:

```bash
kubectl get applications -n argocd     # all should be Synced / Healthy
kubectl get pods -A
```

## 2. Install the service mesh and ingress gateway

```bash
./infrastructure/setup-istio.sh
```

This installs Istio through ArgoCD (`istio-base`, `istiod`, `istio-ingressgateway`, `kiali`,
`istio-config`), enables sidecar injection on the `default` namespace, and restarts the app
workloads so they get sidecars.

`istio-config` includes the `Gateway` and `VirtualService` that route `myapp.local`:

| Path | Destination |
|------|-------------|
| `/api/*` | `backend-dev:3000` |
| `/*` | `frontend-dev:80` |

There is no NGINX ingress controller. Without this step the app is not reachable from
outside the cluster.

## 3. Access the application

The ingress gateway is a `LoadBalancer` Service. On minikube it gets an external IP only
while a tunnel is running. In a **separate terminal**, run this and leave it open (it asks
for your password because it binds port 80):

```bash
minikube tunnel
```

Until the tunnel is running, the `istio-ingressgateway` Application shows `Progressing` in
ArgoCD. That is expected; it turns `Healthy` once the Service has an IP.

Map the hostname once:

```bash
echo "127.0.0.1 myapp.local" | sudo tee -a /etc/hosts
```

Then open:

- `http://myapp.local/` — the React interface.
- `http://myapp.local/api/users` — the Node.js backend.

## 4. ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open **https://localhost:8080** (accept the self-signed certificate). Username `admin`;
password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

## 5. Key rotation demo

Once the encryption-service pods are running:

```bash
./infrastructure/demo-rotation.sh
```

See [`walkthrough.md`](./walkthrough.md) for the other rotation scenarios.

## 6. View metrics

Grafana:

```bash
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
```

Open http://localhost:3000 and log in with `admin` / `admin`. Prometheus picks up targets
for pods with a `ServiceMonitor` or `PodMonitor` attached.

Kiali (mesh topology):

```bash
kubectl port-forward svc/kiali -n istio-system 20001:20001
```

Open http://localhost:20001.

## Teardown

```bash
minikube stop      # pause, keep state
minikube delete    # remove the cluster
```
