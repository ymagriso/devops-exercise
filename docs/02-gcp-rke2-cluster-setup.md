[← Back to Main README](../README.md) | [← Previous: Architecture & Costs](01-architecture-and-costs.md) | [Next: cert-manager & Let's Encrypt →](03-cert-manager-letsencrypt.md)

---

# 2. GCP Infrastructure & RKE2 HA Cluster Setup

- [Prerequisites](#prerequisites)
- [1. Authenticate and Configure GCP](#1-authenticate-and-configure-gcp)
- [2. Provision the Infrastructure](#2-provision-the-infrastructure)
- [3. Enable Secure Access (IAP) and Outbound Internet (Cloud NAT)](#3-enable-secure-access-iap-and-outbound-internet-cloud-nat)
  - [Step 3a: Allow Inbound SSH and Kubernetes API from IAP](#step-3a-allow-inbound-ssh-and-kubernetes-api-from-iap)
  - [Step 3b: Enable Outbound Internet via Cloud NAT](#step-3b-enable-outbound-internet-via-cloud-nat)
- [4. Install RKE2 with Cilium (HA Control Plane)](#4-install-rke2-with-cilium-ha-control-plane)
  - [Step 4a: Initialize the First Node](#step-4a-initialize-the-first-node)
  - [Step 4b: Join Nodes 2 and 3](#step-4b-join-nodes-2-and-3)
- [5. Configure Local Kubectl Access](#5-configure-local-kubectl-access)

---

## Prerequisites

* An active Google Cloud account (with the $300 free trial active).
* A dedicated GCP Project (e.g., `sandbox-lab`).
* [Google Cloud CLI (`gcloud`)](https://cloud.google.com/sdk/docs/install) installed locally.
* `kubectl` and [`helm`](https://helm.sh/docs/intro/install/) installed locally.
* A domain managed in **Cloudflare** (used for ACME DNS-01 TLS certificate validation and Cloudflare Tunnel).

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

## 3. Enable Secure Access (IAP) and Outbound Internet (Cloud NAT)

Because the VMs are provisioned without external IP addresses (`--network-interface=no-address`), you need two networking rules:
1. An **IAP firewall rule** for **inbound** SSH (`tcp:22`) and Kubernetes API (`tcp:6443`) access through the IAP tunnel.
2. A **Cloud NAT** gateway for **outbound** internet access (required to download the RKE2 installer from `get.rke2.io`, release artifacts from GitHub, and Cilium/CoreDNS container images).

### Step 3a: Allow Inbound SSH and Kubernetes API from IAP

Create a firewall rule to allow SSH (`tcp:22`) and Kubernetes API (`tcp:6443`) traffic from Google's Identity-Aware Proxy (IAP) IP range:

```bash
gcloud compute firewall-rules create allow-ssh-from-iap \
    --direction=INGRESS \
    --action=allow \
    --rules=tcp:22,tcp:6443 \
    --source-ranges=35.235.240.0/20
```

### Step 3b: Enable Outbound Internet via Cloud NAT

Create a Cloud Router and attach a Cloud NAT gateway in `me-west1`:

```bash
# Create a Cloud Router in me-west1
gcloud compute routers create rke2-nat-router \
    --network=default \
    --region=me-west1

# Attach a Cloud NAT gateway to allow outbound internet traffic for private VMs
gcloud compute routers nats create rke2-nat-config \
    --router=rke2-nat-router \
    --region=me-west1 \
    --auto-allocate-nat-external-ips \
    --nat-all-subnet-ip-ranges
```

## 4. Install RKE2 with Cilium (HA Control Plane)

### Step 4a: Initialize the First Node

SSH into `rke2-node-1` using IAP:

```bash
gcloud compute ssh rke2-node-1 --tunnel-through-iap --zone=me-west1-a
```

Configure RKE2 to use Cilium as the CNI and set the short hostname as `node-name` before installing (GCP's default internal FQDN `<vm>.<zone>.c.<project-id>.internal` can exceed Kubernetes's 63-byte label limit):

```bash
sudo mkdir -p /etc/rancher/rke2
sudo tee /etc/rancher/rke2/config.yaml <<EOF
node-name: $(hostname -s)
cni: cilium
EOF
```

Install and start RKE2:

```bash
curl -sfL https://get.rke2.io | sudo sh -
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

Create the RKE2 configuration file to point to the first node, set the short `node-name`, and configure the CNI (replace `<INTERNAL_IP_OF_NODE_1>` and `<TOKEN>`):

```bash
sudo mkdir -p /etc/rancher/rke2
sudo tee /etc/rancher/rke2/config.yaml <<EOF
node-name: $(hostname -s)
server: https://<INTERNAL_IP_OF_NODE_1>:9345
token: <TOKEN>
cni: cilium
EOF
```

Install and start the RKE2 server component:

```bash
curl -sfL https://get.rke2.io | sudo sh -
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

You should see all 3 nodes listed with the `control-plane,etcd` roles.

---

[← Back to Main README](../README.md) | [← Previous: Architecture & Costs](01-architecture-and-costs.md) | [Next: cert-manager & Let's Encrypt →](03-cert-manager-letsencrypt.md)
