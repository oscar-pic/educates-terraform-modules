###
# GCE (Google Compute Engine) Configuration for Local Educates
###

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region where this instance will be created"
  type        = string
}

variable "zone" {
  description = "GCP zone for the compute instance. Defaults to first zone in the region"
  type        = string
  default     = ""
}

variable "cluster_name" {
  description = "Name used for resources and DNS records"
  type        = string
}

variable "machine_type" {
  description = "GCE machine type for the compute instance"
  type        = string
  default     = "e2-standard-4"
}

variable "disk_size_gb" {
  description = "Boot disk size in GB"
  type        = number
  default     = 100
}

variable "disk_type" {
  description = "Boot disk type"
  type        = string
  default     = "pd-balanced"
}

variable "image_family" {
  description = "OS image family for the compute instance"
  type        = string
  default     = "ubuntu-2204-lts"
}

variable "image_project" {
  description = "GCP project hosting the OS image"
  type        = string
  default     = "ubuntu-os-cloud"
}

variable "dns_zone_name" {
  description = "Name of an existing Cloud DNS managed zone"
  type        = string
}

variable "TLD" {
  description = "Top-level domain for DNS records (e.g. educates.example.com)"
  type        = string
}

variable "ssh_user" {
  description = "SSH username for the compute instance"
  type        = string
  default     = "educates"
}
