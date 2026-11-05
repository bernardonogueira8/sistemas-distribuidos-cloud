output "deployment" {
  description = "Nonsecret deployment contract for build, Auth Proxy schema task, and health scripts. SQL credentials remain in Secret Manager and Terraform state."
  value = {
    name                    = var.name
    project_id              = var.project_id
    region                  = var.region
    zones                   = var.zones
    network                 = module.network.network
    subnetwork              = module.network.subnetwork
    runtime_service_account = google_service_account.runtime.email
    runtime_secret_id       = module.database.runtime_secret_id
    runtime_secret_version  = module.database.runtime_secret_version
    db_instance             = module.database.db_instance
    db_connection_name      = module.database.db_connection_name
    db_host                 = module.database.db_host
    db_name                 = module.database.db_name
    bucket                  = module.storage.bucket
    registry                = module.storage.registry
    registry_host           = module.storage.registry_host
    image_repository        = module.storage.image_repository
    image                   = var.image
    enable_runtime          = var.enable_runtime
    api_url                 = try(module.load_balancer[0].api_url, null)
    domain_url              = try(module.load_balancer[0].domain_url, null)
    lb_ip                   = try(module.load_balancer[0].ip_address, null)
    mig                     = try(module.compute[0].mig, null)
    instance_group          = try(module.compute[0].instance_group, null)
    runtime_regions = var.enable_runtime ? [
      { region = var.region, zones = var.zones, mig = module.compute[0].mig, instance_group = module.compute[0].instance_group },
      { region = var.secondary_region.region, zones = var.secondary_region.zones, mig = module.compute_secondary[0].mig, instance_group = module.compute_secondary[0].instance_group }
    ] : []
    backend_service = try(module.load_balancer[0].backend_service, null)
  }
  depends_on = [module.network, module.database, module.storage, google_project_iam_member.logs]
}

output "image_repository" {
  value = module.storage.image_repository
}

output "api_url" {
  value = try(module.load_balancer[0].api_url, null)
}

output "mig" {
  value = try(module.compute[0].mig, null)
}