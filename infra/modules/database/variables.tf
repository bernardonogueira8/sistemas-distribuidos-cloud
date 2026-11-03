variable "name" { type = string }
variable "region" { type = string }
variable "network" { type = string }
variable "db_tier" { type = string }
variable "deletion_protection" { type = bool }
variable "labels" { type = map(string) }
variable "runtime_service_account" { type = string }