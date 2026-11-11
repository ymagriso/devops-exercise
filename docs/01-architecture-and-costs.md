[← Back to Main README](../README.md) | [Next: GCP & RKE2 Cluster Setup →](02-gcp-rke2-cluster-setup.md)

---

# 1. Architecture Rationale & Regional Cost Comparison

- [Why RKE2?](#why-rke2)
- [Why Cilium CNI?](#why-cilium-cni)
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
