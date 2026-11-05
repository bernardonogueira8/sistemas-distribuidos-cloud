mock_provider "google" {}
mock_provider "random" {
  mock_resource "random_password" {
    defaults = { result = "mock-password-not-a-real-credential" }
  }
}

run "private_network" {
  command = plan
  module { source = "./modules/network" }
  variables {
    name   = "distributed-cloud"
    region = "us-central1"
  }
  assert {
    condition     = !google_compute_network.app.auto_create_subnetworks && google_compute_subnetwork.app.private_ip_google_access
    error_message = "The application subnet must use private Google access on a custom VPC."
  }
  assert {
    condition     = toset(google_compute_firewall.gfe.source_ranges) == toset(["35.191.0.0/16", "130.211.0.0/22"]) && toset(one(google_compute_firewall.gfe.allow).ports) == toset(["3000"])
    error_message = "The load balancer health-check rule must stay limited to Google frontend ranges."
  }
  assert {
    condition     = toset(google_compute_firewall.api_direct.source_ranges) == toset(["0.0.0.0/0"]) && toset(one(google_compute_firewall.api_direct.allow).ports) == toset(["3000"])
    error_message = "Direct API access must be available over IPv4 TCP port 3000."
  }
}

run "secondary_network" {
  command = plan
  module { source = "./modules/network" }
  variables {
    name             = "distributed-cloud"
    region           = "us-central1"
    secondary_region = { region = "europe-west3", cidr = "10.42.16.0/20" }
  }
  assert {
    condition     = google_compute_subnetwork.app.region == "us-central1" && google_compute_subnetwork.app.ip_cidr_range == "10.42.0.0/20" && google_compute_subnetwork.secondary[0].region == "europe-west3" && google_compute_subnetwork.secondary[0].ip_cidr_range == "10.42.16.0/20" && google_compute_subnetwork.secondary[0].private_ip_google_access
    error_message = "Preserve the primary subnet and add a distinct European subnet with private Google access."
  }
  assert {
    condition     = google_compute_router.secondary[0].region == "europe-west3" && google_compute_router_nat.secondary[0].region == "europe-west3" && google_compute_router_nat.secondary[0].source_subnetwork_ip_ranges_to_nat == "LIST_OF_SUBNETWORKS" && length(google_compute_router_nat.secondary[0].subnetwork) == 1
    error_message = "The secondary region must have its own subnet-scoped NAT."
  }
}

run "two_region_load_balancer" {
  command = plan
  module { source = "./modules/load_balancer" }
  variables {
    name                       = "distributed-cloud"
    instance_group             = "projects/example-project/regions/us-central1/instanceGroups/distributed-cloud"
    additional_instance_groups = ["projects/example-project/regions/europe-west3/instanceGroups/distributed-cloud-secondary"]
    health_check               = "projects/example-project/global/healthChecks/distributed-cloud"
  }
  assert {
    condition     = toset([for backend in google_compute_backend_service.api.backend : backend.group]) == toset([var.instance_group, var.additional_instance_groups[0]]) && alltrue([for backend in google_compute_backend_service.api.backend : backend.balancing_mode == "UTILIZATION" && backend.capacity_scaler == 1])
    error_message = "One global backend service must route to both regional groups at full capacity."
  }
}

run "public_proxy_database_and_shared_sql_identity" {
  command = apply
  module { source = "./modules/database" }
  variables {
    name                    = "distributed-cloud"
    region                  = "us-central1"
    network                 = "projects/example-project/global/networks/distributed-cloud"
    db_tier                 = "db-f1-micro"
    deletion_protection     = true
    labels                  = {}
    runtime_service_account = "runtime@example-project.iam.gserviceaccount.com"
  }
  assert {
    condition     = google_sql_database_instance.app.settings[0].ip_configuration[0].ipv4_enabled && length(google_sql_database_instance.app.settings[0].ip_configuration[0].authorized_networks) == 0 && google_sql_database_instance.app.settings[0].ip_configuration[0].private_network == "projects/example-project/global/networks/distributed-cloud"
    error_message = "Cloud SQL must have a public endpoint for the Auth Proxy, no authorized networks, and retain private VPC connectivity for runtime workloads."
  }
  assert {
    condition     = google_sql_database_instance.app.deletion_protection && google_sql_database_instance.app.settings[0].backup_configuration[0].enabled && google_sql_database_instance.app.settings[0].availability_type == "ZONAL"
    error_message = "SQL must retain deletion protection and backups; this demo does not promise regional SQL HA."
  }
  assert {
    condition     = sensitive(jsondecode(google_secret_manager_secret_version.runtime.secret_data).DB_PASSWORD) == random_password.app.result && jsondecode(google_secret_manager_secret_version.runtime.secret_data).DB_USER == google_sql_user.app.name
    error_message = "The secret must contain the Terraform-generated SQL user credentials."
  }
  assert {
    condition     = length(google_secret_manager_secret_iam_member.access) == 1 && google_secret_manager_secret_iam_member.access["runtime"].member == "serviceAccount:runtime@example-project.iam.gserviceaccount.com"
    error_message = "Only the API runtime identity should read the shared SQL credential; the release deployer reads it for one-off schema setup."
  }
}

run "private_storage_and_signing" {
  command = plan
  module { source = "./modules/storage" }
  variables {
    name                           = "distributed-cloud"
    project_id                     = "example-project"
    region                         = "us-central1"
    bucket_name                    = "example-project-uploads"
    labels                         = {}
    runtime_service_account        = "runtime@example-project.iam.gserviceaccount.com"
    runtime_identity               = "projects/example-project/serviceAccounts/runtime@example-project.iam.gserviceaccount.com"
    build_service_account          = "builder@example-project.iam.gserviceaccount.com"
    destroy_upload_bucket_contents = false
  }
  assert {
    condition     = google_storage_bucket.uploads.public_access_prevention == "enforced" && google_storage_bucket.uploads.uniform_bucket_level_access && !google_storage_bucket.uploads.force_destroy
    error_message = "Uploads must remain private and force deletion must be off by default."
  }
  assert {
    condition     = toset(google_project_iam_custom_role.sign_blob.permissions) == toset(["iam.serviceAccounts.signBlob"]) && google_service_account_iam_member.sign_blob.member == "serviceAccount:runtime@example-project.iam.gserviceaccount.com"
    error_message = "Private signed URLs require runtime self-signing with only signBlob."
  }
  assert {
    condition     = length(google_artifact_registry_repository_iam_member.reader) == 1 && google_artifact_registry_repository_iam_member.reader["runtime"].role == "roles/artifactregistry.reader" && google_artifact_registry_repository_iam_member.builder.role == "roles/artifactregistry.writer"
    error_message = "Runtime alone needs repository read access; only the existing builder gets repository write access."
  }
}

run "private_two_zone_compute" {
  command = plan
  module { source = "./modules/compute" }
  variables {
    name                    = "distributed-cloud"
    project_id              = "example-project"
    region                  = "us-central1"
    zones                   = ["us-central1-a", "us-central1-b"]
    subnetwork              = "projects/example-project/regions/us-central1/subnetworks/distributed-cloud"
    runtime_service_account = "runtime@example-project.iam.gserviceaccount.com"
    runtime_secret_id       = "distributed-cloud-runtime"
    runtime_secret_version  = "1"
    db_host                 = "10.43.0.3"
    db_name                 = "aula_pratica_db"
    bucket                  = "example-project-uploads"
    registry_host           = "us-central1-docker.pkg.dev"
    image                   = "us-central1-docker.pkg.dev/example-project/distributed-cloud/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    machine_type            = "e2-small"
    min_replicas            = 2
    max_replicas            = 4
    labels                  = {}
  }
  assert {
    condition     = toset(google_compute_region_instance_group_manager.api.distribution_policy_zones) == toset(["us-central1-a", "us-central1-b"]) && google_compute_region_instance_group_manager.api.distribution_policy_target_shape == "EVEN"
    error_message = "The regional MIG must explicitly distribute across the selected two zones."
  }
  assert {
    condition     = google_compute_region_instance_group_manager.api.update_policy[0].max_surge_fixed == 2 && google_compute_region_instance_group_manager.api.update_policy[0].max_unavailable_fixed == 0 && google_compute_region_autoscaler.api.autoscaling_policy[0].min_replicas == 2
    error_message = "Maintain at least two replicas, with two surge instances and no planned unavailability."
  }
  assert {
    condition     = length(google_compute_instance_template.api.network_interface[0].access_config) == 1
    error_message = "Each runtime instance must receive an ephemeral public IPv4 address for direct API access."
  }
  assert {
    condition     = strcontains(google_compute_instance_template.api.metadata["startup-script"], "versions/1:access") && !strcontains(google_compute_instance_template.api.metadata["startup-script"], "mock-password")
    error_message = "VM metadata may contain a secret version reference, never its credential value."
  }
}

run "http_ip_load_balancer" {
  command = plan
  module { source = "./modules/load_balancer" }
  variables {
    name           = "distributed-cloud"
    domain_name    = ""
    instance_group = "projects/example-project/regions/us-central1/instanceGroups/distributed-cloud"
    health_check   = "projects/example-project/global/healthChecks/distributed-cloud"
  }
  assert {
    condition     = google_compute_global_forwarding_rule.http.port_range == "80" && google_compute_global_forwarding_rule.http.load_balancing_scheme == "EXTERNAL_MANAGED" && google_compute_backend_service.api.protocol == "HTTP"
    error_message = "The initial demo endpoint must use HTTP on port 80."
  }
  assert {
    condition     = google_compute_backend_service.api.security_policy == null
    error_message = "No WAF is required for this initial demo."
  }
  assert {
    condition     = length(google_compute_url_map.api.host_rule) == 0 && output.domain_url == null
    error_message = "IP-only load balancers must not add hostname rules."
  }
}

run "http_domain_load_balancer" {
  command = plan
  module { source = "./modules/load_balancer" }
  variables {
    name           = "distributed-cloud"
    domain_name    = "sistemasdistribuidosunifan.com.br"
    instance_group = "projects/example-project/regions/us-central1/instanceGroups/distributed-cloud"
    health_check   = "projects/example-project/global/healthChecks/distributed-cloud"
  }
  assert {
    condition     = one(google_compute_url_map.api.host_rule).hosts == toset(["sistemasdistribuidosunifan.com.br"]) && one(google_compute_url_map.api.host_rule).path_matcher == one(google_compute_url_map.api.path_matcher).name
    error_message = "The requested hostname must route to the API path matcher."
  }
  assert {
    condition     = output.domain_url == "http://sistemasdistribuidosunifan.com.br" && google_compute_global_forwarding_rule.http.port_range == "80"
    error_message = "Expose the requested HTTP domain without replacing the existing IP endpoint."
  }
}