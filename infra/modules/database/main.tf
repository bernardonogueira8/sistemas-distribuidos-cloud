resource "google_sql_database_instance" "app" {
  name                = "${var.name}-mysql"
  region              = var.region
  database_version    = "MYSQL_8_0"
  deletion_protection = var.deletion_protection
  settings {
    tier                        = var.db_tier
    edition                     = "ENTERPRISE"
    availability_type           = "ZONAL"
    disk_type                   = "PD_SSD"
    disk_size                   = 10
    disk_autoresize             = true
    disk_autoresize_limit       = 100
    deletion_protection_enabled = var.deletion_protection
    user_labels                 = var.labels
    ip_configuration {
      ipv4_enabled                                  = true
      private_network                               = var.network
      enable_private_path_for_google_cloud_services = true
      ssl_mode                                      = "ALLOW_UNENCRYPTED_AND_ENCRYPTED"
    }
    backup_configuration {
      enabled                        = true
      binary_log_enabled             = true
      start_time                     = "03:00"
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 7
        retention_unit   = "COUNT"
      }
    }
    maintenance_window {
      day          = 7
      hour         = 4
      update_track = "stable"
    }
  }
}

resource "google_sql_database" "app" {
  name     = "aula_pratica_db"
  instance = google_sql_database_instance.app.name
}

resource "random_password" "app" {
  length  = 32
  special = false
}

resource "google_sql_user" "app" {
  name     = "api_user"
  instance = google_sql_database_instance.app.name
  host     = "%"
  password = random_password.app.result
}

resource "google_secret_manager_secret" "runtime" {
  secret_id = "${var.name}-runtime"
  labels    = var.labels
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "runtime" {
  secret = google_secret_manager_secret.runtime.id
  secret_data = jsonencode({
    DB_USER     = google_sql_user.app.name
    DB_PASSWORD = random_password.app.result
  })
}

resource "google_secret_manager_secret_iam_member" "access" {
  for_each = {
    runtime = var.runtime_service_account
  }
  secret_id = google_secret_manager_secret.runtime.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${each.value}"
}