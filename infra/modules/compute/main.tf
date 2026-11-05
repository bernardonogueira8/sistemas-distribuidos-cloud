locals {
  startup = templatefile("${path.module}/startup.sh.tftpl", {
    image          = var.image
    project_id     = var.project_id
    secret_id      = var.runtime_secret_id
    secret_version = var.runtime_secret_version
    db_host        = var.db_host
    db_name        = var.db_name
    bucket         = var.bucket
    registry_host  = var.registry_host
  })
}

data "google_compute_image" "cos" {
  family  = "cos-stable"
  project = "cos-cloud"
}

resource "google_compute_instance_template" "api" {
  name_prefix  = "${var.name}-"
  machine_type = var.machine_type
  region       = var.region
  tags         = [coalesce(var.network_tag, "${var.name}-api")]
  labels       = var.labels
  disk {
    source_image = data.google_compute_image.cos.self_link
    auto_delete  = true
    boot         = true
    disk_size_gb = 20
    disk_type    = "pd-balanced"
  }
  network_interface {
    subnetwork = var.subnetwork
    access_config {}
  }
  service_account {
    email  = var.runtime_service_account
    scopes = ["cloud-platform"]
  }
  metadata = {
    startup-script           = local.startup
    block-project-ssh-keys   = "true"
    enable-oslogin           = "TRUE"
    disable-legacy-endpoints = "true"
  }
  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }
  lifecycle { create_before_destroy = true }
}

resource "google_compute_health_check" "api" {
  name                = var.name
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3
  http_health_check {
    port         = 3000
    request_path = "/"
  }
}

resource "google_compute_region_instance_group_manager" "api" {
  name                             = var.name
  region                           = var.region
  base_instance_name               = var.name
  distribution_policy_zones        = var.zones
  distribution_policy_target_shape = "EVEN"
  target_size                      = var.min_replicas
  version {
    instance_template = google_compute_instance_template.api.id
  }
  named_port {
    name = "http"
    port = 3000
  }
  auto_healing_policies {
    health_check      = google_compute_health_check.api.id
    initial_delay_sec = 300
  }
  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 2
    max_unavailable_fixed = 0
    replacement_method    = "SUBSTITUTE"
  }
  wait_for_instances        = true
  wait_for_instances_status = "UPDATED"
  lifecycle {
    ignore_changes = [target_size]
  }
}

resource "google_compute_region_autoscaler" "api" {
  name   = var.name
  region = var.region
  target = google_compute_region_instance_group_manager.api.id
  autoscaling_policy {
    min_replicas    = var.min_replicas
    max_replicas    = var.max_replicas
    cooldown_period = 180
    cpu_utilization { target = 0.65 }
  }
}