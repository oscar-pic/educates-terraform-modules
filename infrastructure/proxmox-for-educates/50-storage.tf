resource "kubectl_manifest" "namespace" {
  for_each = local.privileged_namespaces

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = each.key
      labels = {
        "pod-security.kubernetes.io/enforce" = "privileged"
        "pod-security.kubernetes.io/audit"   = "privileged"
        "pod-security.kubernetes.io/warn"    = "privileged"
      }
    }
  })

  # Talk to the cluster only once it passed the health check.
  depends_on = [data.talos_cluster_health.this]
}

###############################################################################
# Proxmox CSI
###############################################################################

# Proxmox API credentials for the plugin, kept out of the Helm release values.
resource "kubectl_manifest" "proxmox_csi_config" {
  count = var.proxmox_csi.enabled ? 1 : 0

  sensitive_fields = ["stringData"]
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata   = { name = "proxmox-csi-config", namespace = "csi-proxmox" }
    stringData = {
      "config.yaml" = yamlencode({
        clusters = [{
          url          = var.proxmox_csi.url
          insecure     = var.proxmox_csi.insecure
          token_id     = var.proxmox_csi.token_id
          token_secret = var.proxmox_csi_token_secret
          region       = var.proxmox.region # matches the topology.kubernetes.io/region node label
        }]
      })
    }
  })

  depends_on = [kubectl_manifest.namespace]
}

resource "helm_release" "proxmox_csi" {
  count = var.proxmox_csi.enabled ? 1 : 0

  name       = "proxmox-csi-plugin"
  namespace  = "csi-proxmox"
  repository = "oci://ghcr.io/sergelogvinov/charts"
  chart      = "proxmox-csi-plugin"
  version    = var.proxmox_csi.version

  values = [yamlencode({
    existingConfigSecret    = "proxmox-csi-config"
    existingConfigSecretKey = "config.yaml"
    storageClass = [for c in var.proxmox_csi.storage_classes : merge(
      {
        name          = c.name
        storage       = c.datastore
        fstype        = c.fstype
        ssd           = c.ssd
        reclaimPolicy = c.reclaim_policy
        annotations   = local.default_annotation[c.name]
      },
      c.cache == null ? {} : { cache = c.cache },
    )]
  })]

  depends_on = [kubectl_manifest.proxmox_csi_config]

  lifecycle {
    precondition {
      condition     = var.proxmox_csi.url != "" && var.proxmox_csi.token_id != "" && var.proxmox_csi_token_secret != "" && length(var.proxmox_csi.storage_classes) > 0
      error_message = "proxmox_csi needs url, token_id, proxmox_csi_token_secret and at least one storage class."
    }
  }
}

###############################################################################
# Ceph CSI (RBD and CephFS, one namespace each: the charts share ConfigMap names)
###############################################################################

resource "helm_release" "ceph_rbd" {
  count = local.ceph_rbd_enabled ? 1 : 0

  name       = "ceph-csi-rbd"
  namespace  = "ceph-csi-rbd"
  repository = "https://ceph.github.io/csi-charts"
  chart      = "ceph-csi-rbd"
  version    = var.ceph_csi.version

  values = [yamlencode({
    csiConfig   = local.ceph_csi_config
    provisioner = { replicaCount = local.replicas }
    secret      = { create = true, userID = var.ceph_csi.user_id }
    storageClass = {
      create      = true
      name        = var.ceph_csi.rbd.storage_class
      clusterID   = var.ceph_csi.cluster_id
      pool        = var.ceph_csi.rbd.pool
      annotations = local.default_annotation[var.ceph_csi.rbd.storage_class]
    }
  })]

  set_sensitive = [{
    name  = "secret.userKey"
    value = var.ceph_csi_user_key
  }]

  depends_on = [kubectl_manifest.namespace]

  lifecycle {
    precondition {
      condition     = var.ceph_csi.cluster_id != "" && length(var.ceph_csi.monitors) > 0 && var.ceph_csi_user_key != ""
      error_message = "ceph_csi needs cluster_id, monitors and ceph_csi_user_key."
    }
  }
}

resource "helm_release" "ceph_fs" {
  count = local.ceph_fs_enabled ? 1 : 0

  name       = "ceph-csi-cephfs"
  namespace  = "ceph-csi-cephfs"
  repository = "https://ceph.github.io/csi-charts"
  chart      = "ceph-csi-cephfs"
  version    = var.ceph_csi.version

  values = [yamlencode({
    csiConfig   = local.ceph_csi_config
    provisioner = { replicaCount = local.replicas }
    secret      = { create = true, userID = var.ceph_csi.user_id }
    storageClass = {
      create      = true
      name        = var.ceph_csi.cephfs.storage_class
      clusterID   = var.ceph_csi.cluster_id
      fsName      = var.ceph_csi.cephfs.fs_name
      annotations = local.default_annotation[var.ceph_csi.cephfs.storage_class]
    }
  })]

  set_sensitive = [{
    name  = "secret.userKey"
    value = var.ceph_csi_user_key
  }]

  depends_on = [kubectl_manifest.namespace]

  lifecycle {
    precondition {
      condition     = var.ceph_csi.cluster_id != "" && length(var.ceph_csi.monitors) > 0 && var.ceph_csi_user_key != ""
      error_message = "ceph_csi needs cluster_id, monitors and ceph_csi_user_key."
    }
  }
}

###############################################################################
# NFS CSI
###############################################################################

resource "helm_release" "nfs" {
  count = var.nfs_csi.enabled ? 1 : 0

  name       = "csi-driver-nfs"
  namespace  = "csi-nfs"
  repository = "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts"
  chart      = "csi-driver-nfs"
  version    = var.nfs_csi.version

  values = [yamlencode({
    controller = { replicas = local.replicas }
    storageClass = {
      create            = true
      name              = var.nfs_csi.storage_class
      annotations       = local.default_annotation[var.nfs_csi.storage_class]
      parameters        = { server = var.nfs_csi.server, share = var.nfs_csi.share }
      reclaimPolicy     = "Delete"
      volumeBindingMode = "Immediate"
      mountOptions      = var.nfs_csi.mount_options
    }
  })]

  depends_on = [kubectl_manifest.namespace]

  lifecycle {
    precondition {
      condition     = var.nfs_csi.server != ""
      error_message = "nfs_csi needs server."
    }
  }
}

###############################################################################
# Exactly one default StorageClass
###############################################################################

resource "terraform_data" "default_storage_class_check" {
  input = var.default_storage_class

  lifecycle {
    precondition {
      condition     = contains(local.storage_classes, var.default_storage_class)
      error_message = "default_storage_class '${var.default_storage_class}' is not one of the enabled classes: ${join(", ", local.storage_classes)}."
    }
  }
}
