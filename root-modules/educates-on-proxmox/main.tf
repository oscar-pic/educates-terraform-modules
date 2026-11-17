locals {
  proxmox_csi = try(var.storage.proxmox_csi, {})
  ceph_csi    = try(var.storage.ceph_csi, {})
  ceph_rbd    = try(local.ceph_csi.enabled, false) && try(local.ceph_csi.rbd.enabled, true)
  ceph_fs     = try(local.ceph_csi.enabled, false) && try(local.ceph_csi.cephfs.enabled, false)
  # Kernel clients: RBD needs rbd (+ libceph), the CephFS kernel mounter needs ceph (+ libceph).
  ceph_kernel_modules = concat(local.ceph_rbd ? ["rbd", "libceph"] : [], local.ceph_fs ? ["ceph", "libceph"] : [])

  client_configs_dir = trimsuffix(coalesce(var.client_configs_dir, path.root), "/")
}

module "cluster" {
  source = "../../infrastructure/proxmox-for-educates"
  # source = "github.com/educates/educates-terraform-modules.git//infrastructure/proxmox-for-educates"

  providers = {
    proxmox       = proxmox
    talos         = talos
    helm.template = helm.template
    kubectl       = kubectl
  }

  cluster_name = var.cluster_name
  proxmox      = var.proxmox
  # Ceph volumes need their kernel modules on every node.
  talos = merge(var.talos, {
    kernel_modules = distinct(concat(try(var.talos.kernel_modules, []), local.ceph_kernel_modules))
  })
  network                            = var.network
  storage_network                    = var.storage_network
  nodes                              = var.nodes
  allow_scheduling_on_control_planes = var.allow_scheduling_on_control_planes
  cilium                             = var.cilium
  gateway_api                        = var.gateway_api

  # Cluster services: LoadBalancer IPs and storage.
  load_balancer         = var.load_balancer
  default_storage_class = var.storage.default_class
  proxmox_csi = merge(
    {
      url      = "${trimsuffix(var.proxmox_endpoint, "/")}/api2/json"
      insecure = var.proxmox_insecure
    },
    local.proxmox_csi,
  )
  proxmox_csi_token_secret = var.proxmox_csi_token_secret
  ceph_csi                 = local.ceph_csi
  ceph_csi_user_key        = var.ceph_csi_user_key
  ceph_csi_rbd_user_key    = var.ceph_csi_rbd_user_key
  ceph_csi_cephfs_user_key = var.ceph_csi_cephfs_user_key
  nfs_csi                  = try(var.storage.nfs_csi, {})

  educates_workshop_egress_fix = var.educates_workshop_egress_fix
}

resource "local_sensitive_file" "kubeconfig" {
  count = var.write_client_configs ? 1 : 0

  content         = module.cluster.kubeconfig
  filename        = "${local.client_configs_dir}/kubeconfig-${var.cluster_name}.yaml"
  file_permission = "0600"
}

resource "local_sensitive_file" "talosconfig" {
  count = var.write_client_configs ? 1 : 0

  content         = module.cluster.talosconfig
  filename        = "${local.client_configs_dir}/talosconfig-${var.cluster_name}"
  file_permission = "0600"
}
