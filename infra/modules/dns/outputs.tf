output "record_name" {
  value = google_dns_record_set.api.name
}

output "record_ip" {
  value = one(google_dns_record_set.api.rrdatas)
}