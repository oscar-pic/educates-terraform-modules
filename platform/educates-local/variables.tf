variable "educates_version" {
  description = "Version of the educates CLI to install"
  type        = string
  default     = "3.3.2"
}

variable "cluster_name" {
  description = "Name for the Kind cluster"
  type        = string
}

variable "wildcard_domain" {
  description = "Wildcard domain for educates ingress (e.g. cluster-name.example.com)"
  type        = string
}

variable "ssh_connection" {
  description = "SSH connection details to the GCE VM"
  type = object({
    host        = string
    user        = string
    private_key = string
  })
  sensitive = true
}

variable "gcp_project" {
  description = "GCP project ID"
  type        = string
}

variable "dns_zone" {
  description = "Cloud DNS zone domain"
  type        = string
}
