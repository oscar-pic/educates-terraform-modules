variable "proxmox_endpoint" {
  description = "Proxmox VE API URL, e.g. https://pve.example.com:8006/"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token, 'user@realm!token-id=secret'. Better passed as TF_VAR_proxmox_api_token than written in a file."
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification of the Proxmox API (self-signed certificate)."
  type        = bool
  default     = false
}

variable "cluster_name" {
  description = "Cluster name."
  type        = string
}

variable "proxmox" {
  description = "Proxmox placement settings. See infrastructure/proxmox-for-educates."
  type        = any
  default     = {}
}

variable "talos" {
  description = "Talos and Kubernetes versions. See infrastructure/proxmox-for-educates."
  type        = any
  default     = {}
}

variable "network" {
  description = "Primary network. See infrastructure/proxmox-for-educates."
  type        = any
}

variable "storage_network" {
  description = "Optional storage network. See infrastructure/proxmox-for-educates."
  type        = any
  default     = null
}

variable "nodes" {
  description = "Cluster nodes. See infrastructure/proxmox-for-educates."
  type        = any
}

variable "allow_scheduling_on_control_planes" {
  description = "Allow workloads on control-plane nodes. Defaults to true only without workers."
  type        = bool
  default     = null
}

variable "cilium" {
  description = "Cilium settings. See infrastructure/proxmox-for-educates."
  type        = any
  default     = {}
}

variable "gateway_api" {
  description = "Gateway API settings. See infrastructure/proxmox-for-educates."
  type        = any
  default     = {}
}

variable "load_balancer" {
  description = "LoadBalancer IP pools and interfaces. See infrastructure/proxmox-cluster-services."
  type        = any
}

variable "storage" {
  description = <<-EOT
    Storage backends: { default_class = "...", proxmox_csi = {...}, ceph_csi = {...}, nfs_csi = {...} }.
    See infrastructure/proxmox-cluster-services. Proxmox CSI defaults its url, insecure flag and region
    from proxmox_endpoint, proxmox_insecure and proxmox.region.
  EOT
  type        = any
}

variable "proxmox_csi_token_secret" {
  description = "Secret of the Proxmox CSI API token (TF_VAR_proxmox_csi_token_secret)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "ceph_csi_user_key" {
  description = "Ceph key of the CSI client (TF_VAR_ceph_csi_user_key)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "write_client_configs" {
  description = "Write kubeconfig and talosconfig files next to this root module."
  type        = bool
  default     = true
}
