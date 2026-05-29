variable "deployment_flavor" {
  type        = string
  description = "The type of deployment: 'single-node-k3s', 'rke2-cluster', or 'talos-cluster'"
  validation {
    condition     = contains(["single-node-k3s", "rke2-cluster", "talos-cluster"], var.deployment_flavor)
    error_message = "Flavor must be one of: single-node-k3s, rke2-cluster, talos-cluster."
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

variable "proxmox_ceph_clusterID" {
  description = "Ceph Cluster UUID (FSID) - ceph fsid command"
  type        = string
  default     = ""
}

variable "proxmox_ceph_k8s_key" {
  type        = string
  description = "The Ceph client.kubernetes authentication key encoded in base64."
  sensitive   = true
}

variable "proxmox_ceph_bridge" {
  type        = string
  default     = "vmbr1"
  description = "Bridge used in all Proxmox K8s VMs for Ceph Traffic"
}

variable "proxmox_ceph_storage_subnet" {
  type        = string
  description = "CIDR block for the Ceph storage network"
  default     = "10.10.60.0/24"
}

variable "k8s_ceph_storage_pods_ip_range" {
  type = object({
    start = string
    end   = string
  })
  description = "Dynamic Range for Storage Pods"
}

variable "k8s_ceph_storage_interface_name" {
  type        = string
  description = "The physical or bridge interface name on the k8s nodes"
  default     = "ens19"
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

variable "proxmox_images_snippets_datastore" {
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
    # If flavor is NOT single-node-k3s, shared MUST be true.
    condition     = var.deployment_flavor == "single-node-k3s" || var.proxmox_vms_datastore.shared == true
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

variable "k8s_api_cp_interface" {
  description = "Optional Name Interface VIP/LB IP. If empty, the code picks a control-plane node."
  type        = string
  default     = "eth0"
}

variable "k8s_cluster_token" {
  type        = string
  description = "Secrec Shared Token to nodes join to RKE2 Cluster"
  default     = "secret-educates-token-123456"
  sensitive   = true
}

variable "system_timezone" {
  type        = string
  description = "The system timezone for the deployed nodes"
  default     = "Europe/Madrid"
}

variable "kube_nodes" {
  description = "Unified node configuration"
  type = map(object({
    type            = string 
    proxmox_host    = number
    mac_address     = optional (string, "")
    ip_address      = string
    gateway         = string
    dns_servers     = optional(list(string), ["8.8.8.8, 1.1.1.1"]) # Default if not specified
    network_bridge  = optional(string, "vmbr0")
    vm_user         = optional(string, "ubuntu")           # Default here
    vm_password     = optional(string, "Ubuntu1!") # Default here
    ssh_key_path    = optional(string, "~/.ssh/id_ed25519.pub") # Default here
    vm_cores        = optional(number, 4)
    vm_memory       = optional(number, 8192)
    vm_disk_size    = optional(number, 30)
    
    config_patches  = optional(list(string), [])
  }))
}

###############################################################################
# ARCHITECTURAL GUARDRAILS & VALIDATIONS
###############################################################################

resource "null_resource" "validate_rke2_ha_requirements" {
  # This lifecycle precondition enforces deployment standards before touching Proxmox.
  # It evaluates cluster node topology against the presence of an API Virtual IP.
  lifecycle {
    precondition {
      condition = !(
        var.deployment_flavor == "rke2-cluster" && 
        length([for k, v in var.kube_nodes : k if v.type == "rke2-server" || v.type == "rke2-server-bootstrap"]) > 1 && 
        var.k8s_api_endpoint_vip == ""
      )
      error_message = <<EOF
CRITICAL ARCHITECTURE ERROR:
The deployment flavor is set to 'rke2-cluster' with multiple Control Plane (master) nodes,
but the 'k8s_api_endpoint_vip' variable is empty.

To guarantee High Availability (HA) and allow downstream joiner nodes to register 
securely via a unified control plane entry point, you MUST define a valid Virtual IP (VIP)
inside your .tfvars configuration file.
EOF
    }
  }
}