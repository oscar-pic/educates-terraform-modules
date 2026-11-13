locals {
  replicas = min(2, max(1, var.node_count))

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
