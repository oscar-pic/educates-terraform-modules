variable "deployment_flavor" {
  type        = string
  description = "The type of deployment: 'single-node', 'rke2-cluster', or 'talos-cluster'"
  validation {
    condition     = contains(["single-node", "rke2-cluster", "talos-cluster"], var.deployment_flavor)
    error_message = "Flavor must be one of: single-node, rke2-cluster, talos-cluster."
  }
}

variable "proxmox_endpoint" { 
  type    = string
  default = "https://192.168.1.28:8006" 
}

variable "proxmox_api_token" {
  type      = string
  sensitive = true # This hides the token in your logs
}

variable "proxmox_nodes" {
  type    = list(string)
  default = ["proxmox-server"]
}

variable "ssh_private_key_path" {
  description = "Path to the SSH private key to connect to Proxmox"
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "proxmox_image_datastore" {
  description = "Storage for ISOs and Snippets (ej: local)"
  type = object({
    name   = string
    shared = bool
  })
  default = {
    name   = "local"
    shared = false
  }
}

variable "proxmox_vms_datastore" {
  description = "Storage for VMs Disks (ej: data-vms)"
  type = object({
    name   = string
    shared = bool
  })
  validation {
    # If flavor is NOT single-node, shared MUST be true.
    condition     = var.deployment_flavor == "single-node" || var.proxmox_vms_datastore.shared == true
    error_message = "CRITICAL: For cluster deployments, the VM datastore MUST be shared (NFS/Ceph) to ensure HA and data persistence across nodes."
  }
}

variable "cloud_image_url" {
  type    = string
  default = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "proxmox_image_filename" {
  description = "The name of the file as it will appear in the Proxmox storage"
  type        = string
  default     = "ubuntu-24.04-cloud.img"
}

variable "k8s_api_endpoint_vip" {
  description = "Optional VIP/LB IP. If empty, the code picks a control-plane node."
  type        = string
  default     = ""
}

variable "kube_nodes" {
  description = "Unified node configuration"
  type = map(object({
    type           = string 
    proxmox_host   = number
    mac_address    = optional (string, "")
    ip_address     = string
    gateway        = string
    dns_servers    = optional(list(string), ["8.8.8.8, 1.1.1.1"]) # Default if not specified
    vm_user        = optional(string, "ubuntu")           # Default here
    vm_password    = optional(string, "Ubuntu1!") # Default here
    ssh_key_path   = optional(string, "~/.ssh/id_ed25519.pub") # Default here
    vm_cores       = optional(number, 4)
    vm_memory      = optional(number, 8192)
    vm_disk_size   = optional(number, 30)
    network_bridge = optional(string, "vmbr0")
    config_patches = optional(list(string), [])
  }))
}

variable "kapp_controller_version" {
  description = "Version of kapp-controller to install"
  type        = string
  default     = "v0.59.7"
}

variable "educates_version" {
  description = "Version of Educates training platform to install"
  type        = string
  default     = "3.7.1"
}

variable "educates_portal_domain" {
  description = "The base domain for Educates (e.g., lab.inet)"
  type        = string
  default = "educates.lab.inet"
}

variable "educates_portal_hostname" {
  type        = string
  description = "Subdominio específico para el portal (ej: educates)"
  default     = "educates"
}