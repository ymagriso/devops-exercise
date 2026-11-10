# High Availability RKE2 Cluster on Google Cloud (Free Trial Setup)

This repository contains the instructions for deploying a highly available, 3-node RKE2 (Kubernetes) cluster on Google Cloud Platform (GCP).

The infrastructure is optimized to run within the boundaries of the $300 GCP Free Trial by utilizing Identity-Aware Proxy (IAP) instead of public external IPs, and deploying all 3 nodes symmetrically as both control plane and worker nodes. It also configures **Cilium** as the CNI for high performance and low latency, which is ideal for stateful workloads like MongoDB.

## Table of Contents

- [Why RKE2?](#why-rke2)
- [Why Cilium CNI?](#why-cilium-cni)
- [Regional Cost & Latency Comparison](#regional-cost--latency-comparison)
  - ["Always Free" Tier vs. $300 Free Trial Credits](#always-free-tier-vs-300-free-trial-credits)
  - [Cost Breakdown Across Regions (Full 3-Node Cluster)](#cost-breakdown-across-regions-full-3-node-cluster)
  - [Practical Impact & Choosing a Closer Region](#practical-impact--choosing-a-closer-region)
- [Prerequisites](#prerequisites)
- [1. Authenticate and Configure GCP](#1-authenticate-and-configure-gcp)
- [2. Provision the Infrastructure](#2-provision-the-infrastructure)
- [3. Enable Secure Access (IAP)](#3-enable-secure-access-iap)
- [4. Install RKE2 with Cilium (HA Control Plane)](#4-install-rke2-with-cilium-ha-control-plane)
  - [Step 4a: Initialize the First Node](#step-4a-initialize-the-first-node)
  - [Step 4b: Join Nodes 2 and 3](#step-4b-join-nodes-2-and-3)
- [5. Configure Local Kubectl Access](#5-configure-local-kubectl-access)
- [Cost Management Tip: Stopping and Starting the Cluster](#cost-management-tip-stopping-and-starting-the-cluster)
  - [Stop the Instances](#stop-the-instances)
  - [Start the Instances](#start-the-instances)
  - [Check Instance Status](#check-instance-status)
  - [Delete the Cluster (Full Cleanup)](#delete-the-cluster-full-cleanup)

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

The steps below use **`me-west1` (`me-west1-a`, Tel Aviv, Israel)** as the recommended region for low IAP tunnel latency with only a minor cost difference (~10% compared to US regions). You can replace the `--zone` flag with any region closer to your location. Below is how GCP billing works with the Free Trial and how regional pricing affects your $300 credit.

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

## Prerequisites

* An active Google Cloud account (with the $300 free trial active).
* A dedicated GCP Project (e.g., `sandbox-lab`).
* [Google Cloud CLI (`gcloud`)](https://cloud.google.com/sdk/docs/install) installed locally.
* `kubectl` installed locally.

## 1. Authenticate and Configure GCP

First, log in to your Google account and set your active project.

```bash
# Authenticate the gcloud CLI
gcloud auth login

# Set your target GCP Project ID
gcloud config set project YOUR_PROJECT_ID
```

## 2. Provision the Infrastructure

Create three `e2-standard-2` instances running Ubuntu 24.04 in `me-west1-a`.
*To save costs (approx $11/month), these VMs are provisioned **without** external IP addresses.*

```bash
gcloud compute instances bulk create \
    --name-pattern="rke2-node-#" \
    --count=3 \
    --zone=me-west1-a \
    --machine-type=e2-standard-2 \
    --network-interface=no-address \
    --create-disk=boot=yes,image-family=ubuntu-2404-lts-amd64,image-project=ubuntu-os-cloud,size=50GB,type=pd-standard
```

## 3. Enable Secure Access (IAP)

Since the VMs do not have external IPs, create a firewall rule to allow SSH traffic from Google's Identity-Aware Proxy (IAP) IP range.

```bash
gcloud compute firewall-rules create allow-ssh-from-iap \
    --direction=INGRESS \
    --action=allow \
    --rules=tcp:22 \
    --source-ranges=35.235.240.0/20
```

## 4. Install RKE2 with Cilium (HA Control Plane)

### Step 4a: Initialize the First Node

SSH into `rke2-node-1` using IAP:

```bash
gcloud compute ssh rke2-node-1 --tunnel-through-iap --zone=me-west1-a
```

Configure RKE2 to use Cilium as the CNI before installing:

```bash
sudo mkdir -p /etc/rancher/rke2
echo -e "cni: cilium" | sudo tee /etc/rancher/rke2/config.yaml
```

Install and start RKE2:

```bash
curl -sfL https://get.rke2.io | sh -
sudo systemctl enable --now rke2-server.service
```

Retrieve the node joining token (save this for the next step):

```bash
sudo cat /var/lib/rancher/rke2/server/node-token
```

Type `exit` to return to your local machine.

### Step 4b: Join Nodes 2 and 3

Repeat the following process for **both** `rke2-node-2` and `rke2-node-3`.

SSH into the node:

```bash
gcloud compute ssh rke2-node-2 --tunnel-through-iap --zone=me-west1-a
```

Create the RKE2 configuration file to point to the first node and set the CNI (replace `<INTERNAL_IP_OF_NODE_1>` and `<TOKEN>`):

```bash
sudo mkdir -p /etc/rancher/rke2
sudo nano /etc/rancher/rke2/config.yaml
```

Paste the following into `config.yaml`:

```yaml
server: https://<INTERNAL_IP_OF_NODE_1>:9345
token: <TOKEN>
cni: cilium
```

Install and start the RKE2 server component:

```bash
curl -sfL https://get.rke2.io | sh -
sudo systemctl enable --now rke2-server.service
```

## 5. Configure Local Kubectl Access

Because the cluster is private, route your local `kubectl` traffic through an IAP tunnel.

**1. Copy the kubeconfig file to your local machine:**

```bash
# Securely copy file from root to user on VM
gcloud compute ssh rke2-node-1 --tunnel-through-iap --zone=me-west1-a \
    --command="sudo cp /etc/rancher/rke2/rke2.yaml ~/.kubeconfig && sudo chown \$(whoami) ~/.kubeconfig"

# Download file to local machine
gcloud compute scp rke2-node-1:~/.kubeconfig ./rke2-kubeconfig.yaml \
    --tunnel-through-iap --zone=me-west1-a
```

**2. Open the IAP Port Forwarding Tunnel:**
*Run this in a dedicated terminal window and leave it open.*

```bash
gcloud compute start-iap-tunnel rke2-node-1 6443 \
    --local-host-port=localhost:6443 \
    --zone=me-west1-a
```

**3. Test the connection:**
Open a new terminal window on your local machine and point `kubectl` to the downloaded file.

```bash
export KUBECONFIG=$(pwd)/rke2-kubeconfig.yaml
kubectl get nodes
```

You should see all 3 nodes listed with the `control-plane,etcd,master` roles.

## Cost Management Tip: Stopping and Starting the Cluster

To stretch your $300 free trial, shut down the instances when you are not actively using the cluster and start them back up when needed.

### Stop the Instances

```bash
gcloud compute instances stop rke2-node-1 rke2-node-2 rke2-node-3 --zone=me-west1-a
```

*Note: You will still incur a small persistent disk storage fee (~$6.75/month total in `me-west1`) while the VMs are stopped.*

### Start the Instances

Because `rke2-server.service` was enabled with `systemctl enable` and GCP preserves each VM's internal IP address across stops/starts, starting the instances automatically brings the RKE2 cluster back online:

```bash
gcloud compute instances start rke2-node-1 rke2-node-2 rke2-node-3 --zone=me-west1-a
```

Once the VMs are running, re-open the IAP port-forwarding tunnel from [Step 5](#5-configure-local-kubectl-access) to resume using `kubectl`.

### Check Instance Status

Verify whether the nodes are `RUNNING` or `TERMINATED`:

```bash
gcloud compute instances list --filter="name~'^rke2-node-'"
```

### Delete the Cluster (Full Cleanup)

To permanently remove the VMs and their attached persistent disks (which are configured with `autoDelete: true` by default) so no storage charges remain:

```bash
gcloud compute instances delete rke2-node-1 rke2-node-2 rke2-node-3 --zone=me-west1-a
```

Verify that all disks have been removed:

```bash
gcloud compute disks list
```