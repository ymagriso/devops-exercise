[← Back to Main README](../README.md) | [← Previous: MongoDB ReplicaSet & Metrics](05-mongodb-replicaset-and-metrics.md)

---

# 6. Cluster Operations, Dependency Automation & Cost Management

- [Automated Dependency Updates with Mend Renovate](#automated-dependency-updates-with-mend-renovate)
  - [Tracked Managers & Files](#tracked-managers--files)
  - [Cooldown (`minimumReleaseAge`) & Rate-Limiting Strategy](#cooldown-minimumreleaseage--rate-limiting-strategy)
- [Stop the Instances (Cost Conservation)](#stop-the-instances-cost-conservation)
- [Start the Instances](#start-the-instances)
- [Check Instance Status](#check-instance-status)
- [Delete the Cluster (Full Cleanup)](#delete-the-cluster-full-cleanup)
  - [Method A: Automated Teardown via GitHub Actions (Recommended)](#method-a-automated-teardown-via-github-actions-recommended)
  - [Method B: Teardown via OpenTofu CLI](#method-b-teardown-via-opentofu-cli)
  - [Method C: Manual Teardown via gcloud CLI](#method-c-manual-teardown-via-gcloud-cli)

---

## Automated Dependency Updates with Mend Renovate

This repository uses the [**Mend Renovate**](https://developer.mend.io) GitHub App configured via [`renovate.json`](../renovate.json) to automatically detect and open Pull Requests for new **Helm chart versions**, **Docker container image tags**, and **OpenTofu provider versions**. Because Argo CD is configured with automated sync (`automated: true`), merging a Renovate PR into `main` automatically rolls out the upgrade to the cluster.

### Tracked Managers & Files

| Renovate Manager | Pattern (`managerFilePatterns`) | Tracked Dependencies |
| :--- | :--- | :--- |
| **`terraform`** | `/^tofu/.*\.tf$/`, `tofu/.terraform.lock.hcl` | • OpenTofu required version<br>• `hashicorp/google` provider<br>• `hashicorp/random` provider |
| **`argocd`** | `/^argocd/(apps\|bootstrap)/[^/]+\.ya?ml$/` | • `argo-cd` Helm chart in [`argocd/apps/argocd.yaml`](../argocd/apps/argocd.yaml)<br>• `cert-manager` Helm chart in [`argocd/apps/cert-manager.yaml`](../argocd/apps/cert-manager.yaml)<br>• `mongodb` OCI Helm chart in [`argocd/apps/mongodb.yaml`](../argocd/apps/mongodb.yaml) |
| **`kubernetes`** | `/^argocd/apps/workloads/.+\.ya?ml$/` | • `cloudflare/cloudflared` image in [`argocd/apps/workloads/cloudflared/deployment.yaml`](../argocd/apps/workloads/cloudflared/deployment.yaml) |
| **`helm-values`** | `/(^\|/)values\.ya?ml$/` | • `bitnamilegacy/mongodb` & `bitnamilegacy/mongodb-exporter` images in [`mongodb/values.yaml`](../mongodb/values.yaml) |
| **`github-actions`** | `.github/workflows/*.ya?ml` | • GitHub Actions action versions (`setup-opentofu`, `auth`, `setup-gcloud`) |

### Cooldown (`minimumReleaseAge`) & Rate-Limiting Strategy

To protect the GitOps cluster against supply-chain compromises and unstable "Day-0" upstream releases:
* **3-Day Default Cooldown (`"minimumReleaseAge": "3 days"`):** Patch and minor Helm chart or Docker image updates must soak upstream for at least 3 days before Renovate opens a PR.
* **7-Day Major Release Cooldown (`matchUpdateTypes: ["major"]`):** Major version upgrades require a 7-day cooldown window to allow early upstream hotfixes (`.1` / `.2`) to settle.
* **Pinned Major Series for MongoDB (`registry-1.docker.io/bitnamicharts/mongodb`):** Major chart updates (`17.x+`, which target MongoDB `8.2`/`9.0` and `:latest` tags) are disabled (`enabled: false`) so the chart remains aligned with the pinned MongoDB `8.0.13` (`16.x`) release.
* **PR Rate Limits (`prHourlyLimit: 2`, `prConcurrentLimit: 5`):** Prevents PR spam while automatically tagging PRs with `helm`, `docker`, `opentofu`, and `dependencies` labels.

---

To stretch your $300 GCP Free Trial, shut down the instances when you are not actively using the cluster and start them back up when needed.

## Stop the Instances (Cost Conservation)

```bash
gcloud compute instances stop rke2-node-1 rke2-node-2 rke2-node-3 --zone=me-west1-a
```

*Note: You will still incur a small persistent disk storage fee (~$6.75/month total in `me-west1`) while the VMs are stopped.*

## Start the Instances

Because `rke2-server.service` was enabled with `systemctl enable` and GCP preserves each VM's internal IP address across stops/starts, starting the instances automatically brings the RKE2 cluster, `cert-manager`, Argo CD, and the Cloudflare Tunnel back online:

```bash
gcloud compute instances start rke2-node-1 rke2-node-2 rke2-node-3 --zone=me-west1-a
```

Once the VMs are running, re-open the IAP port-forwarding tunnel from [Guide 2: Step 5](02-gcp-rke2-cluster-setup.md#connecting-to-the-cluster-with-local-kubectl) if you want local `kubectl` access (the Argo CD Web UI at `https://argocd.<your-domain>` will reconnect automatically via `cloudflared`).

## Check Instance Status

Verify whether the nodes are `RUNNING` or `TERMINATED`:

```bash
gcloud compute instances list --filter="name~'^rke2-node-'"
```

---

## Delete the Cluster (Full Cleanup)

When you are done testing and want to ensure **zero charges** continue against your free trial, tear down the infrastructure using one of the following methods:

### Method A: Automated Teardown via GitHub Actions (Recommended)

1. Open your repository on GitHub and click the **Actions** tab.
2. Select the **OpenTofu Teardown (Destroy Cluster)** workflow.
3. Click **Run workflow**.
4. In the confirmation prompt, enter `DESTROY` and click run.
5. OpenTofu will permanently destroy all 3 VMs, persistent disks, Cloud NAT, Cloud Router, firewall rules, and the Custom VPC.

### Method B: Teardown via OpenTofu CLI

If you manage resources locally with the OpenTofu CLI:

```bash
cd tofu
tofu destroy
```

### Method C: Manual Teardown via gcloud CLI

If you provisioned the cluster using manual `gcloud` commands:

```bash
# Delete the 3 VMs and their attached boot disks
gcloud compute instances delete rke2-node-1 rke2-node-2 rke2-node-3 --zone=me-west1-a

# Delete the Cloud Router (and attached Cloud NAT configuration)
gcloud compute routers delete rke2-nat-router --region=me-west1

# Delete the IAP firewall rule
gcloud compute firewall-rules delete allow-ssh-from-iap
```

Verify that all disks have been removed:

```bash
gcloud compute disks list
```

---

[← Back to Main README](../README.md) | [← Previous: MongoDB ReplicaSet & Metrics](05-mongodb-replicaset-and-metrics.md)
