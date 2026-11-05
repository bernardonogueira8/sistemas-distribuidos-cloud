resource "google_compute_network" "app" {
  name                    = var.name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "app" {
  name                     = var.name
  region                   = var.region
  network                  = google_compute_network.app.id
  ip_cidr_range            = "10.42.0.0/20"
  private_ip_google_access = true
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.1
    metadata             = "EXCLUDE_ALL_METADATA"
  }
}

resource "google_compute_global_address" "sql" {
  name          = "${var.name}-sql"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.app.id
}

resource "google_service_networking_connection" "sql" {
  network                 = google_compute_network.app.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.sql.name]
}

resource "google_compute_router" "app" {
  name    = var.name
  region  = var.region
  network = google_compute_network.app.id
}

resource "google_compute_router_nat" "app" {
  name                               = var.name
  router                             = google_compute_router.app.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.app.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_compute_firewall" "gfe" {
  name          = "${var.name}-gfe"
  network       = google_compute_network.app.id
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["${var.name}-api"]
  allow {
    protocol = "tcp"
    ports    = ["3000"]
  }
  log_config { metadata = "EXCLUDE_ALL_METADATA" }
}

resource "google_compute_firewall" "api_direct" {
  name          = "${var.name}-api-direct"
  network       = google_compute_network.app.id
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["${var.name}-api"]
  allow {
    protocol = "tcp"
    ports    = ["3000"]
  }
  log_config { metadata = "EXCLUDE_ALL_METADATA" }
}

resource "google_compute_subnetwork" "secondary" {
  count                    = var.secondary_region == null ? 0 : 1
  name                     = "${var.name}-secondary"
  region                   = var.secondary_region.region
  network                  = google_compute_network.app.id
  ip_cidr_range            = var.secondary_region.cidr
  private_ip_google_access = true
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.1
    metadata             = "EXCLUDE_ALL_METADATA"
  }
}

resource "google_compute_router" "secondary" {
  count   = var.secondary_region == null ? 0 : 1
  name    = "${var.name}-secondary"
  region  = var.secondary_region.region
  network = google_compute_network.app.id
}

resource "google_compute_router_nat" "secondary" {
  count                              = var.secondary_region == null ? 0 : 1
  name                               = "${var.name}-secondary"
  router                             = google_compute_router.secondary[0].name
  region                             = var.secondary_region.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.secondary[0].id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}