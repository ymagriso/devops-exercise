[← Back to Main README](../README.md) | [← Previous: Architecture & Costs](01-architecture-and-costs.md) | [Next: cert-manager & Let's Encrypt →](03-cert-manager-letsencrypt.md)

---

# 2. GCP Infrastructure & RKE2 HA Cluster Setup

- [Prerequisites](#prerequisites)
- [Method A: Automated Provisioning with OpenTofu & CI/CD (Recommended)](#method-a-automated-provisioning-with-opentofu--cicd-recommended)
  - [1. One-Time GCP Workload Identity Federation (WIF) Setup](#1-one-time-gcp-workload-identity-federation-wif-setup)
  - [2. Configure GitHub Actions Secrets](#2-configure-github-actions-secrets)
  - [3. Deploy the Cluster via GitHub Actions](#3-deploy-the-cluster-via-github-actions)
  - [4. Alternative: Deploy Locally with OpenTofu CLI](#4-alternative-deploy-locally-with-opentofu-cli)
- [Method B: Manual Step-by-Step Provisioning (Imperative gcloud CLI)](#method-b-manual-step-by-step-provisioning-imperative-gcloud-cli)
  - [1. Authenticate and Configure GCP](#1-authenticate-and-configure-gcp)
  - [2. Provision the Infrastructure](#2-provision-the-infrastructure)
  - [3. Enable Secure Access (IAP) and Outbound Internet (Cloud NAT)](#3-enable-secure-access-iap-and-outbound-internet-cloud-nat)
  - [4. Install RKE2 with Cilium (HA Control Plane)](#4-install-rke2-with-cilium-ha-control-plane)
- [Connecting to the Cluster with Local Kubectl](#connecting-to-the-cluster-with-local-kubectl)

---

## Prerequisites

* An active Google Cloud account (with the $300 free trial active).
* A dedicated GCP Project (e.g., `sandbox-lab`).
* [Google Cloud CLI (`gcloud`)](https://cloud.google.com/sdk/docs/install) installed locally.
* `kubectl` and [`helm`](https://helm.sh/docs/intro/install/) installed locally.
* [OpenTofu](https://opentofu.org/docs/intro/install/) (v1.6+) if provisioning locally.
* A domain managed in **Cloudflare** (used for ACME DNS-01 TLS certificate validation and Cloudflare Tunnel).

---

## Method A: Automated Provisioning with OpenTofu & CI/CD (Recommended)

This repository includes complete OpenTofu declarations in the [`tofu/`](../tofu/) directory and an automated GitHub Actions deployment pipeline (`.github/workflows/tofu-apply.yml`).

### Architectural Highlights of the OpenTofu Setup:
* **Dedicated Custom VPC & Subnet (`10.10.0.0/24`)**: Complete isolation from the default network with zero additional GCP cost.
* **Deterministic Static Internal IPs**: `rke2-node-1` (`10.10.0.11`), `rke2-node-2` (`10.10.0.12`), and `rke2-node-3` (`10.10.0.13`).
* **Dedicated Storage Architecture (Root / & /var Separation)**: Each node is provisioned with a default **10 GB Ubuntu 24.04 LTS boot disk** for the root (`/`) filesystem and an attached **50 GB persistent disk** automatically mounted to `/var`. This guarantees that container images, etcd state, and pod ephemeral volumes never deplete OS disk space.
* **Shared Storage & Docker Registry**: A dedicated 50 GB `pd-standard` persistent disk (`rke2-shared-disk`) is attached to `rke2-node-1` and exported across the cluster VPC via kernel NFSv4. All nodes mount this drive at `/shared`, providing cost-effective shared storage for cluster workloads like the internal Docker Registry (`/shared/docker-registry`).
* **Automated Cluster Bootstrapping**: Node 1 initializes RKE2 with Cilium CNI and generates the supervisor endpoint; Nodes 2 & 3 poll port `9345/ping` and join the HA control plane automatically via VM metadata startup scripts.
* **Separation of Day-0 Bootstrap and Day-2 Upgrades**: The startup script installs RKE2 on new nodes at boot time. Running cluster nodes are upgraded in-place without VM teardown or downtime using the **System Upgrade Controller** (see [Guide 6: Automated In-Place RKE2 Upgrades](06-operations-and-cleanup.md#automated-in-place-rke2-upgrades-via-system-upgrade-controller-suc)).
* **VM Recreation Guardrails**: Startup scripts are defined via `metadata = { startup-script = ... }` (updated in-place on GCP) instead of `metadata_startup_script` (which forces VM replacement). Furthermore, the GitHub Actions deployment workflow actively checks the OpenTofu execution plan and blocks any deletion or replacement of cluster VM instances unless specifically permitted via `allow_node_replacement: true`.
* **Intra-Cluster & IAP Firewall Rules**: Allows traffic from Google IAP (`35.235.240.0/20`) for SSH and Kubernetes API, and opens all intra-subnet communication across the cluster nodes.

### 1. One-Time GCP Workload Identity Federation (WIF) Setup

To allow GitHub Actions to provision resources securely without downloading permanent service account JSON keys, run these commands locally once:

```bash
export PROJECT_ID=$(gcloud config get-value project)
export REPO="ymagriso/k8s-resources"
export PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")

# Enable APIs
gcloud services enable iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com compute.googleapis.com iap.googleapis.com

# Create CI Service Account & grant roles
gcloud iam service-accounts create github-actions-ci --display-name="GitHub Actions CI Service Account"
export GCP_CI_SERVICE_ACCOUNT="github-actions-ci@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:${GCP_CI_SERVICE_ACCOUNT}" --role="roles/compute.admin"
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:${GCP_CI_SERVICE_ACCOUNT}" --role="roles/iap.tunnelResourceAccessor"
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:${GCP_CI_SERVICE_ACCOUNT}" --role="roles/iam.serviceAccountUser"

# Create Workload Identity Pool & Provider
gcloud iam workload-identity-pools create "github-pool" --location="global" --display-name="GitHub Actions Pool"
gcloud iam workload-identity-pools providers create-oidc "github-provider" \
    --location="global" \
    --workload-identity-pool="github-pool" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
    --attribute-condition="assertion.repository == '${REPO}'"

# Allow GitHub repo to impersonate CI Service Account
gcloud iam service-accounts add-iam-policy-binding "${GCP_CI_SERVICE_ACCOUNT}" \
    --role="roles/iam.workloadIdentityUser" \
    --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-pool/attribute.repository/${REPO}"

# Print values for GitHub Secrets
echo "GCP_CI_SERVICE_ACCOUNT: $GCP_CI_SERVICE_ACCOUNT"
echo "GCP_WIF_PROVIDER: projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-pool/providers/github-provider"
```

### 2. Configure GitHub Actions Secrets

Navigate to **Settings → Secrets and variables → Actions** in your GitHub repository and add:

| Secret Name | Value Description |
| :--- | :--- |
| `GCP_CI_SERVICE_ACCOUNT` | Output from step 1 above (`github-actions-ci@<PROJECT_ID>.iam.gserviceaccount.com`) |
| `GCP_WIF_PROVIDER` | Output from step 1 above (`projects/<NUM>/locations/global/...`) |
| `CUSTOM_DOMAIN` | Your actual domain name (e.g., `example.com`) — kept private from Git |
| `ACME_EMAIL` | Email address for Let's Encrypt certificate notices |
| `CLOUDFLARE_API_TOKEN` | Cloudflare DNS API token with `Zone:DNS:Edit` permissions |
| `CLOUDFLARED_TUNNEL_TOKEN` | Token for your Cloudflare Zero Trust Tunnel |
| `ARGOCD_GOOGLE_OIDC_CLIENT_ID` | Google Cloud OAuth 2.0 Web Client ID (`<NUM>-<STR>.apps.googleusercontent.com`) |
| `ARGOCD_GOOGLE_OIDC_CLIENT_SECRET` | Google Cloud OAuth 2.0 Client Secret (`GOCSPX-...`) |
| `ARGOCD_ADMIN_EMAIL` | *(Optional)* Google email address granted `role:admin` in Argo CD RBAC (defaults to `ACME_EMAIL`) |
| `MONGODB_ROOT_PASSWORD` | Secure root password for MongoDB |
| `MONGODB_REPLICA_SET_KEY` | ReplicaSet key for MongoDB internal replication |

### 3. Deploy the Cluster via GitHub Actions

1. Go to the **Actions** tab in GitHub.
2. Select the **OpenTofu Apply & Cluster Bootstrap** workflow.
3. Click **Run workflow** (Action: `apply`).
4. In under 10 minutes, the workflow will:
   * Provision the Custom VPC, Cloud Router, Cloud NAT, and 3 VMs via OpenTofu.
   * Wait for RKE2 to complete bootstrapping on all 3 nodes.
   * Inject all Kubernetes secrets and domain manifests via an IAP tunnel.
   * Bootstrap the Argo CD Root App to start GitOps synchronization!

### 4. Alternative: Deploy Locally with OpenTofu CLI

If you prefer applying locally:

```bash
cd tofu
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your GCP project_id

tofu init
tofu plan
tofu apply
```

---

## Method B: Manual Step-by-Step Provisioning (Imperative gcloud CLI)

If you prefer provisioning manually using the Google Cloud CLI:

### 1. Authenticate and Configure GCP

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

### 2. Provision the Infrastructure

Create three `e2-standard-2` instances running Ubuntu 24.04 in `me-west1-a` without external IP addresses:

```bash
gcloud compute instances bulk create \
    --name-pattern="rke2-node-#" \
    --count=3 \
    --zone=me-west1-a \
    --machine-type=e2-standard-2 \
    --network-interface=no-address \
    --create-disk=boot=yes,image-family=ubuntu-2404-lts-amd64,image-project=ubuntu-os-cloud,size=50GB,type=pd-standard
```

### 3. Enable Secure Access (IAP) and Outbound Internet (Cloud NAT)

```bash
# Allow IAP Ingress
gcloud compute firewall-rules create allow-ssh-from-iap \
    --direction=INGRESS \
    --action=allow \
    --rules=tcp:22,tcp:6443 \
    --source-ranges=35.235.240.0/20

# Create Cloud Router and NAT
gcloud compute routers create rke2-nat-router \
    --network=default \
    --region=me-west1

gcloud compute routers nats create rke2-nat-config \
    --router=rke2-nat-router \
    --region=me-west1 \
    --auto-allocate-nat-external-ips \
    --nat-all-subnet-ip-ranges
```

### 4. Install RKE2 with Cilium (HA Control Plane)

**Node 1 (Initial Server):**
```bash
gcloud compute ssh rke2-node-1 --tunnel-through-iap --zone=me-west1-a
sudo mkdir -p /etc/rancher/rke2
sudo tee /etc/rancher/rke2/config.yaml <<EOF
node-name: $(hostname -s)
cni: cilium
EOF
curl -sfL https://get.rke2.io | sudo sh -
sudo systemctl enable --now rke2-server.service
sudo cat /var/lib/rancher/rke2/server/node-token
exit
```

**Nodes 2 and 3 (Join Servers):**
```bash
gcloud compute ssh rke2-node-2 --tunnel-through-iap --zone=me-west1-a
sudo mkdir -p /etc/rancher/rke2
sudo tee /etc/rancher/rke2/config.yaml <<EOF
node-name: $(hostname -s)
server: https://<INTERNAL_IP_OF_NODE_1>:9345
token: <TOKEN>
cni: cilium
EOF
curl -sfL https://get.rke2.io | sudo sh -
sudo systemctl enable --now rke2-server.service
exit
```

---

## Connecting to the Cluster with Local Kubectl

Regardless of whether you used Method A or Method B:

1. **Download the kubeconfig file:**
   ```bash
   gcloud compute ssh rke2-node-1 --tunnel-through-iap --zone=me-west1-a \
       --command="sudo cat /etc/rancher/rke2/rke2.yaml" > ./rke2-kubeconfig.yaml
   ```

2. **Open the IAP Port Forwarding Tunnel:**
   *(Run this in a dedicated terminal window and leave it running)*
   ```bash
   gcloud compute start-iap-tunnel rke2-node-1 6443 \
       --local-host-port=localhost:6443 \
       --zone=me-west1-a
   ```

3. **Verify Node Status:**
   ```bash
   export KUBECONFIG=$(pwd)/rke2-kubeconfig.yaml
   kubectl get nodes -o wide
   ```

All three nodes will be listed in `Ready` status with the roles `control-plane,etcd`.

---

[← Back to Main README](../README.md) | [← Previous: Architecture & Costs](01-architecture-and-costs.md) | [Next: cert-manager & Let's Encrypt →](03-cert-manager-letsencrypt.md)
