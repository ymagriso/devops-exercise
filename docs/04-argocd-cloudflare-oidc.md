[← Back to Main README](../README.md) | [← Previous: cert-manager & Let's Encrypt](03-cert-manager-letsencrypt.md) | [Next: MongoDB ReplicaSet & Metrics →](05-mongodb-replicaset-and-metrics.md)

---

# 4. Deploy Self-Managed Argo CD, Cloudflare Tunnel & Google OIDC

- [Overview](#overview)
- [Step 1: Install Argo CD via Helm](#step-1-install-argo-cd-via-helm)
- [Step 2: Issue a Let's Encrypt TLS Certificate for Argo CD](#step-2-issue-a-lets-encrypt-tls-certificate-for-argo-cd)
- [Step 3: Configure the Cloudflare Tunnel Secret and Public Hostname](#step-3-configure-the-cloudflare-tunnel-secret-and-public-hostname)
- [Step 4: Bootstrap GitOps (Root App-of-Apps)](#step-4-bootstrap-gitops-root-app-of-apps)
- [Step 5: Configure Google OIDC Authentication (Disable Default Admin)](#step-5-configure-google-oidc-authentication-disable-default-admin)

---

## Overview

Argo CD is deployed using the official `argo/argo-cd` Helm chart (Standard single-replica profile) and configured using the **App-of-Apps GitOps pattern** ([`argocd/bootstrap/root-app.yaml`](../argocd/bootstrap/root-app.yaml)) so that Argo CD continuously manages:
* **Itself** ([`argocd/apps/argocd.yaml`](../argocd/apps/argocd.yaml) + [`argocd/values.yaml`](../argocd/values.yaml))
* **`cert-manager`** ([`argocd/apps/cert-manager.yaml`](../argocd/apps/cert-manager.yaml) + [`cert-manager/values.yaml`](../cert-manager/values.yaml))
* **Cloudflare Tunnel (`cloudflared`)** ([`argocd/apps/cloudflared.yaml`](../argocd/apps/cloudflared.yaml) + [`argocd/apps/workloads/cloudflared/`](../argocd/apps/workloads/cloudflared/))
* **MongoDB ReplicaSet (`mongodb`)** ([`argocd/apps/mongodb.yaml`](../argocd/apps/mongodb.yaml) + [`mongodb/values.yaml`](../mongodb/values.yaml))
* **System Upgrade Controller** ([`argocd/apps/system-upgrade-controller.yaml`](../argocd/apps/system-upgrade-controller.yaml) + [`argocd/apps/workloads/system-upgrade-controller/`](../argocd/apps/workloads/system-upgrade-controller/))
* **RKE2 Upgrade Plans** ([`argocd/apps/rke2-upgrade-plans.yaml`](../argocd/apps/rke2-upgrade-plans.yaml) + [`argocd/apps/workloads/rke2-upgrade-plans/`](../argocd/apps/workloads/rke2-upgrade-plans/))

Because `cloudflared` establishes an outbound-only connection through Cloud NAT to Cloudflare's edge and connects internally to `argocd-server` over HTTPS using a Let's Encrypt certificate issued by `cert-manager`, the Argo CD UI and CLI are exposed on your custom domain with **end-to-end strict TLS** and zero GCP LoadBalancer or public IP costs.

## Step 1: Install Argo CD via Helm

Add the Argo Helm repository and install Argo CD using [`argocd/values.yaml`](../argocd/values.yaml):

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --create-namespace \
    --version 10.17.2 \
    --values argocd/values.yaml \
    --wait
```

Retrieve the initial `admin` password (if needed before enabling Google OIDC):

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d; echo
```

## Step 2: Issue a Let's Encrypt TLS Certificate for Argo CD

Apply [`argocd/certificate.yaml`](../argocd/certificate.yaml), substituting `argocd.yourdomain.com` with your actual subdomain so `cert-manager` provisions a signed Let's Encrypt certificate into the `argocd-server-tls` Secret:

```bash
sed 's/argocd.yourdomain.com/argocd.YOUR_ACTUAL_DOMAIN/g' argocd/certificate.yaml | kubectl apply -f -
```

Wait ~1–2 minutes for the DNS-01 challenge to complete and verify the certificate is `READY: True`:

```bash
kubectl get certificate -n argocd
```

Restart `argocd-server` so it loads the newly issued TLS certificate from `argocd-server-tls`:

```bash
kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout status deployment argocd-server -n argocd
```

## Step 3: Configure the Cloudflare Tunnel Secret and Public Hostname

1. In the [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/) (*Networks → Tunnels*), create a new **Cloudflared** tunnel (e.g., `rke2-cluster`) and copy the **Tunnel Token**.
2. Create the `cloudflared` namespace and store the token in a Kubernetes Secret (kept out of Git):

```bash
kubectl create namespace cloudflared

kubectl create secret generic cloudflared-token \
    -n cloudflared \
    --from-literal=token='<YOUR_CLOUDFLARE_TUNNEL_TOKEN>'
```

3. In the tunnel's **Public Hostname** configuration in Cloudflare Zero Trust:
   * **Argo CD:**
     * **Subdomain:** `argocd`
     * **Domain:** `<your-domain>`
     * **Service Type:** `HTTPS`
     * **URL:** `argocd-server.argocd.svc.cluster.local:443`
     * **Additional application settings → TLS → Origin Server Name:** `argocd.<your-domain>` *(validates the Let's Encrypt certificate served by `argocd-server`)*
   * **`devops-demo` (`sample-nodejs`):**
     * **Subdomain:** `demo`
     * **Domain:** `<your-domain>`
     * **Service Type:** `HTTP`
     * **URL:** `devops-demo.devops-demo.svc.cluster.local:8080`
     * Cloudflare terminates HTTPS at the edge (`https://demo.<your-domain>`) and forwards HTTP inside the cluster to the `devops-demo` `ClusterIP` Service (endpoints: `/my-app`, `/about`, `/ready`, `/live`, `/classified`, and `/metrics`).

## Step 4: Bootstrap GitOps (Root App-of-Apps)

Apply the root `Application` ([`argocd/bootstrap/root-app.yaml`](../argocd/bootstrap/root-app.yaml)), which automatically syncs all applications under [`argocd/apps/`](../argocd/apps/) (`argocd`, `cert-manager`, and `cloudflared`):

```bash
kubectl apply -f argocd/bootstrap/root-app.yaml
```

Verify that all Argo CD applications are `Synced` and `Healthy`, and that the `cloudflared` pods are running:

```bash
kubectl get applications -n argocd
kubectl get pods -n cloudflared
```

You can now access the Argo CD UI directly in your browser at `https://argocd.<your-domain>`.

## Step 5: Configure Google OIDC Authentication (Disable Default Admin)

[`argocd/values.yaml`](../argocd/values.yaml) disables the built-in local `admin` user (`admin.enabled: false`) and configures native OpenID Connect (OIDC) authentication against Google (`https://accounts.google.com`).

1. **Create a Google OAuth 2.0 Client in GCP Console** (*APIs & Services → Credentials*):
   * Configure the **OAuth consent screen** (*Google Auth Platform → Audience*):
     * Set **User Type (Audience)** to **External** (required for personal `@gmail.com` accounts; **Internal** restricts sign-in to a Google Workspace organization and returns `"can only be used within its organization"`).
     * Keep **Publishing status** set to **Testing** and add your Google email under **Test users** (this blocks all unlisted Google accounts at Google's login screen without needing app verification).
   * Click **Create Credentials → OAuth client ID**:
     * **Application type:** `Web application`
     * **Authorized redirect URIs:**
       * `https://argocd.<your-domain>/auth/callback`
       * `http://localhost:8085/auth/callback` *(optional, for `argocd login --sso` CLI)*
2. **Store the OAuth Client ID and Secret in Kubernetes** (labeled with `app.kubernetes.io/part-of=argocd` so Argo CD can read `$argocd-google-oidc:clientID` and `$argocd-google-oidc:clientSecret`):

```bash
kubectl create secret generic argocd-google-oidc \
    -n argocd \
    --from-literal=clientID='<GOOGLE_CLIENT_ID>' \
    --from-literal=clientSecret='<GOOGLE_CLIENT_SECRET>'

kubectl label secret argocd-google-oidc -n argocd app.kubernetes.io/part-of=argocd
```

3. **Set your Argo CD URL and RBAC Admin Email in-cluster** (kept out of Git and preserved across syncs via `ignoreDifferences` in [`argocd/apps/argocd.yaml`](../argocd/apps/argocd.yaml)):

```bash
# Set the external URL on argocd-cm for OIDC redirect callbacks
kubectl patch configmap argocd-cm -n argocd \
    --type merge \
    -p '{"data":{"url":"https://argocd.YOUR_ACTUAL_DOMAIN"}}'

# Grant role:admin to your Google account email on argocd-rbac-cm
kubectl patch configmap argocd-rbac-cm -n argocd \
    --type merge \
    -p '{"data":{"policy.csv":"g, YOUR_GOOGLE_EMAIL, role:admin"}}'
```

4. **Granting Access to Additional Google Users (Optional):**
   Because access is protected by both Google OAuth **Testing** mode and Argo CD RBAC (`policy.default: ""`), adding another user requires updating both layers:
   * **GCP Console (*OAuth consent screen / Audience → Test users*):** Click **+ Add Users** and add the user's Google email (supports up to 100 test users).
   * **Argo CD RBAC (`argocd-rbac-cm`):** Append a `g, <email>, <role>` line (`role:readonly` for view-only access or `role:admin` for full admin access):

```bash
kubectl patch configmap argocd-rbac-cm -n argocd \
    --type merge \
    -p '{"data":{"policy.csv":"g, YOUR_GOOGLE_EMAIL, role:admin\ng, COLLEAGUE_GOOGLE_EMAIL, role:readonly"}}'
```

---

[← Back to Main README](../README.md) | [← Previous: cert-manager & Let's Encrypt](03-cert-manager-letsencrypt.md) | [Next: MongoDB ReplicaSet & Metrics →](05-mongodb-replicaset-and-metrics.md)
