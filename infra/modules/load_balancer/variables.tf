variable "name" { type = string }
variable "instance_group" { type = string }
variable "additional_instance_groups" {
  type    = list(string)
  default = []
}
variable "health_check" { type = string }
variable "domain_name" {
  type    = string
  default = ""
}