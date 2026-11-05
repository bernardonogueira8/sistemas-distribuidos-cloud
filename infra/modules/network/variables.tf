variable "name" { type = string }
variable "region" { type = string }
variable "secondary_region" {
  type    = object({ region = string, cidr = string })
  default = null
}