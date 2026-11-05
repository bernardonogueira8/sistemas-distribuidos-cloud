output "api_url" { value = "http://${google_compute_global_address.api.address}" }
output "ip_address" { value = google_compute_global_address.api.address }
output "backend_service" { value = google_compute_backend_service.api.name }
output "domain_url" { value = var.domain_name == "" ? null : "http://${var.domain_name}" }