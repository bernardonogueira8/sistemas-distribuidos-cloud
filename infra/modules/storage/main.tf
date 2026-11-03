resource "google_storage_bucket" "uploads" {
  name                        = var.bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = var.labels
  versioning { enabled = true }
  soft_delete_policy { retention_duration_seconds = 604800 }
  lifecycle { prevent_destroy = true }
}

resource "google_artifact_registry_repository" "app" {
  location      = var.region
  repository_id = var.name
  format        = "DOCKER"
  labels        = var.labels
}

resource "google_storage_bucket_iam_member" "runtime" {
  bucket = google_storage_bucket.uploads.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${var.runtime_service_account}"
}

resource "google_project_iam_custom_role" "sign_blob" {
  project     = var.project_id
  role_id     = "${replace(var.name, "-", "_")}_signBlob"
  title       = "Upload URL signing only"
  permissions = ["iam.serviceAccounts.signBlob"]
}

resource "google_service_account_iam_member" "sign_blob" {
  service_account_id = var.runtime_identity
  role               = google_project_iam_custom_role.sign_blob.name
  member             = "serviceAccount:${var.runtime_service_account}"
}

resource "google_artifact_registry_repository_iam_member" "reader" {
  for_each = {
    runtime = var.runtime_service_account
  }
  location   = var.region
  repository = google_artifact_registry_repository.app.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${each.value}"
}

resource "google_artifact_registry_repository_iam_member" "builder" {
  location   = var.region
  repository = google_artifact_registry_repository.app.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${var.build_service_account}"
}