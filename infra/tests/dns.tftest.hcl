mock_provider "google" {
  mock_data "google_dns_managed_zone" {
    defaults = {
      name     = "sistemasdistribuidosunifan"
      dns_name = "sistemasdistribuidosunifan.com.br."
    }
  }
}

run "apex_points_to_global_load_balancer" {
  command = plan
  module { source = "./modules/dns" }

  variables {
    managed_zone = "sistemasdistribuidosunifan"
    domain_name  = "sistemasdistribuidosunifan.com.br"
    ip_address   = "34.149.215.10"
  }

  assert {
    condition     = google_dns_record_set.api.name == "sistemasdistribuidosunifan.com.br." && google_dns_record_set.api.managed_zone == "sistemasdistribuidosunifan"
    error_message = "The apex record must use the existing Cloud DNS zone."
  }
  assert {
    condition     = google_dns_record_set.api.type == "A" && google_dns_record_set.api.ttl == 300 && one(google_dns_record_set.api.rrdatas) == "34.149.215.10"
    error_message = "The apex A record must point to the global load balancer IP with the configured TTL."
  }
}

run "reject_hostname_outside_managed_zone" {
  command = plan
  module { source = "./modules/dns" }

  variables {
    managed_zone = "sistemasdistribuidosunifan"
    domain_name  = "other.example.net"
    ip_address   = "34.149.215.10"
  }

  expect_failures = [google_dns_record_set.api]
}
