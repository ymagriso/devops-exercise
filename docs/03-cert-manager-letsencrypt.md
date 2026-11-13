[← Back to Main README](../README.md) | [← Previous: GCP & RKE2 Cluster Setup](02-gcp-rke2-cluster-setup.md) | [Next: Argo CD, Cloudflare Tunnel & Google OIDC →](04-argocd-cloudflare-oidc.md)

---

# 3. Install `cert-manager` and Configure Let's Encrypt (HTTPS)

- [Overview](#overview)
- [Step 1: Create the Cloudflare API Token Secret](#step-1-create-the-cloudflare-api-token-secret)
- [Step 2: Install cert-manager via Helm](#step-2-install-cert-manager-via-helm)
- [Step 3: Configure Let's Encrypt ClusterIssuers](#step-3-configure-lets-encrypt-clusterissuers)

---

## Overview

Because the RKE2 cluster nodes do not have public external IPs (`--network-interface=no-address`), Let's Encrypt cannot connect inbound on port `80` for an `HTTP-01` challenge. Instead, **`cert-manager`** is configured to use the **ACME `DNS-01` challenge with Cloudflare**, reaching the Cloudflare and Let's Encrypt APIs outbound through your Cloud NAT gateway to automatically provision and renew trusted TLS certificates.

## Step 1: Create the Cloudflare API Token Secret

1. In the [Cloudflare Dashboard](https://dash.cloudflare.com/) (*Manage Account → Account API tokens* or *My Profile → API Tokens*), create a token with:
   * **Specific domains (`<your-domain>`):** `DNS: Edit` (and `Zone: Read`, plus **Entire account:** `Cloudflare One Connector: cloudflared: Write` if sharing `CLOUDFLARE_API_TOKEN` with the Cloudflare Tunnel automation in [`tofu-apply.yml`](../.github/workflows/tofu-apply.yml))
2. Create the `cert-manager` namespace and store the token in a Kubernetes Secret (kept out of Git):

```bash
kubectl create namespace cert-manager

kubectl create secret generic cloudflare-api-token-secret \
    -n cert-manager \
    --from-literal=api-token='<YOUR_CLOUDFLARE_API_TOKEN>'
```

## Step 2: Install cert-manager via Helm

Add the Jetstack Helm repository and install `cert-manager` using [`cert-manager/values.yaml`](../cert-manager/values.yaml):

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --values cert-manager/values.yaml \
    --wait
```

Verify that all `cert-manager` pods are running:

```bash
kubectl get pods -n cert-manager
```

## Step 3: Configure Let's Encrypt ClusterIssuers

Apply [`cert-manager/cluster-issuers.yaml`](../cert-manager/cluster-issuers.yaml), substituting your ACME registration email address on the fly so your personal email is not committed to the public repository:

```bash
sed 's/your-email@yourdomain.com/YOUR_ACTUAL_EMAIL/g' cert-manager/cluster-issuers.yaml | kubectl apply -f -
```

Verify that both `letsencrypt-staging` and `letsencrypt-prod` `ClusterIssuer` resources report `READY: True`:

```bash
kubectl get clusterissuer
```

---

[← Back to Main README](../README.md) | [← Previous: GCP & RKE2 Cluster Setup](02-gcp-rke2-cluster-setup.md) | [Next: Argo CD, Cloudflare Tunnel & Google OIDC →](04-argocd-cloudflare-oidc.md)
