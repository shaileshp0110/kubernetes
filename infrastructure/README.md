# Local Kubernetes Environment Setup

This guide deploys the full stack on a local `minikube` cluster: ArgoCD (GitOps), Vault
Transit encryption, the demo apps, Prometheus/Grafana, and an Istio service mesh whose
ingress gateway is the only way into the cluster.

> **Architecture & diagrams:** [`ARCHITECTURE.md`](./ARCHITECTURE.md)
> **Guided demo:** [`walkthrough.md`](./walkthrough.md)

## UI quick reference

Once the stack is running (sections 1–3):

| UI | URL | Needs running | Login |
|----|-----|---------------|-------|
| App (React frontend) | http://myapp.local/ | `minikube tunnel` | — |
| Backend API | http://myapp.local/api/users | `minikube tunnel` | — |
| ArgoCD | https://localhost:8080 | `kubectl port-forward svc/argocd-server -n argocd 8080:443` | `admin` / see section 4 |
| Grafana | http://localhost:3000 | `kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80` | none to view; `admin` / `admin` to edit |
| Kiali | http://localhost:20001 | `kubectl port-forward svc/kiali -n istio-system 20001:20001` | — |

Run each command in its own terminal and leave it open.

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
2. Builds the five app images inside minikube's Docker daemon (`pullPolicy: Never`).
3. Installs ArgoCD.
4. Applies the root Application `gitops-config/clusters/root-local.yaml` (app-of-apps). It
   creates and owns every other Application: `vault`, `postgres`, `kube-prometheus-stack`, `loki`,
   `frontend-dev`, `backend-dev`, and `dev-environment` (which owns the two encryption
   services and `logger-service`). A deleted child Application is recreated automatically.
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

The first request to `myapp.local` can take about 5 seconds: macOS treats `.local` names as
mDNS and waits for that lookup to time out before reading `/etc/hosts`. Adding an IPv6 entry
removes the delay:

```bash
echo "::1 myapp.local" | sudo tee -a /etc/hosts
```

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

Open http://localhost:3000 and log in with the default credentials:

- Username: `admin`
- Password: `admin`

Dashboards and Explore are readable **without logging in** (anonymous Viewer access); log
in as `admin` only to edit. Grafana may ask you to change the password on first login; you
can skip that. Grafana has no persistent storage here, so a changed password — and any
dashboard you create in the UI — is lost when its pod restarts, which also resets the
login to `admin` / `admin`:

```bash
kubectl rollout restart deploy/kube-prometheus-stack-grafana -n monitoring
```

**Metrics.** Prometheus picks up targets for pods with a `ServiceMonitor` or `PodMonitor`
attached. The Grafana home page is empty; go to **Dashboards → Browse**:

- `Kubernetes / Compute Resources / Namespace (Pods)` — CPU and memory per pod; pick
  namespace `default`.
- Folder `Istio` — Mesh, Service, Workload and Control Plane dashboards (request rate,
  errors, latency per service).

Or use **Explore** with the `Prometheus` datasource, for example:

```
sum(rate(istio_requests_total[5m])) by (destination_workload)
```

Set the time range to `Last 15 minutes` after a restart; older ranges are empty. The etcd,
scheduler and controller-manager dashboards stay empty on minikube, because those
components listen on localhost only.

**Logs.** Promtail tails every pod's logs into Loki. In **Explore**, choose the `Loki`
datasource and query by label, for example the messages written by the scheduled logger
service:

```
{namespace="default", container="microservice", pod=~"logger-service-.*"}
```

Loki keeps logs in the pod's own storage, so history is lost when the Loki pod restarts.

Kiali (mesh topology):

```bash
kubectl port-forward svc/kiali -n istio-system 20001:20001
```

Open http://localhost:20001.

**Kiali → Grafana uses no credentials.** Kiali calls the Grafana API to check its version
and to build the "View in Grafana" links. Grafana allows anonymous Viewer access
(`grafana.ini` `auth.anonymous` in `gitops-config/clusters/local-cluster/core-infrastructure.yaml`),
so Kiali is configured with `external_services.grafana.auth.type: none` in
`gitops-config/clusters/local-cluster/istio.yaml`. Kiali's own graph and metrics come from
Prometheus and do not depend on this.

This is a local-only shortcut: anyone who can reach Grafana can read every dashboard. In
production, disable anonymous access and use a Grafana service account with the Viewer
role, a bearer token held in a secret manager and synced into a Kubernetes `Secret`, and
reference it from the Kiali config (`auth.type: bearer`, `token: secret:<secret-name>:<key>`).

Each `kubectl port-forward` blocks its terminal until you stop it. Run the ArgoCD, Grafana
and Kiali forwards in three separate terminals; pasting them into one starts only the first.

## 7. Scheduled logger service

`logger-service` is a small Rust REST service (`POST /log`, `GET /health`, port 8080). A
Kubernetes `CronJob`, `logger-service-trigger`, POSTs a message to it every minute, and the
service writes that message to its log.

```bash
kubectl get cronjob,jobs -n default
kubectl logs deploy/logger-service -n default -c microservice -f
```

The schedule and message are set in `gitops-config/environments/dev/logger-service/values.yaml`.

## Restarting after `minikube stop`

`minikube start` brings the cluster, the pods and the built images back, but not everything:

```bash
# 1. Start the cluster and wait for the pods
minikube start
kubectl get pods -A

# 2. Recreate the Vault Transit engine and keys. Vault runs in dev mode (in-memory),
#    so they are lost on every restart and the encryption services fail without them.
kubectl exec -n vault vault-0 -- vault secrets enable transit
kubectl exec -n vault vault-0 -- vault write -f transit/keys/demo-key-symmetric type=aes256-gcm96
kubectl exec -n vault vault-0 -- vault write -f transit/keys/demo-key-asymmetric type=rsa-2048

# 3. In a separate terminal, leave running (needed for http://myapp.local)
minikube tunnel
```

Then start the port-forwards from sections 4 and 6 for any UI you want to open.

After a `minikube delete`, run `setup-minikube.sh` and `setup-istio.sh` again instead
(sections 1 and 2).

## Rebuilding an app image

The Deployments use `pullPolicy: Never`, so an image must exist in **minikube's** Docker
daemon. An image built in your local Docker is not visible to the cluster and the pod
fails with `ErrImageNeverPull`. From the root of this repo:

```bash
eval $(minikube docker-env)
docker build -t logger-service:latest logger-service
kubectl rollout restart deployment/logger-service -n default
```

Use the same pattern for the other services (`frontend`, `backend`, `encryption-service`,
`encryption-service-java`); their Deployment names are listed by `kubectl get deploy -n default`.

## Teardown

```bash
minikube stop      # pause, keep state
minikube delete    # remove the cluster
```
