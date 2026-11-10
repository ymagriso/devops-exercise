# High Availability RKE2 Cluster on Google Cloud (Free Trial Setup)

This repository contains the instructions for deploying a highly available, 3-node RKE2 (Kubernetes) cluster on Google Cloud Platform (GCP).

The infrastructure is optimized to run within the boundaries of the $300 GCP Free Trial by utilizing Identity-Aware Proxy (IAP) instead of public external IPs, and deploying all 3 nodes symmetrically as both control plane and worker nodes. It also configures **Cilium** as the CNI for high performance and low latency, which is ideal for stateful workloads like MongoDB.

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

Create three `e2-standard-2` instances running Ubuntu 24.04.
*To save costs (approx $11/month), these VMs are provisioned **without** external IP addresses.*

```bash
gcloud compute instances bulk create \
    --name-pattern="rke2-node-#" \
    --count=3 \
    --zone=us-central1-a \
    --machine-type=e2-standard-2 \
    --network-interface=no-address \
    --create-disk=image-family=ubuntu-2404-lts,image-project=ubuntu-os-cloud,size=50GB,type=pd-standard
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
gcloud compute ssh rke2-node-1 --tunnel-through-iap --zone=us-central1-a
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
gcloud compute ssh rke2-node-2 --tunnel-through-iap --zone=us-central1-a
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
gcloud compute ssh rke2-node-1 --tunnel-through-iap --zone=us-central1-a \
    --command="sudo cp /etc/rancher/rke2/rke2.yaml ~/.kubeconfig && sudo chown \$(whoami) ~/.kubeconfig"

# Download file to local machine
gcloud compute scp rke2-node-1:~/.kubeconfig ./rke2-kubeconfig.yaml \
    --tunnel-through-iap --zone=us-central1-a
```

**2. Open the IAP Port Forwarding Tunnel:**
*Run this in a dedicated terminal window and leave it open.*

```bash
gcloud compute start-iap-tunnel rke2-node-1 6443 \
    --local-host-port=localhost:6443 \
    --zone=us-central1-a
```

**3. Test the connection:**
Open a new terminal window on your local machine and point `kubectl` to the downloaded file.

```bash
export KUBECONFIG=$(pwd)/rke2-kubeconfig.yaml
kubectl get nodes
```

You should see all 3 nodes listed with the `control-plane,etcd,master` roles.

## Cost Management Tip

To stretch your $300 free trial, shut down the instances when you are not actively using the cluster:

```bash
gcloud compute instances stop rke2-node-1 rke2-node-2 rke2-node-3 --zone=us-central1-a
```

*Note: You will still incur a small persistent disk storage fee (~$6.00/month total) while the VMs are stopped.*