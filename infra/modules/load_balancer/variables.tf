variable "name" { type = string }
variable "instance_group" { type = string }
variable "health_check" { type = string }
variable "domain_name" {
	type    = string
	default = ""
}