data "google_dns_managed_zone" "existing" {
  name = var.managed_zone
}

resource "google_dns_record_set" "api" {
  name         = "${trimsuffix(var.domain_name, ".")}."
  managed_zone = data.google_dns_managed_zone.existing.name
  type         = "A"
  ttl          = 300
  rrdatas      = [var.ip_address]

  lifecycle {
    precondition {
      condition     = endswith(lower("${trimsuffix(var.domain_name, ".")}."), lower(data.google_dns_managed_zone.existing.dns_name))
      error_message = "The DNS record name must belong to the selected managed zone."
    }
  }
}