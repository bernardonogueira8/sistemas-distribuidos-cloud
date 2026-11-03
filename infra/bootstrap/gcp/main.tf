terraform {
  required_version = ">= 1.9.0, < 2.0.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" { type = string }
variable "region" { type = string }
variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}
variable "name" {
  type    = string
  default = "distributed-cloud"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,16}$", var.name))
    error_message = "name must be a lowercase resource prefix of at most 17 characters."
  }
}
variable "github_repository" {
  type = string
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "Use the exact GitHub owner/repository."
  }
}
variable "github_repository_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "Use the immutable numeric GitHub repository ID."
  }
}
variable "state_bucket_name" { type = string }

locals {
  prefix = "${var.name}-${var.environment}"
  services = toset([
    "serviceusage.googleapis.com", "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com", "iamcredentials.googleapis.com", "sts.googleapis.com",
    "compute.googleapis.com", "sqladmin.googleapis.com", "servicenetworking.googleapis.com",
    "storage.googleapis.com", "artifactregistry.googleapis.com", "secretmanager.googleapis.com",
    "logging.googleapis.com", "monitoring.googleapis.com"
  ])
}

resource "google_project_service" "api" {
  for_each           = local.services
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_storage_bucket" "state" {
  name                        = var.state_bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  versioning { enabled = true }
  lifecycle { prevent_destroy = true }
  depends_on = [google_project_service.api]
}

resource "google_service_account" "deployer" {
  account_id   = "${local.prefix}-deploy"
  display_name = "Terraform infrastructure deployer"
  depends_on   = [google_project_service.api]
}
resource "google_service_account" "build" {
  account_id   = "${local.prefix}-build"
  display_name = "Artifact publisher"
  depends_on   = [google_project_service.api]
}

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "${local.prefix}-gh"
  depends_on                = [google_project_service.api]
}
resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  attribute_mapping = {
    "google.subject"          = "assertion.sub"
    "attribute.repository_id" = "assertion.repository_id"
  }
  attribute_condition = "assertion.repository == '${var.github_repository}' && assertion.repository_id == '${var.github_repository_id}' && assertion.ref == 'refs/heads/main' && assertion.environment == '${var.environment}'"
  oidc { issuer_uri = "https://token.actions.githubusercontent.com" }
}
resource "google_service_account_iam_member" "github" {
  for_each           = { deployer = google_service_account.deployer.name, build = google_service_account.build.name }
  service_account_id = each.value
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository_id/${var.github_repository_id}"
}

resource "google_storage_bucket_iam_member" "deployer_state" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.deployer.email}"
}

resource "google_project_iam_member" "deployer" {
  for_each = toset([
    "roles/compute.admin", "roles/cloudsql.admin", "roles/servicenetworking.networksAdmin",
    "roles/storage.admin", "roles/artifactregistry.admin", "roles/secretmanager.admin",
    "roles/iam.serviceAccountAdmin", "roles/iam.serviceAccountUser", "roles/iam.roleAdmin",
    "roles/resourcemanager.projectIamAdmin", "roles/logging.configWriter", "roles/monitoring.editor",
    "roles/serviceusage.serviceUsageConsumer"
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.deployer.email}"
}

output "workload_identity_provider" { value = google_iam_workload_identity_pool_provider.github.name }
output "build_service_account" { value = google_service_account.build.email }
output "deployer_service_account" { value = google_service_account.deployer.email }
output "state_bucket" { value = google_storage_bucket.state.name }