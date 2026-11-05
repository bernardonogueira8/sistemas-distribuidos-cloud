variable "name" { type = string }
variable "project_id" { type = string }
variable "region" { type = string }
variable "zones" { type = list(string) }
variable "subnetwork" { type = string }
variable "runtime_service_account" { type = string }
variable "runtime_secret_id" { type = string }
variable "runtime_secret_version" { type = string }
variable "db_host" { type = string }
variable "db_name" { type = string }
variable "bucket" { type = string }
variable "registry_host" { type = string }
variable "image" { type = string }
variable "machine_type" { type = string }
variable "min_replicas" { type = number }
variable "max_replicas" { type = number }
variable "labels" { type = map(string) }
variable "network_tag" {
  type    = string
  default = null
}