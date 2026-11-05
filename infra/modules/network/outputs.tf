output "network" { value = google_compute_network.app.id }
output "subnetwork" { value = google_compute_subnetwork.app.id }
output "secondary_subnetwork" { value = try(google_compute_subnetwork.secondary[0].id, null) }