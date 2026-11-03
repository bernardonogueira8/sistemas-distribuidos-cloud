output "db_instance" { value = google_sql_database_instance.app.name }
output "db_connection_name" { value = google_sql_database_instance.app.connection_name }
output "db_host" { value = google_sql_database_instance.app.private_ip_address }
output "db_name" { value = google_sql_database.app.name }
output "runtime_secret_id" { value = google_secret_manager_secret.runtime.secret_id }
output "runtime_secret_version" { value = google_secret_manager_secret_version.runtime.version }