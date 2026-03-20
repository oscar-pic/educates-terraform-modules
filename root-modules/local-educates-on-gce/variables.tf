###
# GCE Configuration for Local Educates
###

variable "project_id" {
  description = "GCP project"
  type        = string
}

variable "region" {
  description = "GCP region"
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

variable "dns_zone_name" {
  description = "Name of an existing Cloud DNS managed zone"
  type        = string
}

##
# Configuration for the Educates Installer
##
variable "deploy_educates" {
  description = "Whether to deploy/install Educates platform onto the VM"
  type        = bool
  default     = true
}

variable "educates_version" {
  description = "Educates version to use"
  type        = string
  default     = "3.3.2"
}

variable "TLD" {
  description = "Top Level Domain to use for services deployed in the cluster (cluster_name will be prepended for final wildcard_domain)"
  type        = string
}
