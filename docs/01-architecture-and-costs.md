[← Back to Main README](../README.md) | [Next: GCP & RKE2 Cluster Setup →](02-gcp-rke2-cluster-setup.md)

---

# 1. Architecture Rationale & Regional Cost Comparison

- [Why RKE2?](#why-rke2)
- [Why Cilium CNI?](#why-cilium-cni)
- [Namespace Strategy: Single Namespace vs. Multiple Namespaces](#namespace-strategy-single-namespace-vs-multiple-namespaces)
  - [Core Trade-Offs at a Glance](#core-trade-offs-at-a-glance)
  - [Single Namespace: Pros & Cons](#single-namespace-pros--cons)
  - [Multiple Namespaces: Pros & Cons](#multiple-namespaces-pros--cons)
  - [Architectural Contexts & Recommendations](#architectural-contexts--recommendations)
- [Regional Cost & Latency Comparison](#regional-cost--latency-comparison)
  - ["Always Free" Tier vs. $300 Free Trial Credits](#always-free-tier-vs-300-free-trial-credits)
  - [Cost Breakdown Across Regions (Full 3-Node Cluster)](#cost-breakdown-across-regions-full-3-node-cluster)
  - [Practical Impact & Choosing a Closer Region](#practical-impact--choosing-a-closer-region)

---

## Why RKE2?

Before starting, it is helpful to understand why RKE2 was selected over Rancher's other distributions (RKE and K3s).

| Feature | RKE (RKE1) | K3s | RKE2 (RKE Government) |
|---|---|---|---|
| **Focus** | Legacy Enterprise / Docker-based | Lightweight Edge / IoT / Dev | Secure, Compliant Enterprise / Cloud |
| **Architecture** | Docker containers | Single binary (lightweight) | Single binary (combines K3s usability with upstream alignment) |
| **Control Plane** | Runs in Docker containers | Bundled, runs as a single process | Runs as static pods (highly observable) |
| **Datastore** | etcd | SQLite (default), etcd, MySQL, Postgres | etcd (default) |
| **Container Runtime** | Docker | containerd | containerd |
| **Security/Compliance** | Standard | Standard | CIS Benchmark v1.7/v1.8 out-of-the-box, FIPS 140-2, Trivy scanned |
| **Resource Overhead** | High | Very Low | Moderate (scales with workload) |
| **Best For** | Existing RKE1 deployments | Resource-constrained edge, Raspberry Pi, single-node | Production clusters, government compliance, HA with etcd |

> **Why RKE2 is the correct choice here:** RKE2 provides the modern, single-binary ease-of-use of K3s but defaults to a robust, highly-available `etcd` backend required for production clusters. Unlike K3s, which is optimized for resource-constrained edge devices (like Raspberry Pis), RKE2 aligns closely with upstream Kubernetes, making it the superior choice for deploying resilient, stateful workloads like MongoDB on enterprise-grade VMs in GCP.

## Why Cilium CNI?

RKE2 natively bundles several Container Network Interfaces (CNIs). For this specific architecture—running stateful MongoDB replica sets on memory-constrained (8GB RAM) VMs—**Cilium** was selected for its distinct performance advantages.

| CNI | Data Plane | Performance | Memory Impact | Verdict |
| ----- | ----- | ----- | ----- | ----- |
| **Cilium** | eBPF | High (Low Latency) | Low | **Selected.** Bypasses traditional `iptables` overhead, significantly reducing network latency for database replication while freeing up RAM for your application. |
| **Calico** | BGP (iptables) | Very Good | Moderate | Strong alternative with excellent security, but its native eBPF mode requires extra configuration outside of the RKE2 defaults. |
| **Canal** | VXLAN (iptables) | Moderate | Low | RKE2 Default. The VXLAN encapsulation/de-encapsulation adds network overhead that is not ideal for heavy database workloads. |

## Namespace Strategy: Single Namespace vs. Multiple Namespaces

Kubernetes namespaces provide a logical boundary for organizing cluster resources, enforcing security policies, scoping secrets, and dividing compute quotas. Choosing when to group resources into a **single namespace** versus splitting them across **multiple namespaces** is a key architectural decision.

### Core Trade-Offs at a Glance

| Dimension | Single Namespace | Multiple Namespaces |
| :--- | :--- | :--- |
| **Service Discovery (DNS)** | Short service names work out-of-the-box (`http://backend:8080`) | Requires cross-namespace FQDNs (`http://backend.<namespace>.svc.cluster.local:8080`) |
| **Secret & ConfigMap Scope** | All workloads in the namespace can potentially mount shared `Secret` and `ConfigMap` objects | Secrets are strictly scoped per namespace; reduces credential exposure and blast radius |
| **RBAC & Access Control** | Coarse-grained (`RoleBinding` grants access to everything in the shared namespace) | Fine-grained (`Role` / `RoleBinding` per team, component, or environment) |
| **Network Isolation (Cilium)** | Requires pod-label selectors for every `NetworkPolicy` / `CiliumNetworkPolicy` | Enables simple default-deny boundaries at the namespace level (`io.kubernetes.pod.namespace`) |
| **Resource Quotas & Limits** | One shared `ResourceQuota` / `LimitRange` pool; noisy neighbors can starve co-located services | Dedicated `ResourceQuota` and `LimitRange` per namespace prevent resource starvation |
| **GitOps & Lifecycle (Argo CD)** | Simple single-target deployment, but pruning or deleting the namespace wipes all components | Independent sync, prune, and deletion boundaries per component or environment |
| **Resource Duplication** | Minimal — shared pull secrets, TLS certificates, and config maps exist only once | Shared secrets (e.g., wildcard TLS certs or registry pull secrets) must be replicated or synced |

### Single Namespace: Pros & Cons

**Pros:**
* **Simpler Service-to-Service Communication:** Pods within the same namespace can reach each other by short service name (e.g., `mongodb:27017`), simplifying application configuration.
* **Direct Secret & ConfigMap Sharing:** Shared `Secret` objects (such as TLS certificates, OAuth credentials, or image pull secrets) and `ConfigMap` objects can be mounted directly by any pod without needing cross-namespace synchronization tools (like `reflector` or `external-secrets`).
* **Lower Operational Overhead:** Fewer manifests to maintain, fewer `RoleBinding` and `NetworkPolicy` rules to debug, and a single target namespace in `kubectl` commands (`kubectl get all -n app`).

**Cons:**
* **Larger Security Blast Radius:** If a compromised pod or overly permissive `ServiceAccount` has secret-read permissions in that namespace, it can access secrets belonging to every other workload in the same namespace.
* **Naming Collisions:** Resource names (`Service`, `Deployment`, `ConfigMap`, `Secret`) must be unique within a namespace, requiring prefixes when multiple components or environments share one namespace.
* **Noisy Neighbor Risk:** Without namespace-level `ResourceQuota` boundaries, a memory leak or CPU spike in one workload can exhaust quota meant for critical databases or platform services.
* **Accidental Deletion / Prune Risk:** Deleting the namespace or misconfiguring an Argo CD application prune policy can inadvertently tear down unrelated workloads sharing that namespace.

### Multiple Namespaces: Pros & Cons

**Pros:**
* **Strong Security & Secret Isolation:** Kubernetes `Secret` objects cannot be mounted across namespaces. Sensitive credentials—such as `cloudflare-api-token` in `cert-manager`, `argocd-google-oidc` in `argocd`, and `tunnel-credentials` in `cloudflare`—are completely invisible to application workloads.
* **Zero-Trust Network Segmentation with Cilium:** With Cilium as the CNI, you can apply default-deny ingress/egress policies per namespace and explicitly allow only required cross-namespace paths (for example, allowing `cloudflare` (`cloudflared`) to reach `argocd-server.argocd.svc.cluster.local:443` and nothing else).
* **Blast-Radius & Lifecycle Containment:** Upgrading, rolling back, or deleting one component's namespace (`kubectl delete ns cloudflare`) cannot accidentally delete resources in `argocd` or `cert-manager`.
* **Granular RBAC & Multi-Tenancy:** In Argo CD and Kubernetes RBAC, you can grant developers full access to an application namespace while keeping infrastructure namespaces (`kube-system`, `cert-manager`, `argocd`) read-only or restricted to platform admins.
* **Dedicated Resource Governance:** On memory-constrained nodes (such as 3 × 8 GB RAM VMs), per-namespace `ResourceQuota` and `LimitRange` policies ensure development workloads cannot starve stateful databases or control-plane components.

**Cons:**
* **Cross-Namespace Secret Management:** Because `Secret` and `ConfigMap` objects cannot be referenced across namespaces by regular pods, shared assets (like a wildcard TLS certificate or private container registry credentials) must either be issued per namespace (via a `ClusterIssuer`) or replicated across namespaces.
* **Explicit FQDN Addressing:** Services calling across namespaces must use `<service>.<namespace>.svc.cluster.local` (e.g., `https://argocd-server.argocd.svc.cluster.local:443`).
* **More Policy Boilerplate:** Each namespace requires its own `Namespace` manifest, `ResourceQuota`, `LimitRange`, `RoleBinding`, and `NetworkPolicy` definitions.

### Architectural Contexts & Recommendations

#### 1. Platform & Infrastructure Isolation (Used in This Repository)
In this repository, each platform component runs in its own dedicated namespace:
* **`kube-system`** — RKE2 core components and Cilium CNI
* **`cert-manager`** — TLS certificate controller (`cloudflare-api-token` secret stays isolated here)
* **`argocd`** — GitOps control plane (`argocd-google-oidc` and `argocd-server-tls` stay isolated here)
* **`cloudflare`** — Edge connector (`cloudflared` pods and `tunnel-credentials` secret stay isolated here)

> **Why this is recommended:** Platform tools hold high-privilege credentials (DNS API tokens, OIDC client secrets, tunnel tokens). Isolating each into its own namespace ensures that even if `cloudflared` (which handles external edge traffic) were compromised, it cannot read `cert-manager`'s Cloudflare DNS API token or Argo CD's OIDC secrets. Furthermore, using a `ClusterIssuer` (`letsencrypt-prod`) allows `cert-manager` to issue `Certificate` secrets into any target namespace without sharing its own namespace.

#### 2. Application Microservices & Stateful Databases (e.g., App Tier + MongoDB)
When deploying an application stack consisting of stateless APIs/workers and a stateful MongoDB replica set:
* **Single Application Namespace (`my-app`) — Recommended for tightly coupled stacks:** If a MongoDB replica set is dedicated exclusively to one application and managed by the same team, placing the backend API and its dedicated MongoDB stateful set in the **same namespace** simplifies service discovery (`mongodb-0.mongodb-headless:27017`), shares database connection secrets cleanly, and keeps the entire application stack within one Argo CD `Application`.
* **Separate Database Namespace (`my-app` + `mongodb-prod`) — Recommended for shared data services or strict DBA boundaries:** If multiple applications share the database cluster, or if you want to prevent application developers from accidentally deleting `PersistentVolumeClaim` objects or database `StatefulSet` pods during a deployment reset, isolating the stateful database in its own `database` namespace with strict Cilium network policies (allowing ingress only on port `27017` from the `my-app` namespace) provides superior protection against accidental data loss.

#### 3. Multi-Environment Separation (`dev` / `staging` / `prod`)
When running multiple environments on a single 3-node cluster to stay within the $300 GCP Free Trial budget:
* **Separate Namespaces per Environment (`app-dev`, `app-staging`, `app-prod`) — Strongly Recommended:** Never mix `dev`, `staging`, and `prod` workloads in a single namespace. Using one namespace per environment lets you:
  1. Reuse identical Kubernetes resource names (`Deployment/api`, `Service/api`) across environments without naming collisions.
  2. Apply strict `ResourceQuota` limits to `app-dev` and `app-staging` so non-production tests cannot exhaust the 24 GB total cluster RAM and impact `app-prod`.
  3. Block cross-environment traffic using Cilium `NetworkPolicy` so a `dev` pod can never accidentally connect to a `prod` MongoDB instance.
  4. Manage each environment as a separate Argo CD `Application` (e.g., auto-syncing `app-dev` on commit while requiring manual sync or promotion for `app-prod`).

## Regional Cost & Latency Comparison

The setup steps use **`me-west1` (`me-west1-a`, Tel Aviv, Israel)** as the recommended region for low IAP tunnel latency with only a minor cost difference (~10% compared to US regions). You can replace the `--zone` flag with any region closer to your location. Below is how GCP billing works with the Free Trial and how regional pricing affects your $300 credit.

### "Always Free" Tier vs. $300 Free Trial Credits

* **GCP "Always Free" Tier (US-only):** Only covers **1 × `e2-micro`** VM and **30 GB of `pd-standard` disk** in `us-central1`, `us-west1`, or `us-east1`.
* **$300 Free Trial Credits (Global):** Can be spent in **any GCP region**.

Because this architecture provisions **3 × `e2-standard-2`** VMs (2 vCPUs, 8 GB RAM each) and **150 GB total disk** (3 × 50 GB `pd-standard`), it draws from your **$300 Free Trial credits** rather than the Always Free tier. Deploying outside the US only forfeits the 30 GB Always Free disk allowance (worth **~$1.20/month**).

### Cost Breakdown Across Regions (Full 3-Node Cluster)

Estimated costs for **3 × `e2-standard-2` VMs + 150 GB `pd-standard` disk** (with `--network-interface=no-address`, so $0 for external IPs):

| Region | Location | 3 VMs Hourly | 3 VMs (24/7 Month) | 150 GB Disk / Month (even when stopped) | Total 24/7 Monthly | Total Runtime on $300 Credit |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`me-west1`** *(recommended)* | Tel Aviv, Israel | ~$0.221 / hr | ~$161.43 | ~$6.75 | **~$168.18 / mo** | ~1,310 hours (~54 days 24/7) |
| **`us-central1`** | Iowa, USA | ~$0.201 / hr | ~$146.76 | ~$4.80 *(120 GB billed)* | **~$151.56 / mo** | ~1,450 hours (~60 days 24/7) |
| **`europe-west1` / `west4`** | Belgium / Netherlands | ~$0.221 / hr | ~$161.43 | ~$6.00 | **~$167.43 / mo** | ~1,315 hours (~55 days 24/7) |
| **`europe-west3`** | Frankfurt, Germany | ~$0.259 / hr | ~$189.06 | ~$7.20 | **~$196.26 / mo** | ~1,115 hours (~46 days 24/7) |

### Practical Impact & Choosing a Closer Region

1. **Minimal Cost Difference (~10%):**
   * Choosing `me-west1` (Tel Aviv) or `europe-west1` (Belgium) over `us-central1` costs **~$0.02/hour more** for the entire 3-node cluster (~$0.16 extra for an 8-hour work session).
   * When the VMs are **stopped**, you only pay for the 150 GB persistent disks (~$6.00–$6.75/month vs. ~$4.80/month in `us-central1`).
2. **Much Lower IAP Tunnel Latency:**
   * Because all `ssh` and `kubectl` commands are routed through an **Identity-Aware Proxy (IAP) TCP tunnel**, deploying in a nearby region (`me-west1`) cuts round-trip latency from ~150–180 ms down to ~5–50 ms, making interactive SSH and `kubectl` noticeably more responsive.
3. **Free Trial Quota Check:**
   * Free trial accounts typically have an **8 vCPU per-region quota** by default. Since 3 × `e2-standard-2` uses **6 vCPUs**, the cluster fits within the default regional quota in whichever region you choose.

---

[← Back to Main README](../README.md) | [Next: GCP & RKE2 Cluster Setup →](02-gcp-rke2-cluster-setup.md)
