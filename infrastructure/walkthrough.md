# Vault Key Rotation Demo — GitOps Walkthrough

I have implemented a production-grade GitOps architecture using two GitHub repositories and HashiCorp Vault.

> **Full system diagram & deep-dive:** see [`ARCHITECTURE.md`](./ARCHITECTURE.md) — layered
> architecture, Istio service mesh, security model, data flows, and operations.

## Architecture

This setup uses a dual-repository pattern:
1.  **Source Repo**: [shaileshp0110/kubernetes](https://github.com/shaileshp0110/kubernetes) - Contains application code and setup scripts.
2.  **Config Repo**: [shaileshp0110/gitops-config](https://github.com/shaileshp0110/gitops-config) - Contains Helm charts and ArgoCD Application manifests.

### Component Diagram
```mermaid
graph TD
    A[ArgoCD] -->|Syncs| B[shaileshp0110/gitops-config]
    B -->|Defines| R[root-local - app-of-apps]
    R -->|Owns| C[Vault]
    R -->|Owns| P[postgres + kube-prometheus-stack]
    R -->|Owns| W[frontend-dev + backend-dev]
    R -->|Owns| DE[dev-environment - app-of-apps]
    DE -->|Owns| D[Encryption Service - Node.js]
    DE -->|Owns| E[Encryption Service - Java]
    D -->|Calls| C
    E -->|Calls| C
    C -->|Manages| F[Transit Keys & Rotation]
    G[Istio ingress gateway] -->|myapp.local /| W
```

## Key Features

- **Dual-Key Support**: Demonstrates rotation for both **Symmetric (AES-256)** and **Asymmetric (RSA-2048)** keys.
- **Multi-Language Demo**: Proves interoperability between Node.js and Java using Vault as a shared encryption provider.
- **Full GitOps**: Uses the "App of Apps" pattern. The top-level `root-local` Application owns every other Application (including `dev-environment`, which owns the encryption services), so a deleted Application is recreated automatically.
- **Vault Transit Engine**: Handles encryption-as-a-service, allowing data to stay encrypted while keys are rotated in the background.
- **Service Mesh (Istio)**: Zero-trust mTLS layer and the cluster's ingress — see [Service Mesh](#service-mesh-istio) below.

## Running the Demo locally

1.  **Start the environment**:
    From the root of this repo:
    ```bash
    ./infrastructure/setup-minikube.sh
    ```
    This script builds the container images locally inside Minikube, installs ArgoCD, and applies the `root-local` app-of-apps.

2.  **Verify Synchronization** — see [ArgoCD UI](#argocd-ui) below.

3.  **Run Rotation Test**:
    ```bash
    # Basic demo — single rotation, symmetric + asymmetric keys
    ./infrastructure/demo-rotation.sh

    # Multi-rotation demo — encrypt at v1, rotate N times, verify decrypt still works
    ./infrastructure/demo-rotation-n.sh 2   # rotate twice  (key ends at v3)
    ./infrastructure/demo-rotation-n.sh 5   # rotate 5 times (key ends at v6)

    # Dual-version demo — encrypt at v1 and v3, rotate once more, decrypt both
    ./infrastructure/demo-rotation-v1-v3.sh
    ```
    `demo-rotation.sh` encrypts with Node.js, rotates once, and decrypts with Java.
    `demo-rotation-n.sh` resets each key to v1, encrypts, rotates **N** times, then proves the original v1 ciphertext still decrypts.
    `demo-rotation-v1-v3.sh` encrypts one message at **v1** and another at **v3**, rotates once more to **v4**, then decrypts both — proving Vault retains every key version.

## ArgoCD UI

ArgoCD runs inside the cluster — it is not exposed on localhost by default. You must port-forward (or use `minikube service`) before opening the UI.

### Option A: Port-forward (recommended)

In a **separate terminal**, run this and **leave it open** while you use the UI:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Then open in your browser:

**https://localhost:8080**

> Use `https://`, not `http://`. Your browser will warn about the certificate — that is expected for local port-forward; proceed anyway.

**Login credentials:**

| Field    | Value   |
|----------|---------|
| Username | `admin` |
| Password | printed at the end of `setup-minikube.sh`, or retrieve with: |

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

You should see `root-local`, `dev-environment`, `vault`, `postgres`, `kube-prometheus-stack`, `frontend-dev`, `backend-dev`, and the encryption services (plus the `istio-*` and `kiali` Applications after `setup-istio.sh`). Green status means synced and healthy.

### Option B: Minikube service URL

```bash
minikube service argocd-server -n argocd --url
```

Open the URL printed by that command.

### Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| **Connection refused** on localhost:8080 | Port-forward is not running | Start `kubectl port-forward ...` in a terminal and keep it open |
| Port-forward terminal was closed | Forwarding stops when the process exits | Re-run the port-forward command |
| Port 8080 already in use | Another process owns the port | Use a different local port: `kubectl port-forward svc/argocd-server -n argocd 9090:443` then open https://localhost:9090 |
| Blank page or TLS error | Used `http://` instead of `https://` | Open **https://localhost:8080** |
| **Connection lost** / port-forward exits | Cluster stopped or deleted | Expected — restart cluster and re-run port-forward |

## Service Mesh (Istio)

The platform runs a zero-trust Istio service mesh. Its ingress gateway is the only way into
the cluster — there is no NGINX ingress controller, so the app at `myapp.local` is reachable
only after this step. Detailed topology and policies are in
[`ARCHITECTURE.md`](./ARCHITECTURE.md#service-mesh-istio).

### Install

```bash
./infrastructure/setup-istio.sh
```

The script is idempotent and runs: preflight checks → ArgoCD Applications
(`istio-base` → `istiod` → `istio-ingressgateway` → `kiali`, ordered by sync-wave) →
mesh config (STRICT mTLS + allow-list AuthorizationPolicies + Prometheus monitors +
`myapp.local` Gateway/VirtualService) → sidecar injection on `default` + workload rollout.

> The `istio-ingressgateway` Service is a `LoadBalancer`. On minikube, run
> `minikube tunnel` so it gets an external IP (`127.0.0.1`). Until then its ArgoCD
> Application shows `Progressing` even though the deployment is `1/1` — that is expected.
> Gateway chart is pinned to **1.27.1** because ArgoCD's
> repo-server runs Helm v4, whose strict schema validation rejects older gateway charts.

### Access the app

In a **separate terminal**, run this and leave it open (it asks for your password because
it binds port 80):

```bash
minikube tunnel
```

Map the hostname once:

```bash
echo "127.0.0.1 myapp.local" | sudo tee -a /etc/hosts
```

Then open `http://myapp.local/` (React UI) or `http://myapp.local/api/users` (backend).
Requests go browser → Istio ingress gateway → frontend / backend over mTLS.

### Verify

```bash
kubectl get pods -n default                    # app pods show 2/2 (app + istio-proxy)
kubectl get peerauthentication -A              # STRICT mTLS
kubectl get authorizationpolicy -A             # deny-all + explicit ALLOW rules
kubectl get gateway,virtualservice -n default  # myapp.local routing
kubectl get svc istio-ingressgateway -n istio-system   # EXTERNAL-IP 127.0.0.1 while the tunnel runs
```

### Kiali (mesh UI)

```bash
kubectl port-forward svc/kiali -n istio-system 20001:20001
# http://localhost:20001  (anonymous auth for local demo)
```

### Demo scripts under the mesh

The rotation scripts create throwaway `curl-test` pods. With sidecar injection enabled on
`default`, those pods would get an Envoy sidecar and fail to exit under `--rm -i`. They
already opt out with the annotation `sidecar.istio.io/inject: "false"` in their `kube_curl`
helper — no change needed to run the demos against a meshed cluster.

## Stopping and Cleanup

When you're done with the demo, shut things down at the level you need.

### Stop port-forwards first

Close any terminals still running:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
minikube tunnel
```

If the cluster stops, port-forwards will exit with **"lost connection to pod"** — that is normal.

### Pause the cluster (keep data, resume later)

Stops all pods but keeps the cluster and its state on disk:

```bash
minikube stop
```

Start again with:

```bash
minikube start
```

### Delete the cluster (full teardown)

Removes the cluster and everything deployed (ArgoCD, Vault, apps, postgres):

```bash
minikube delete
```

### Complete cleanup (free disk space)

Removes all minikube profiles and cached images:

```bash
minikube delete --all --purge
```

### What to use when

| Goal | Command |
|------|---------|
| Pause, resume later | `minikube stop` |
| Done with this demo | `minikube delete` |
| Free disk space / fresh start | `minikube delete --all --purge` |

### Start again from scratch

```bash
./infrastructure/setup-minikube.sh
./infrastructure/setup-istio.sh
```

## Summary of Fixes Applied
- **Manifest Cleanup**: Fixed `env` variable formatting to match the Helm chart's expected array structure.
- **DNS names**: Used `fullnameOverride` in Helm values to ensure predictable DNS names during the demo.
- **Local Compatibility**: Set `image.pullPolicy: Never` for services built locally in the Minikube Docker daemon.
