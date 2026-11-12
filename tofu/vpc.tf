resource "google_compute_network" "rke2_vpc" {
  name                    = var.vpc_name
  auto_create_subnetworks = false
  description             = "Dedicated custom VPC for high availability RKE2 cluster"
}

resource "google_compute_subnetwork" "rke2_subnet" {
  name                     = "${var.vpc_name}-subnet"
  ip_cidr_range            = var.subnet_cidr
  region                   = var.region
  network                  = google_compute_network.rke2_vpc.id
  private_ip_google_access = true
  description              = "Subnetwork for RKE2 nodes in ${var.region}"
}

resource "google_compute_router" "nat_router" {
  name    = "rke2-nat-router"
  region  = var.region
  network = google_compute_network.rke2_vpc.id
}

resource "google_compute_router_nat" "nat_config" {
  name                               = "rke2-nat-config"
  router                             = google_compute_router.nat_router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = false
    filter = "ERRORS_ONLY"
  }
}
