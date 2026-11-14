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

# Dedicated persistent disks for /var on each node
resource "google_compute_disk" "rke2_var_disk" {
  count = var.node_count
  name  = "rke2-node-${count.index + 1}-var"
  type  = "pd-standard"
  zone  = var.zone
  size  = var.var_disk_size
  labels = {
    managed-by = "opentofu"
    cluster    = "rke2"
    mount      = "var"
  }
}

# State migration: preserve existing rke2-shared-disk on rke2-node-1 as index [0]
# when upgrading from single-node NFS to 3-node replicated GlusterFS.
moved {
  from = google_compute_disk.rke2_shared_disk
  to   = google_compute_disk.rke2_shared_disk[0]
}

# Dedicated 50GB persistent disks on each node backing the 3-way replicated GlusterFS /shared volume
resource "google_compute_disk" "rke2_shared_disk" {
  count = var.node_count
  name  = count.index == 0 ? "rke2-shared-disk" : "rke2-node-${count.index + 1}-shared"
  type  = "pd-standard"
  zone  = var.zone
  size  = var.shared_disk_size
  labels = {
    managed-by = "opentofu"
    cluster    = "rke2"
    mount      = "shared"
  }
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

  attached_disk {
    source      = google_compute_disk.rke2_var_disk[count.index].id
    device_name = "var-disk"
  }

  attached_disk {
    source      = google_compute_disk.rke2_shared_disk[count.index].id
    device_name = "shared-disk"
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

  # IMPORTANT: use metadata["startup-script"], NOT `metadata_startup_script`.
  # In the google provider, `metadata_startup_script` is ForceNew: any change
  # (e.g. an RKE2 version bump) destroys and recreates ALL nodes at once,
  # wiping etcd and persistent data. `metadata` is updated in place; the new
  # script only applies to newly created nodes. Running nodes are upgraded
  # in place by the System Upgrade Controller (argocd/apps/workloads/rke2-upgrade-plans).
  metadata = {
    startup-script = templatefile("${path.module}/startup.sh.tftpl", {
      is_init_node = count.index == 0
      node_name    = "rke2-node-${count.index + 1}"
      node_ip      = cidrhost(var.subnet_cidr, 11 + count.index)
      init_node_ip = cidrhost(var.subnet_cidr, 11)
      all_node_ips = [for idx in range(var.node_count) : cidrhost(var.subnet_cidr, 11 + idx)]
      subnet_cidr  = var.subnet_cidr
      token        = random_password.rke2_token.result
      rke2_version = var.rke2_version
    })
  }

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
