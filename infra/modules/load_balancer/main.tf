resource "google_compute_backend_service" "api" {
  name                  = var.name
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  timeout_sec           = 60
  health_checks         = [var.health_check]
  backend {
    group           = var.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1
  }
  dynamic "backend" {
    for_each = var.additional_instance_groups
    content {
      group           = backend.value
      balancing_mode  = "UTILIZATION"
      capacity_scaler = 1
    }
  }
  log_config {
    enable      = true
    sample_rate = 1
  }
}

resource "google_compute_global_address" "api" {
  name = var.name
}

resource "google_compute_url_map" "api" {
  name            = var.name
  default_service = google_compute_backend_service.api.id
  dynamic "host_rule" {
    for_each = var.domain_name == "" ? [] : [var.domain_name]
    content {
      hosts        = [host_rule.value]
      path_matcher = "api"
    }
  }
  dynamic "path_matcher" {
    for_each = var.domain_name == "" ? [] : [var.domain_name]
    content {
      name            = "api"
      default_service = google_compute_backend_service.api.id
    }
  }
}

resource "google_compute_target_http_proxy" "api" {
  name    = var.name
  url_map = google_compute_url_map.api.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "${var.name}-http"
  ip_address            = google_compute_global_address.api.address
  target                = google_compute_target_http_proxy.api.id
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}