mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      name  = "projects/example-project/serviceAccounts/mock-account@example-project.iam.gserviceaccount.com"
      email = "mock-account@example-project.iam.gserviceaccount.com"
    }
  }
  mock_resource "google_compute_network" {
    defaults = { id = "projects/example-project/global/networks/distributed-cloud" }
  }
  mock_resource "google_secret_manager_secret_version" {
    defaults = { version = "1" }
  }
  mock_resource "google_compute_global_address" {
    defaults = { address = "203.0.113.10" }
  }
}
mock_provider "random" {}

override_resource {
  override_during = plan
  target          = module.database.google_secret_manager_secret_version.runtime
  values          = { version = "1" }
}

variables {
  project_id            = "example-project"
  region                = "us-central1"
  name                  = "distributed-cloud"
  zones                 = ["us-central1-a", "us-central1-b"]
  bucket_name           = "example-project-uploads"
  build_service_account = "builder@example-project.iam.gserviceaccount.com"
  enable_runtime        = false
  image                 = ""
}

run "initial_infrastructure_without_image" {
  command = plan

  assert {
    condition     = length(module.compute) == 0 && length(module.compute_secondary) == 0 && length(module.load_balancer) == 0 && length(output.deployment.runtime_regions) == 0
    error_message = "The first apply must not launch image-dependent serving resources."
  }
  assert {
    condition     = output.deployment.api_url == null && output.deployment.mig == null && output.deployment.image == ""
    error_message = "Initial deployment outputs must reflect a disabled runtime."
  }
  assert {
    condition     = output.image_repository == "us-central1-docker.pkg.dev/example-project/distributed-cloud/api"
    error_message = "The repository must be available before the image is built."
  }
  assert {
    condition     = google_service_account.runtime.account_id == "distributed-cloud-run" && !can(output.deployment.schema_service_account)
    error_message = "The deployment contract must not retain an unused schema VM identity."
  }
  assert {
    condition     = !issensitive(output.deployment) && !can(output.deployment.DB_PASSWORD) && !can(output.deployment.password) && !can(output.deployment.secret_data)
    error_message = "The deployment contract must not expose SQL credentials."
  }
}

run "enable_digest_pinned_runtime" {
  command = plan
  override_resource {
    override_during = plan
    target          = module.load_balancer[0].google_compute_global_address.api
    values          = { address = "203.0.113.10" }
  }
  variables {
    enable_runtime = true
    image          = "us-central1-docker.pkg.dev/example-project/distributed-cloud/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
  assert {
    condition     = length(module.compute) == 1 && length(module.load_balancer) == 1 && output.api_url == "http://203.0.113.10"
    error_message = "Enabling the runtime must expose the HTTP IP endpoint."
  }
  assert {
    condition     = output.mig == "distributed-cloud" && output.deployment.runtime_secret_version == "1"
    error_message = "Scripts require the MIG name and explicit nonsecret credential version."
  }
  assert {
    condition     = length(module.compute_secondary) == 1 && [for target in output.deployment.runtime_regions : target.region] == ["us-central1", "europe-west3"] && output.deployment.runtime_regions[1].mig == "distributed-cloud-secondary"
    error_message = "Runtime must expose both regional MIGs while retaining the legacy primary name."
  }
}

run "reject_same_secondary_region" {
  command = plan
  variables { secondary_region = { region = "us-central1", zones = ["us-central1-a", "us-central1-b"], cidr = "10.42.16.0/20" } }
  expect_failures = [var.secondary_region]
}

run "reject_secondary_duplicate_zones" {
  command = plan
  variables { secondary_region = { region = "europe-west3", zones = ["europe-west3-a", "europe-west3-a"], cidr = "10.42.16.0/20" } }
  expect_failures = [var.secondary_region]
}

run "reject_secondary_foreign_zone" {
  command = plan
  variables { secondary_region = { region = "europe-west3", zones = ["us-central1-a", "europe-west3-b"], cidr = "10.42.16.0/20" } }
  expect_failures = [var.secondary_region]
}

run "reject_secondary_overlapping_subnet" {
  command = plan
  variables { secondary_region = { region = "europe-west3", zones = ["europe-west3-a", "europe-west3-b"], cidr = "10.42.0.0/20" } }
  expect_failures = [var.secondary_region]
}

run "reject_runtime_without_image" {
  command = plan
  variables {
    enable_runtime = true
    image          = ""
  }
  expect_failures = [var.image]
}

run "reject_mutable_image" {
  command = plan
  variables {
    image = "us-central1-docker.pkg.dev/example-project/distributed-cloud/api:latest"
  }
  expect_failures = [var.image]
}

run "reject_foreign_repository" {
  command = plan
  variables {
    image = "us-central1-docker.pkg.dev/other-project/distributed-cloud/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
  expect_failures = [var.image]
}

run "reject_one_zone" {
  command = plan
  variables { zones = ["us-central1-a"] }
  expect_failures = [var.zones]
}

run "reject_duplicate_zones" {
  command = plan
  variables { zones = ["us-central1-a", "us-central1-a"] }
  expect_failures = [var.zones]
}

run "reject_foreign_region_zone" {
  command = plan
  variables { zones = ["us-central1-a", "us-east1-b"] }
  expect_failures = [var.zones]
}

run "reject_single_replica" {
  command = plan
  variables { min_replicas = 1 }
  expect_failures = [var.min_replicas]
}

run "reject_fractional_replicas" {
  command = plan
  variables { min_replicas = 2.5 }
  expect_failures = [var.min_replicas]
}

run "reject_inverted_replica_limits" {
  command = plan
  variables { max_replicas = 1 }
  expect_failures = [var.max_replicas]
}