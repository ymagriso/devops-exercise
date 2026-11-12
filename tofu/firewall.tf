# Allow administrative access (SSH 22, K8s API 6443) exclusively via Google IAP
resource "google_compute_firewall" "allow_iap" {
  name        = "allow-ssh-k8s-from-iap"
  network     = google_compute_network.rke2_vpc.name
  description = "Allow inbound SSH and Kubernetes API through Google Cloud IAP"

  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]

  allow {
    protocol = "tcp"
    ports    = ["22", "6443"]
  }

  target_tags = ["rke2-node"]
}

# Allow unrestricted intra-cluster communication among RKE2 cluster nodes
resource "google_compute_firewall" "allow_internal" {
  name        = "allow-internal-rke2"
  network     = google_compute_network.rke2_vpc.name
  description = "Allow all intra-subnet traffic for RKE2, Cilium CNI, etcd, and Pod networking"

  direction     = "INGRESS"
  source_ranges = [var.subnet_cidr]

  allow {
    protocol = "all"
  }

  target_tags = ["rke2-node"]
}
