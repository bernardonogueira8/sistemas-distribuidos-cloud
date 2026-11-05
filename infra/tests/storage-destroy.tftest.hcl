mock_provider "google" {}

run "storage_full_destroy_opt_in" {
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
    destroy_upload_bucket_contents = true
  }

  assert {
    condition     = google_storage_bucket.uploads.force_destroy
    error_message = "Only the explicit full-destroy input may enable removal of uploaded objects."
  }
}