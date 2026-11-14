[← Back to Main README](../README.md) | [← Previous: Argo CD, Cloudflare Tunnel & Google OIDC](04-argocd-cloudflare-oidc.md) | [Next: Operations & Cost Management →](06-operations-and-cleanup.md)

---

# 5. Deploy MongoDB ReplicaSet (`9.0.8`) & Prometheus Metrics Exporter

- [Overview & Architecture](#overview--architecture)
- [Resource Requests & Limits Sizing Rationale](#resource-requests--limits-sizing-rationale)
- [Step 1: GitOps Deployment via Argo CD](#step-1-gitops-deployment-via-argo-cd)
- [Step 2: Retrieve the Generated MongoDB Credentials](#step-2-retrieve-the-generated-mongodb-credentials)
- [Step 3: Expose MongoDB (`27017/TCP`) Externally via Cloudflare Tunnel](#step-3-expose-mongodb-27017tcp-externally-via-cloudflare-tunnel)
- [Step 4: Externalize Prometheus Metrics (`9216/TCP`) via Cloudflare Tunnel](#step-4-externalize-prometheus-metrics-9216tcp-via-cloudflare-tunnel)

---

## Overview & Architecture

MongoDB is deployed into a dedicated **`mongodb`** namespace via Argo CD ([`argocd/apps/mongodb.yaml`](../argocd/apps/mongodb.yaml)) using the **Bitnami MongoDB Helm Chart** (`version: 20.0.20`, which packages **MongoDB `9.0.8`** and **`mongodb-exporter` `0.54.0`**) and values defined in [`mongodb/values.yaml`](../mongodb/values.yaml).

### Key Design Choices
* **ReplicaSet Topology (1 Replica per Node):** Configured with `architecture: replicaset`, `replicaCount: 3`, and `podAntiAffinityPreset: hard`, guaranteeing that `mongodb-0`, `mongodb-1`, and `mongodb-2` are scheduled on separate RKE2 nodes (`rke2-node-1`, `rke2-node-2`, `rke2-node-3`).
* **No Arbiter & Ephemeral Storage:** `arbiter.enabled: false` (3 data-bearing replicas already form a complete voting quorum) and `persistence.enabled: false` (`emptyDir` storage).
* **Actively Patched Bitnami Images:** Chart `20.0.20` pulls the actively maintained `registry-1.docker.io/bitnami/mongodb:latest` (`9.0.8`) and `registry-1.docker.io/bitnami/mongodb-exporter:latest` (`0.54.0`) images directly without requiring `bitnamilegacy/*` overrides or `allowInsecureImages: true`.
* **GitOps Secret Stability:** Because Bitnami's Helm chart randomly generates `mongodb-root-password` and `mongodb-replica-set-key` when rendered with `helm template`, [`argocd/apps/mongodb.yaml`](../argocd/apps/mongodb.yaml) configures `ignoreDifferences` on `Secret/mongodb` (`/data`) along with `RespectIgnoreDifferences=true` and `ApplyOutOfSyncOnly=true`. This creates the `Secret` automatically on initial deployment and preserves it across all future syncs without storing credentials in Git.

---

## Resource Requests & Limits Sizing Rationale

Each of the 3 `e2-standard-2` nodes provides **2 vCPUs (`2000m`)** and **8 GiB RAM**. After accounting for RKE2 control-plane static pods (`etcd`, `kube-apiserver`, `kube-controller-manager`), Cilium, `cert-manager`, Argo CD, and `cloudflared`, the busiest node (`rke2-node-3`) has **`~465m` unrequested CPU** and **`~5.0 GiB` unrequested RAM** available.

| Container | CPU Request | CPU Limit | Memory Request | Memory Limit |
| :--- | :--- | :--- | :--- | :--- |
| **`mongodb`** (`resources`) | **`250m`** | **`1000m`** | **`1Gi`** | **`2Gi`** |
| **`metrics`** sidecar (`metrics.resources`) | **`50m`** | **`200m`** | **`64Mi`** | **`128Mi`** |
| **Total per Pod (1 per Node)** | **`300m`** | **`1200m`** | **`1088Mi`** | **`2176Mi`** |

1. **Guaranteed Scheduling Across All 3 Nodes (`300m` total CPU request):**
   Requesting `250m` (`mongodb`) + `50m` (`metrics`) = **`300m` CPU per pod** fits comfortably inside the `465m` unrequested CPU budget on `rke2-node-3`, ensuring all 3 replicas schedule immediately alongside `podAntiAffinityPreset: hard`.
2. **Burst Headroom (`1000m` CPU limit):**
   Control-plane static pods reserve CPU requests for safety but idle below 15% actual CPU utilization. A `1000m` (1 full vCPU) limit allows MongoDB to burst during replica set elections, initial syncs, and heavy queries without throttling.
3. **WiredTiger Cache Sizing (`1Gi` Request / `2Gi` Limit):**
   MongoDB's WiredTiger engine sizes its internal cache to `max(50% of (RAM Limit - 1 GB), 256 MB)`. With a **`2Gi` memory limit**, WiredTiger allocates **`512 MB`** to its cache and leaves **`1.5 GiB`** inside the container for connections, aggregation buffers, and `emptyDir` data—preventing `OOMKilled` events while keeping over **`2.8 GiB`** of free RAM on every node.
4. **Prometheus Exporter Sidecar (`50m`/`64Mi` Request, `200m`/`128Mi` Limit):**
   `mongodb-exporter` is a lightweight stateless Go process that translates MongoDB's `serverStatus` metrics when scraped on port `9216`.

---

## Step 1: GitOps Deployment via Argo CD

Because the Root App-of-Apps ([`argocd/bootstrap/root-app.yaml`](../argocd/bootstrap/root-app.yaml)) watches `argocd/apps/`, merging [`argocd/apps/mongodb.yaml`](../argocd/apps/mongodb.yaml) to `main` automatically deploys the `mongodb` Application.

Verify the rollout and check that one replica is running on each of the 3 nodes:

```bash
kubectl get pods -n mongodb -o wide
```

Expected output (3 pods, each with `2/2` containers ready — `mongodb` + `metrics` — across `rke2-node-1`, `rke2-node-2`, and `rke2-node-3`):

```text
NAME        READY   STATUS    RESTARTS   AGE   IP            NODE          NOMINATED NODE   READINESS GATES
mongodb-0   2/2     Running   0          2m    10.42.0.xxx   rke2-node-1   <none>           <none>
mongodb-1   2/2     Running   0          2m    10.42.1.xxx   rke2-node-2   <none>           <none>
mongodb-2   2/2     Running   0          2m    10.42.2.xxx   rke2-node-3   <none>           <none>
```

---

## Step 2: Retrieve the Generated MongoDB Credentials

Retrieve the `root` password generated in `Secret/mongodb`:

```bash
export MONGODB_ROOT_PASSWORD=$(kubectl get secret --namespace mongodb mongodb -o jsonpath="{.data.mongodb-root-password}" | base64 -d)
echo "Root Password: $MONGODB_ROOT_PASSWORD"
```

---

## Step 3: Expose MongoDB (`27017/TCP`) Externally via Cloudflare Tunnel

Because the `cloudflared` connector already runs inside the cluster (`cloudflare` namespace), it can route TCP traffic directly to the headless MongoDB service without opening GCP firewall ports or paying for external load balancers.

1. **Declarative Tunnel Route (`tofu/cloudflare/routes.yaml`):**
   The `mongodb` TCP route and its proxied DNS CNAME record (`mongodb.<your-domain>`) are managed declaratively in [`tofu/cloudflare/routes.yaml`](../tofu/cloudflare/routes.yaml) and applied via [`.github/workflows/tofu-apply.yml`](../.github/workflows/tofu-apply.yml):
   * **Subdomain:** `mongodb`
   * **Service:** `tcp://mongodb-0.mongodb-headless.mongodb.svc.cluster.local:27017`

2. **Connect from Your Workstation Using Docker (No Local Install Needed):**
   Open a terminal and run `cloudflared access tcp` inside Docker to bridge `localhost:27017` to the Cloudflare Tunnel:

```bash
docker run --rm -it \
  -p 127.0.0.1:27017:27017 \
  cloudflare/cloudflared:latest \
  access tcp --hostname mongodb.<your-domain> --url 0.0.0.0:27017
```

3. **Connect with `mongosh` (via Docker) or MongoDB Compass:**
   In a second terminal, connect to `127.0.0.1:27017` with `?directConnection=true`:

```bash
docker run --rm -it --network host mongo:9.0 \
  mongosh "mongodb://root:${MONGODB_ROOT_PASSWORD}@127.0.0.1:27017/admin?directConnection=true" \
  --eval "rs.status().members.map(m => ({name: m.name, stateStr: m.stateStr, health: m.health}))"
```

---

## Step 4: Externalize Prometheus Metrics (`9216/TCP`) via Cloudflare Tunnel

The Bitnami chart creates a `ClusterIP` service **`mongodb-metrics.mongodb.svc.cluster.local:9216`** exposing Prometheus metrics at `/metrics`.

1. **Declarative Tunnel Route (`tofu/cloudflare/routes.yaml`):**
   The `mongo-metrics` HTTP route and its proxied DNS CNAME record (`mongo-metrics.<your-domain>`) are managed declaratively in [`tofu/cloudflare/routes.yaml`](../tofu/cloudflare/routes.yaml) and applied via [`.github/workflows/tofu-apply.yml`](../.github/workflows/tofu-apply.yml):
   * **Subdomain:** `mongo-metrics`
   * **Service:** `http://mongodb-metrics.mongodb.svc.cluster.local:9216`
   * *(Recommended for production)* Under **Access → Applications**, add a Zero Trust Access policy (e.g., Google OIDC or a Service Token) for `mongo-metrics.<your-domain>` so only authorized scrapers or users can view metrics.

2. **Verify the Externalized Metrics Endpoint:**

```bash
curl -s https://mongo-metrics.<your-domain>/metrics | grep -E "^mongodb_up|^mongodb_ss_connections"
```

---

[← Back to Main README](../README.md) | [← Previous: Argo CD, Cloudflare Tunnel & Google OIDC](04-argocd-cloudflare-oidc.md) | [Next: Operations & Cost Management →](06-operations-and-cleanup.md)
