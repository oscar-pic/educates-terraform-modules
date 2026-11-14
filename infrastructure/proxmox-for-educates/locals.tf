locals {
  cp_nodes     = { for k, n in var.nodes : k => n if n.role == "controlplane" }
  worker_nodes = { for k, n in var.nodes : k => n if n.role == "worker" }

  cp_ips     = [for k in sort(keys(local.cp_nodes)) : local.cp_nodes[k].ip]
  worker_ips = [for k in sort(keys(local.worker_nodes)) : local.worker_nodes[k].ip]

  # The first control-plane node (alphabetical key) bootstraps etcd.
  bootstrap_key = sort(keys(local.cp_nodes))[0]
  bootstrap_ip  = local.cp_nodes[local.bootstrap_key].ip

  api_vip          = var.network.api_vip == null ? "" : var.network.api_vip
  api_host         = local.api_vip != "" ? local.api_vip : local.bootstrap_ip
  cluster_endpoint = "https://${local.api_host}:6443"

  network_prefix = split("/", var.network.cidr)[1]
  storage_prefix = var.storage_network == null ? "" : split("/", var.storage_network.cidr)[1]

  hostnames = { for k, _ in var.nodes : k => "${var.cluster_name}-${k}" }

  schedulable_control_planes = (
    var.allow_scheduling_on_control_planes != null
    ? var.allow_scheduling_on_control_planes
    : length(local.worker_nodes) == 0
  )

  kubernetes_version = trimprefix(var.talos.kubernetes_version, "v")

  guest_agent_enabled = contains(var.talos.extensions, "siderolabs/qemu-guest-agent")

  # Proxmox nodes that need their own copy of the Talos image.
  proxmox_nodes = sort(distinct([for n in values(var.nodes) : n.proxmox_node]))
  image_nodes   = var.proxmox.image_datastore_shared ? [local.proxmox_nodes[0]] : local.proxmox_nodes

  gateway_api_crds_url = coalesce(
    var.gateway_api.crds_url,
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api.version}/standard-install.yaml",
  )
}

# Cluster services
locals {
  replicas = min(2, length(var.nodes))

  proxmox_csi_classes = var.proxmox_csi.enabled ? [for c in var.proxmox_csi.storage_classes : c.name] : []
  ceph_rbd_enabled    = var.ceph_csi.enabled && var.ceph_csi.rbd.enabled
  ceph_fs_enabled     = var.ceph_csi.enabled && var.ceph_csi.cephfs.enabled

  storage_classes = concat(
    local.proxmox_csi_classes,
    local.ceph_rbd_enabled ? [var.ceph_csi.rbd.storage_class] : [],
    local.ceph_fs_enabled ? [var.ceph_csi.cephfs.storage_class] : [],
    var.nfs_csi.enabled ? [var.nfs_csi.storage_class] : [],
  )

  default_annotation = { for name in local.storage_classes : name => {
    "storageclass.kubernetes.io/is-default-class" = tostring(name == var.default_storage_class)
  } }

  # CSI node plugins mount host paths and run privileged.
  privileged_namespaces = toset(compact([
    var.proxmox_csi.enabled ? "csi-proxmox" : "",
    local.ceph_rbd_enabled ? "ceph-csi-rbd" : "",
    local.ceph_fs_enabled ? "ceph-csi-cephfs" : "",
    var.nfs_csi.enabled ? "csi-nfs" : "",
  ]))

  ceph_csi_config = [{
    clusterID = var.ceph_csi.cluster_id
    monitors  = var.ceph_csi.monitors
    cephFS    = { subvolumeGroup = var.ceph_csi.cephfs.subvolume_group }
  }]
}
