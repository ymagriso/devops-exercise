[← Back to Main README](../README.md) | [← Previous: MongoDB ReplicaSet & Metrics](05-mongodb-replicaset-and-metrics.md)

---

# 6. Cluster Operations & Cost Management

- [Stop the Instances](#stop-the-instances)
- [Start the Instances](#start-the-instances)
- [Check Instance Status](#check-instance-status)
- [Delete the Cluster (Full Cleanup)](#delete-the-cluster-full-cleanup)

---

To stretch your $300 GCP Free Trial, shut down the instances when you are not actively using the cluster and start them back up when needed.

## Stop the Instances

```bash
gcloud compute instances stop rke2-node-1 rke2-node-2 rke2-node-3 --zone=me-west1-a
```

*Note: You will still incur a small persistent disk storage fee (~$6.75/month total in `me-west1`) while the VMs are stopped.*

## Start the Instances

Because `rke2-server.service` was enabled with `systemctl enable` and GCP preserves each VM's internal IP address across stops/starts, starting the instances automatically brings the RKE2 cluster, `cert-manager`, Argo CD, and the Cloudflare Tunnel back online:

```bash
gcloud compute instances start rke2-node-1 rke2-node-2 rke2-node-3 --zone=me-west1-a
```

Once the VMs are running, re-open the IAP port-forwarding tunnel from [Guide 2: Step 5](02-gcp-rke2-cluster-setup.md#5-configure-local-kubectl-access) if you want local `kubectl` access (the Argo CD Web UI at `https://argocd.<your-domain>` will reconnect automatically via `cloudflared`).

## Check Instance Status

Verify whether the nodes are `RUNNING` or `TERMINATED`:

```bash
gcloud compute instances list --filter="name~'^rke2-node-'"
```

## Delete the Cluster (Full Cleanup)

To permanently remove the VMs, their attached persistent disks (which are configured with `autoDelete: true` by default), the Cloud NAT router, and the firewall rule so no charges remain:

```bash
# Delete the 3 VMs and their boot disks
gcloud compute instances delete rke2-node-1 rke2-node-2 rke2-node-3 --zone=me-west1-a

# Delete the Cloud Router (and its attached Cloud NAT configuration)
gcloud compute routers delete rke2-nat-router --region=me-west1

# Delete the IAP SSH firewall rule
gcloud compute firewall-rules delete allow-ssh-from-iap
```

Verify that all disks have been removed:

```bash
gcloud compute disks list
```

---

[← Back to Main README](../README.md) | [← Previous: MongoDB ReplicaSet & Metrics](05-mongodb-replicaset-and-metrics.md)
