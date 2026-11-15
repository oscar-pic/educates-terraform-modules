variable "cluster_name" {
  description = "Cluster name. Used for the Talos/Kubernetes cluster, as a prefix for VM names and as a Proxmox tag."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$", var.cluster_name))
    error_message = "cluster_name must be 1-32 lowercase letters, digits or hyphens, starting and ending with a letter or digit."
  }
}

variable "proxmox" {
  description = <<-EOT
    Proxmox VE placement settings.
    - region: name of the Proxmox cluster, published as the topology.kubernetes.io/region node label (used by Proxmox CSI).
    - vm_datastore: datastore for VM disks, EFI disks and cloud-init drives.
    - image_datastore: datastore for the Talos disk image. It must allow the 'import' content type (PVE >= 8.4).
    - image_datastore_shared: true if image_datastore is shared by all Proxmox nodes (the image is then downloaded once).
    - image_download_node: with a shared image datastore, the Proxmox node that downloads the image (it needs
      Sys.AccessNetwork). Defaults to the first, alphabetically, of the nodes that host VMs, which changes
      when the topology does; set it to keep one node and avoid a new download.
    - cpu_type: QEMU CPU type. 'host' gives the best performance but blocks live migration between different CPUs.
    - ha_enabled: register the VMs as Proxmox HA resources. Needs a Proxmox cluster and shared VM storage.
    - tags: extra Proxmox tags for every VM.
    - default_tags: also tag every VM with "talos", the cluster name and its role (default true).
      Proxmox checks tags on VM creation against /vms/<id> only, ignoring privileges on the pool: with
      VM privileges granted only on the pool, set default_tags = false and tags = [] (no tags at all).
    - pool: Proxmox resource pool for the cluster's VMs (optional), for example "educates" or, nested
      (PVE 8.1+), "lab/educates". By default it is an existing pool, created and kept by whoever runs
      Proxmox: the module puts its VMs in it and never creates, changes or deletes it.
    - create_pool: create the pool instead (the last level only) and delete it on destroy. It must not
      exist yet, and the levels above it must exist. Proxmox only deletes an empty pool, so VMs that
      others put in it are never touched; they make the destroy stop at the pool.
      scripts/preflight.sh checks either case.
  EOT
  type = object({
    region                 = optional(string, "pve")
    vm_datastore           = optional(string, "local-lvm")
    image_datastore        = optional(string, "local")
    image_datastore_shared = optional(bool, false)
    image_download_node    = optional(string)
    cpu_type               = optional(string, "x86-64-v2-AES")
    ha_enabled             = optional(bool, false)
    tags                   = optional(list(string), [])
    default_tags           = optional(bool, true)
    pool                   = optional(string)
    create_pool            = optional(bool, false)
  })
  default = {}

  validation {
    condition     = !var.proxmox.create_pool || var.proxmox.pool != null
    error_message = "proxmox.create_pool needs proxmox.pool (the pool to create)."
  }

  validation {
    condition     = var.proxmox.pool == null || can(regex("^[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*$", var.proxmox.pool))
    error_message = "proxmox.pool must be a pool ID such as \"educates\" or, nested, \"lab/educates\" (letters, digits, - and _)."
  }
}

variable "talos" {
  description = <<-EOT
    Talos and Kubernetes versions.
    - version: Talos version of the disk image. Upgrading a running node is done with talosctl (see docs/operations.md);
      bumping this value afterwards only replaces the downloaded image, never the VMs.
    - config_contract: Talos machine-config contract. Keep it fixed at the value used when the cluster was created.
      Changing it regenerates every node's configuration.
    - kubernetes_version: changing it on a running cluster runs Talos's upgrade-k8s procedure.
    - extensions: official Talos system extensions baked into the image.
    - extra_kernel_args: extra kernel arguments baked into the image.
    - ntp_servers: NTP servers. Empty keeps the Talos default.
    - kernel_modules: kernel modules to load at boot (e.g. ["rbd", "libceph"] for Ceph RBD volumes).
  EOT
  type = object({
    version            = optional(string, "v1.14.6")
    config_contract    = optional(string, "v1.14")
    kubernetes_version = optional(string, "1.37.2")
    extensions         = optional(list(string), ["siderolabs/qemu-guest-agent"])
    extra_kernel_args  = optional(list(string), [])
    ntp_servers        = optional(list(string), [])
    kernel_modules     = optional(list(string), [])
  })
  default = {}
}

variable "network" {
  description = <<-EOT
    Primary (node and Kubernetes API) network.
    - cidr: subnet of the node IPs, e.g. 192.168.10.0/24. Its prefix length is applied to every node IP.
    - api_vip: free IP in that subnet, shared by the control-plane nodes for the Kubernetes API.
      Required with more than one control-plane node.
    - interface: name of the NIC inside Talos (eth0 for the first virtio NIC).
    - mtu: MTU of the VM NIC. 1 inherits the bridge MTU: use it on SDN VXLAN/EVPN VNets (MTU 1450 by
      default), or the nodes send packets the VNet drops. Unset: the Proxmox default (1500).
  EOT
  type = object({
    cidr        = string
    gateway     = string
    bridge      = optional(string, "vmbr0")
    vlan_id     = optional(number)
    dns_servers = optional(list(string), ["1.1.1.1", "8.8.8.8"])
    api_vip     = optional(string)
    interface   = optional(string, "eth0")
    mtu         = optional(number)
  })

  validation {
    condition     = can(cidrhost(var.network.cidr, 0))
    error_message = "network.cidr must be a valid IPv4 CIDR, e.g. 192.168.10.0/24."
  }
}

variable "storage_network" {
  description = "Optional second NIC for a dedicated storage network (Ceph, NFS). Each node then needs storage_ip."
  type = object({
    cidr      = string
    bridge    = string
    vlan_id   = optional(number)
    mtu       = optional(number, 1) # 1 = inherit the bridge MTU (set 9000 only if the bridge has it)
    interface = optional(string, "eth1")
  })
  default = null
}

variable "nodes" {
  description = <<-EOT
    Cluster nodes, keyed by a short name (the VM and Kubernetes node name become <cluster_name>-<key>).
    - role: controlplane or worker. The first control-plane key in alphabetical order bootstraps etcd.
    - proxmox_node: Proxmox node that hosts the VM.
    - ip: node IP inside network.cidr, without prefix length.
    - storage_ip: IP inside storage_network.cidr, required when storage_network is set.
    - memory in MiB, disk_size in GiB.
    - labels: extra Kubernetes node labels (node-role.kubernetes.io/* is not allowed).
  EOT
  type = map(object({
    role         = string
    proxmox_node = string
    ip           = string
    storage_ip   = optional(string)
    vm_id        = optional(number)
    mac_address  = optional(string)
    cpu          = optional(number, 4)
    memory       = optional(number, 8192)
    disk_size    = optional(number, 40)
    labels       = optional(map(string), {})
  }))

  validation {
    condition     = alltrue([for n in values(var.nodes) : contains(["controlplane", "worker"], n.role)])
    error_message = "Each node role must be 'controlplane' or 'worker'."
  }

  validation {
    condition     = length([for n in values(var.nodes) : n if n.role == "controlplane"]) % 2 == 1
    error_message = "Use an odd number of control-plane nodes (1, 3 or 5) so etcd keeps quorum."
  }

  validation {
    condition     = alltrue([for n in values(var.nodes) : can(regex("^\\d{1,3}(\\.\\d{1,3}){3}$", n.ip))])
    error_message = "Node ip must be a plain IPv4 address without prefix length."
  }

  validation {
    condition = alltrue(flatten([
      for n in values(var.nodes) : [for k in keys(n.labels) : !startswith(k, "node-role.kubernetes.io/")]
    ]))
    error_message = "Nodes cannot set node-role.kubernetes.io/* labels on themselves (NodeRestriction). Use another key."
  }
}

variable "allow_scheduling_on_control_planes" {
  description = "Allow workloads on control-plane nodes. Defaults to true only when there are no worker nodes."
  type        = bool
  default     = null
}

variable "cilium" {
  description = "Cilium CNI (installed as a Talos inline manifest, kube-proxy replacement, L2 LoadBalancer announcements)."
  type = object({
    version        = optional(string, "1.20.4")
    hubble_enabled = optional(bool, false)
    extra_values   = optional(string, "")
  })
  default = {}
}

variable "gateway_api" {
  description = <<-EOT
    Gateway API support. Installs the standard-channel CRDs (as a Talos external manifest) and enables Cilium's Gateway API controller.
    crds_url can point to a mirror for air-gapped installs.
  EOT
  type = object({
    enabled  = optional(bool, false)
    version  = optional(string, "v1.6.3")
    crds_url = optional(string)
  })
  default = {}
}

variable "extra_config_patches" {
  description = "Extra Talos config patches (YAML strings), applied after the module's own patches."
  type = object({
    all          = optional(list(string), [])
    controlplane = optional(list(string), [])
    worker       = optional(list(string), [])
  })
  default = {}
}

variable "health_check_timeout" {
  description = "How long the final cluster health check waits."
  type        = string
  default     = "20m"
}

###############################################################################
# Cluster services: LoadBalancer IPs and storage. Applied once the cluster is healthy.
###############################################################################

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
    - storage_classes: one StorageClass per Proxmox datastore.
  EOT
  type = object({
    enabled  = optional(bool, false)
    version  = optional(string, "0.5.15")
    url      = optional(string, "")
    insecure = optional(bool, false)
    token_id = optional(string, "")
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
    - version: ceph-csi chart and images. 3.18 and later need x86-64-v3 CPUs (AVX2): with
      x86-64-v2 hosts or proxmox.cpu_type, use 3.17.x (for example "3.17.2").
    - user_id: Ceph client without the 'client.' prefix, for both drivers. Its key goes in
      ceph_csi_user_key. rbd.user_id and cephfs.user_id override it, each with its own key.
    - rbd: RWO block volumes from an RBD pool, optionally in a RADOS namespace (rados_namespace).
      Needs the 'rbd' kernel module on the nodes.
    - cephfs: RWX volumes from a CephFS file system, in a subvolume group, optionally with their
      data in a dedicated data pool (data_pool) added to the file system. Needs the 'ceph' kernel module.
  EOT
  type = object({
    enabled    = optional(bool, false)
    version    = optional(string, "3.17.2")
    cluster_id = optional(string, "")
    monitors   = optional(list(string), [])
    user_id    = optional(string, "kubernetes")
    rbd = optional(object({
      enabled         = optional(bool, true)
      pool            = optional(string, "kubernetes")
      rados_namespace = optional(string, "")
      user_id         = optional(string)
      storage_class   = optional(string, "ceph-rbd")
    }), {})
    cephfs = optional(object({
      enabled         = optional(bool, false)
      fs_name         = optional(string, "cephfs")
      subvolume_group = optional(string, "csi")
      data_pool       = optional(string, "")
      user_id         = optional(string)
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

variable "ceph_csi_rbd_user_key" {
  description = "Key of ceph_csi.rbd.user_id, when RBD has its own Ceph client. Defaults to ceph_csi_user_key."
  type        = string
  default     = ""
  sensitive   = true
}

variable "ceph_csi_cephfs_user_key" {
  description = "Key of ceph_csi.cephfs.user_id, when CephFS has its own Ceph client. Defaults to ceph_csi_user_key."
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

variable "educates_workshop_egress_fix" {
  description = <<-EOT
    Add a Cilium policy that lets Educates workshop pods reach cluster DNS, services and the
    Kubernetes API. Without it, the egress NetworkPolicy that Educates puts in workshop
    namespaces blocks that traffic on Cilium (see 45-educates-compat.tf). Temporary: turn it
    off once Educates handles Cilium.
  EOT
  type        = bool
  default     = true
}
