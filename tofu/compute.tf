# Cryptographically secure cluster token shared among RKE2 server nodes
resource "random_password" "rke2_token" {
  length  = 48
  special = false
}

# Dedicated least-privilege Service Account for RKE2 cluster nodes
resource "google_service_account" "rke2_node_sa" {
  account_id   = "rke2-node-sa"
  display_name = "RKE2 Node Service Account"
  description  = "Dedicated service account attached to private RKE2 cluster VMs"
}

resource "google_project_iam_member" "rke2_node_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.rke2_node_sa.email}"
}

resource "google_project_iam_member" "rke2_node_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.rke2_node_sa.email}"
}

# 3-Node High Availability RKE2 Cluster Instances
resource "google_compute_instance" "rke2_node" {
  count        = var.node_count
  name         = "rke2-node-${count.index + 1}"
  machine_type = var.machine_type
  zone         = var.zone

  tags = ["rke2-node"]

  boot_disk {
    auto_delete = true
    initialize_params {
      image = var.boot_disk_image
      size  = var.boot_disk_size
      type  = "pd-standard"
      labels = {
        managed-by = "opentofu"
        cluster    = "rke2"
      }
    }
  }

  network_interface {
    network    = google_compute_network.rke2_vpc.id
    subnetwork = google_compute_subnetwork.rke2_subnet.id
    network_ip = cidrhost(var.subnet_cidr, 11 + count.index)
    # Strictly private: no access_config block (no public IP address allocated)
  }

  service_account {
    email  = google_service_account.rke2_node_sa.email
    scopes = ["cloud-platform"]
  }

  metadata_startup_script = templatefile("${path.module}/startup.sh.tftpl", {
    is_init_node = count.index == 0
    node_name    = "rke2-node-${count.index + 1}"
    node_ip      = cidrhost(var.subnet_cidr, 11 + count.index)
    init_node_ip = cidrhost(var.subnet_cidr, 11)
    token        = random_password.rke2_token.result
    rke2_version = var.rke2_version
  })

  labels = {
    managed-by = "opentofu"
    cluster    = "rke2"
    role       = count.index == 0 ? "initial-server" : "join-server"
  }

  # Ensure Cloud NAT is fully established before VM boots and attempts to curl get.rke2.io
  depends_on = [
    google_compute_router_nat.nat_config,
    google_compute_firewall.allow_internal,
    google_compute_firewall.allow_iap
  ]
}
