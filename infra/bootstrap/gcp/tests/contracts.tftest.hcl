mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      name = "projects/example-project/serviceAccounts/mock-sa@example-project.iam.gserviceaccount.com"
    }
  }
  mock_resource "google_iam_workload_identity_pool" {
    defaults = {
      name = "projects/123456789/locations/global/workloadIdentityPools/example"
    }
  }
}
variables {
  project_id           = "example-project"
  region               = "us-central1"
  environment          = "dev"
  github_repository    = "example/distributed-cloud"
  github_repository_id = "123456"
  state_bucket_name    = "example-project-tfstate-dev"
}
run "restricted_identity_and_state" {
  command = plan
  override_resource {
    override_during = plan
    target          = google_iam_workload_identity_pool.github
    values          = { name = "projects/123456789/locations/global/workloadIdentityPools/example" }
  }
  assert {
    condition     = google_storage_bucket.state.public_access_prevention == "enforced" && google_storage_bucket.state.versioning[0].enabled
    error_message = "State must be versioned and private."
  }
  assert {
    condition     = strcontains(google_iam_workload_identity_pool_provider.github.attribute_condition, "assertion.ref == 'refs/heads/main'") && strcontains(google_iam_workload_identity_pool_provider.github.attribute_condition, "assertion.environment == 'dev'") && strcontains(google_iam_workload_identity_pool_provider.github.attribute_condition, "assertion.repository_id == '123456'") && google_service_account_iam_member.github["deployer"].member == "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository_id/123456"
    error_message = "Federation must constrain main, exact environment claim, immutable repository ID and service-account membership."
  }
  assert {
    condition     = google_storage_bucket_iam_member.deployer_state.role == "roles/storage.objectAdmin"
    error_message = "Deployer requires state object/lock operations."
  }
}
run "invalid_environment" {
  command = plan
  variables { environment = "staging" }
  expect_failures = [var.environment]
}
run "invalid_repository" {
  command = plan
  variables { github_repository = "example/repo' || true" }
  expect_failures = [var.github_repository]
}