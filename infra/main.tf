provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  labels = { application = var.name, managed_by = "terraform" }
}

resource "google_service_account" "runtime" {
  account_id   = "${var.name}-run"
  display_name = "API runtime"
}

resource "google_project_iam_member" "logs" {
  for_each = {
    runtime = google_service_account.runtime.email
  }
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${each.value}"
}

module "network" {
  source           = "./modules/network"
  name             = var.name
  region           = var.region
  secondary_region = var.secondary_region
}

module "database" {
  source                  = "./modules/database"
  name                    = var.name
  region                  = var.region
  network                 = module.network.network
  db_tier                 = var.db_tier
  deletion_protection     = var.deletion_protection
  labels                  = local.labels
  runtime_service_account = google_service_account.runtime.email
  depends_on              = [module.network]
}

module "storage" {
  source                         = "./modules/storage"
  name                           = var.name
  project_id                     = var.project_id
  region                         = var.region
  bucket_name                    = var.bucket_name
  labels                         = local.labels
  runtime_service_account        = google_service_account.runtime.email
  runtime_identity               = google_service_account.runtime.name
  build_service_account          = var.build_service_account
  destroy_upload_bucket_contents = var.destroy_upload_bucket_contents
}

module "compute" {
  source                  = "./modules/compute"
  count                   = var.enable_runtime ? 1 : 0
  name                    = var.name
  project_id              = var.project_id
  region                  = var.region
  zones                   = var.zones
  subnetwork              = module.network.subnetwork
  runtime_service_account = google_service_account.runtime.email
  runtime_secret_id       = module.database.runtime_secret_id
  runtime_secret_version  = module.database.runtime_secret_version
  db_host                 = module.database.db_host
  db_name                 = module.database.db_name
  bucket                  = module.storage.bucket
  registry_host           = module.storage.registry_host
  image                   = var.image
  machine_type            = var.machine_type
  min_replicas            = var.min_replicas
  max_replicas            = var.max_replicas
  labels                  = local.labels
  depends_on              = [module.database, module.storage, module.network, google_project_iam_member.logs]
}

module "load_balancer" {
  source                     = "./modules/load_balancer"
  count                      = var.enable_runtime ? 1 : 0
  name                       = var.name
  domain_name                = var.domain_name
  instance_group             = module.compute[0].instance_group
  additional_instance_groups = [module.compute_secondary[0].instance_group]
  health_check               = module.compute[0].health_check
}

module "dns" {
  source = "./modules/dns"
  count  = var.enable_runtime && var.domain_name != "" ? 1 : 0

  managed_zone = var.dns_managed_zone
  domain_name  = var.domain_name
  ip_address   = module.load_balancer[0].ip_address
}

module "compute_secondary" {
  source                  = "./modules/compute"
  count                   = var.enable_runtime ? 1 : 0
  name                    = "${var.name}-secondary"
  project_id              = var.project_id
  region                  = var.secondary_region.region
  zones                   = var.secondary_region.zones
  subnetwork              = module.network.secondary_subnetwork
  network_tag             = "${var.name}-api"
  runtime_service_account = google_service_account.runtime.email
  runtime_secret_id       = module.database.runtime_secret_id
  runtime_secret_version  = module.database.runtime_secret_version
  db_host                 = module.database.db_host
  db_name                 = module.database.db_name
  bucket                  = module.storage.bucket
  registry_host           = module.storage.registry_host
  image                   = var.image
  machine_type            = var.machine_type
  min_replicas            = var.min_replicas
  max_replicas            = var.max_replicas
  labels                  = local.labels
  depends_on              = [module.database, module.storage, module.network, google_project_iam_member.logs]
}