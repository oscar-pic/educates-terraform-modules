locals {
  proxmox_csi = try(var.storage.proxmox_csi, {})
  ceph_csi    = try(var.storage.ceph_csi, {})
  ceph_rbd    = try(local.ceph_csi.enabled, false) && try(local.ceph_csi.rbd.enabled, true)
}

module "cluster" {
  source = "../../infrastructure/proxmox-for-educates"
  # source = "github.com/educates/educates-terraform-modules.git//infrastructure/proxmox-for-educates"

  providers = {
    proxmox = proxmox
    talos   = talos
    helm    = helm.template
  }

  cluster_name = var.cluster_name
  proxmox      = var.proxmox
  # RBD volumes need the rbd kernel module on every node.
  talos = merge(var.talos, {
    kernel_modules = distinct(concat(try(var.talos.kernel_modules, []), local.ceph_rbd ? ["rbd", "libceph"] : []))
  })
  network                            = var.network
  storage_network                    = var.storage_network
  nodes                              = var.nodes
  allow_scheduling_on_control_planes = var.allow_scheduling_on_control_planes
  cilium                             = var.cilium
  gateway_api                        = var.gateway_api
}

module "cluster_services" {
  source = "../../infrastructure/proxmox-cluster-services"
  # source = "github.com/educates/educates-terraform-modules.git//infrastructure/proxmox-cluster-services"

  node_count            = length(var.nodes)
  load_balancer         = var.load_balancer
  default_storage_class = var.storage.default_class

  proxmox_csi = merge(
    {
      url      = "${trimsuffix(var.proxmox_endpoint, "/")}/api2/json"
      insecure = var.proxmox_insecure
      region   = try(var.proxmox.region, "pve")
    },
    local.proxmox_csi,
  )
  proxmox_csi_token_secret = var.proxmox_csi_token_secret
  ceph_csi                 = local.ceph_csi
  ceph_csi_user_key        = var.ceph_csi_user_key
  nfs_csi                  = try(var.storage.nfs_csi, {})

  # Health check passed: API reachable, nodes Ready, Cilium running.
  depends_on = [module.cluster]
}

resource "local_sensitive_file" "kubeconfig" {
  count = var.write_client_configs ? 1 : 0

  content         = module.cluster.kubeconfig
  filename        = "${path.root}/kubeconfig-${var.cluster_name}.yaml"
  file_permission = "0600"
}

resource "local_sensitive_file" "talosconfig" {
  count = var.write_client_configs ? 1 : 0

  content         = module.cluster.talosconfig
  filename        = "${path.root}/talosconfig-${var.cluster_name}"
  file_permission = "0600"
}
