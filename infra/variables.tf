variable "project_id" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "Use a valid Google Cloud project ID."
  }
}

variable "region" {
  type    = string
  default = "us-central1"
  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "Use a Google Cloud region such as us-central1."
  }
}

variable "secondary_region" {
  description = "Secondary API region. SQL, storage and registry remain in the primary region."
  type = object({
    region = string
    zones  = list(string)
    cidr   = string
  })
  default = {
    region = "europe-west3"
    zones  = ["europe-west3-a", "europe-west3-b"]
    cidr   = "10.42.16.0/20"
  }
  validation {
    condition = (
      var.secondary_region.region != var.region &&
      can(regex("^[a-z]+-[a-z]+[0-9]+$", var.secondary_region.region)) &&
      length(var.secondary_region.zones) == 2 &&
      length(distinct(var.secondary_region.zones)) == 2 &&
      alltrue([for zone in var.secondary_region.zones : can(regex("^${var.secondary_region.region}-[a-z]$", zone))]) &&
      can(cidrnetmask(var.secondary_region.cidr)) &&
      can(regex("^10\\.42\\.(16|32|48|64|80|96|112|128|144|160|176|192|208|224|240)\\.0/20$", var.secondary_region.cidr))
    )
    error_message = "Use a different region, two distinct zones in that region, and a nonoverlapping /20 from 10.42.16.0/20 through 10.42.240.0/20."
  }
}

variable "name" {
  type    = string
  default = "distributed-cloud"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,16}$", var.name))
    error_message = "name must be a lowercase resource prefix of at most 17 characters."
  }
}

variable "zones" {
  type = list(string)
  validation {
    condition     = length(var.zones) == 2 && length(distinct(var.zones)) == 2 && alltrue([for zone in var.zones : can(regex("^${var.region}-[a-z]$", zone))])
    error_message = "Supply exactly two distinct zones in the selected region."
  }
}

variable "bucket_name" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "Use a globally unique DNS-compatible bucket name (3-63 characters)."
  }
}

variable "build_service_account" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9-]+@[^/]+\\.iam\\.gserviceaccount\\.com$", var.build_service_account))
    error_message = "Pass the existing bootstrap build service account email."
  }
}

variable "db_tier" {
  type    = string
  default = "db-f1-micro"
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "machine_type" {
  type    = string
  default = "e2-small"
}

variable "min_replicas" {
  type    = number
  default = 2
  validation {
    condition     = var.min_replicas >= 2 && floor(var.min_replicas) == var.min_replicas
    error_message = "min_replicas must be an integer of at least two."
  }
}

variable "max_replicas" {
  type    = number
  default = 4
  validation {
    condition     = var.max_replicas >= var.min_replicas && floor(var.max_replicas) == var.max_replicas
    error_message = "max_replicas must be an integer greater than or equal to min_replicas."
  }
}

variable "domain_name" {
  description = "Optional HTTP hostname routed by the global load balancer and its existing Cloud DNS zone."
  type        = string
  default     = "sistemasdistribuidosunifan.com.br"
  validation {
    condition     = var.domain_name == "" || (length(var.domain_name) <= 253 && can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", var.domain_name)))
    error_message = "Use a lowercase DNS hostname without a scheme, port or path, or an empty string for IP-only access."
  }
}

variable "dns_managed_zone" {
  description = "Name of the existing public Cloud DNS managed zone for domain_name."
  type        = string
  default     = "sistemasdistribuidosunifan"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,61}[a-z0-9]$", var.dns_managed_zone))
    error_message = "Use the name of the existing Cloud DNS managed zone, without a trailing dot."
  }
}

variable "enable_runtime" {
  description = "False only for initial provisioning. Disabling an existing runtime destroys serving resources."
  type        = bool
  default     = false
}

variable "image" {
  description = "Immutable api image from this root's Artifact Registry repository. Required when runtime is enabled."
  type        = string
  default     = ""
  nullable    = false
  validation {
    condition     = var.image == "" || can(regex("^${var.region}-docker\\.pkg\\.dev/${var.project_id}/${var.name}/api@sha256:[a-f0-9]{64}$", var.image))
    error_message = "image must be empty or the repository's api image pinned to a lowercase sha256 digest."
  }
  validation {
    condition     = !var.enable_runtime || var.image != ""
    error_message = "Set a digest-pinned image before enabling runtime."
  }
}

variable "destroy_upload_bucket_contents" {
  description = "Allow the dedicated full-destroy workflow to remove all uploaded objects."
  type        = bool
  default     = false
}