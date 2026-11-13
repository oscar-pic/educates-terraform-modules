variable "node_count" {
  description = "Number of Kubernetes nodes. Caps controller replicas (one per node)."
  type        = number
  default     = 1
}

variable "load_balancer" {
  description = <<-EOT
    LoadBalancer IPs announced by Cilium on the node network (ARP).
    - ip_pools: CIDRs ("192.168.10.200/29") or ranges ("192.168.10.200-192.168.10.210"), free in the node network.
    - interfaces: regular expressions of the node interfaces that answer ARP.
  EOT
  type = object({
    ip_pools   = list(string)
    interfaces = optional(list(string), ["^eth0$"])
  })

  validation {
    condition     = length(var.load_balancer.ip_pools) > 0
    error_message = "load_balancer.ip_pools needs at least one CIDR or range."
  }
}

variable "default_storage_class" {
  description = "Name of the StorageClass marked as cluster default (Educates needs a default RWO class)."
  type        = string
}

variable "proxmox_csi" {
  description = <<-EOT
    Proxmox CSI (https://github.com/sergelogvinov/proxmox-csi-plugin): RWO volumes created as Proxmox disks and hot-plugged into the VMs.
    - url: Proxmox API URL ending in /api2/json.
    - token_id: API token of a user with the CSI role (see the README). Its secret goes in proxmox_csi_token_secret.
    - region: must match the topology.kubernetes.io/region node label (proxmox.region of the cluster module).
    - storage_classes: one StorageClass per Proxmox datastore.
  EOT
  type = object({
    enabled  = optional(bool, false)
    version  = optional(string, "0.5.15")
    url      = optional(string, "")
    insecure = optional(bool, false)
    token_id = optional(string, "")
    region   = optional(string, "pve")
    storage_classes = optional(list(object({
      name           = string
      datastore      = string
      fstype         = optional(string, "ext4")
      ssd            = optional(bool, true)
      cache          = optional(string)
      reclaim_policy = optional(string, "Delete")
    })), [])
  })
  default = {}
}

variable "proxmox_csi_token_secret" {
  description = "Secret of the Proxmox CSI API token."
  type        = string
  default     = ""
  sensitive   = true
}

variable "ceph_csi" {
  description = <<-EOT
    Ceph CSI against an existing Ceph cluster (for example the one of Proxmox).
    - cluster_id: Ceph FSID ('ceph fsid').
    - monitors: monitor addresses ("10.10.10.1:6789").
    - user_id: Ceph client without the 'client.' prefix. Its key goes in ceph_csi_user_key.
    - rbd: RWO block volumes from an RBD pool. Needs the 'rbd' kernel module on the nodes.
    - cephfs: RWX volumes from a CephFS file system.
  EOT
  type = object({
    enabled    = optional(bool, false)
    version    = optional(string, "3.18.2")
    cluster_id = optional(string, "")
    monitors   = optional(list(string), [])
    user_id    = optional(string, "kubernetes")
    rbd = optional(object({
      enabled       = optional(bool, true)
      pool          = optional(string, "kubernetes")
      storage_class = optional(string, "ceph-rbd")
    }), {})
    cephfs = optional(object({
      enabled         = optional(bool, false)
      fs_name         = optional(string, "cephfs")
      subvolume_group = optional(string, "csi")
      storage_class   = optional(string, "cephfs")
    }), {})
  })
  default = {}
}

variable "ceph_csi_user_key" {
  description = "Ceph auth key of ceph_csi.user_id ('ceph auth get-key client.<user_id>')."
  type        = string
  default     = ""
  sensitive   = true
}

variable "nfs_csi" {
  description = "NFS CSI (csi-driver-nfs) on an existing NFS export: one subdirectory per volume, RWX."
  type = object({
    enabled       = optional(bool, false)
    version       = optional(string, "4.13.6")
    server        = optional(string, "")
    share         = optional(string, "/")
    mount_options = optional(list(string), ["nfsvers=4.1"])
    storage_class = optional(string, "nfs")
  })
  default = {}
}
