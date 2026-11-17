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
# Storage drivers
#
# Each chart is rendered with helm_template (no cluster access, like Cilium) and
# every object is applied with its own kubectl_manifest. The kubectl provider
# retries (apply_retry_count), so a short API outage right after bootstrap, for
# example etcd on slow shared storage, does not fail the apply. A Helm release
# interrupted halfway would stay "pending-install" and block every later apply.
#
# Secrets (Proxmox token, Ceph keys) never go into the chart values: they are
# separate Secrets, so the rendered manifests carry nothing sensitive.
###############################################################################

# Proxmox API credentials for the plugin.
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

# Ceph client keys, under the names the charts' StorageClasses refer to.
locals {
  ceph_secrets = {
    rbd    = { enabled = local.ceph_rbd_enabled, name = "csi-rbd-secret", namespace = "ceph-csi-rbd", user_id = local.ceph_rbd_user_id }
    cephfs = { enabled = local.ceph_fs_enabled, name = "csi-cephfs-secret", namespace = "ceph-csi-cephfs", user_id = local.ceph_fs_user_id }
  }
  ceph_secret_keys = { rbd = local.ceph_rbd_user_key, cephfs = local.ceph_fs_user_key }
}

resource "kubectl_manifest" "ceph_secret" {
  for_each = toset([for k, v in local.ceph_secrets : k if v.enabled])

  sensitive_fields = ["stringData"]
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata   = { name = local.ceph_secrets[each.key].name, namespace = local.ceph_secrets[each.key].namespace }
    stringData = { userID = local.ceph_secrets[each.key].user_id, userKey = local.ceph_secret_keys[each.key] }
  })

  depends_on = [kubectl_manifest.namespace]
}

data "helm_template" "proxmox_csi" {
  count    = var.proxmox_csi.enabled ? 1 : 0
  provider = helm.template

  name         = "proxmox-csi-plugin"
  namespace    = "csi-proxmox"
  repository   = "oci://ghcr.io/sergelogvinov/charts"
  chart        = "proxmox-csi-plugin"
  version      = var.proxmox_csi.version
  kube_version = local.kubernetes_version

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

  lifecycle {
    precondition {
      condition     = var.proxmox_csi.url != "" && var.proxmox_csi.token_id != "" && var.proxmox_csi_token_secret != "" && length(var.proxmox_csi.storage_classes) > 0
      error_message = "proxmox_csi needs url, token_id, proxmox_csi_token_secret and at least one storage class."
    }
  }
}

# Ceph CSI: RBD and CephFS, one namespace each (the charts share ConfigMap names).
data "helm_template" "ceph_rbd" {
  count    = local.ceph_rbd_enabled ? 1 : 0
  provider = helm.template

  name         = "ceph-csi-rbd"
  namespace    = "ceph-csi-rbd"
  repository   = "https://ceph.github.io/csi-charts"
  chart        = "ceph-csi-rbd"
  version      = var.ceph_csi.version
  kube_version = local.kubernetes_version

  values = [yamlencode({
    csiConfig   = local.ceph_csi_config
    provisioner = { replicaCount = local.replicas }
    secret      = { create = false } # kubectl_manifest.ceph_secret
    storageClass = {
      create      = true
      name        = var.ceph_csi.rbd.storage_class
      clusterID   = var.ceph_csi.cluster_id
      pool        = var.ceph_csi.rbd.pool
      annotations = local.default_annotation[var.ceph_csi.rbd.storage_class]
    }
  })]

  lifecycle {
    precondition {
      condition     = var.ceph_csi.cluster_id != "" && length(var.ceph_csi.monitors) > 0 && local.ceph_rbd_user_key != ""
      error_message = "ceph_csi RBD needs cluster_id, monitors and a key (ceph_csi_rbd_user_key or ceph_csi_user_key)."
    }
  }
}

data "helm_template" "ceph_fs" {
  count    = local.ceph_fs_enabled ? 1 : 0
  provider = helm.template

  name         = "ceph-csi-cephfs"
  namespace    = "ceph-csi-cephfs"
  repository   = "https://ceph.github.io/csi-charts"
  chart        = "ceph-csi-cephfs"
  version      = var.ceph_csi.version
  kube_version = local.kubernetes_version

  values = [yamlencode({
    csiConfig   = local.ceph_csi_config
    provisioner = { replicaCount = local.replicas }
    secret      = { create = false } # kubectl_manifest.ceph_secret
    storageClass = {
      create      = true
      name        = var.ceph_csi.cephfs.storage_class
      clusterID   = var.ceph_csi.cluster_id
      fsName      = var.ceph_csi.cephfs.fs_name
      pool        = var.ceph_csi.cephfs.data_pool # "" = the file system's default data pool
      annotations = local.default_annotation[var.ceph_csi.cephfs.storage_class]
    }
  })]

  lifecycle {
    precondition {
      condition     = var.ceph_csi.cluster_id != "" && length(var.ceph_csi.monitors) > 0 && local.ceph_fs_user_key != ""
      error_message = "ceph_csi CephFS needs cluster_id, monitors and a key (ceph_csi_cephfs_user_key or ceph_csi_user_key)."
    }
  }
}

data "helm_template" "nfs" {
  count    = var.nfs_csi.enabled ? 1 : 0
  provider = helm.template

  name         = "csi-driver-nfs"
  namespace    = "csi-nfs"
  repository   = "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts"
  chart        = "csi-driver-nfs"
  version      = var.nfs_csi.version
  kube_version = local.kubernetes_version

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

  lifecycle {
    precondition {
      condition     = var.nfs_csi.server != ""
      error_message = "nfs_csi needs server."
    }
  }
}

locals {
  csi_rendered = merge(
    { for t in data.helm_template.proxmox_csi : "proxmox-csi" => t.manifest },
    { for t in data.helm_template.ceph_rbd : "ceph-rbd" => t.manifest },
    { for t in data.helm_template.ceph_fs : "ceph-fs" => t.manifest },
    { for t in data.helm_template.nfs : "nfs" => t.manifest },
  )
  # Every rendered document, decoded once.
  csi_docs = flatten([for driver, manifest in local.csi_rendered : [
    for doc in split("\n---", "\n${manifest}") : { driver = driver, obj = yamldecode(doc) }
    if try(yamldecode(doc).kind, null) != null
  ]])
  # StorageClass and CSIDriver are replaced on any change (immutable fields): drop their labels,
  # which name the chart version, so a chart upgrade alone does not replace them.
  immutable_kinds = ["StorageClass", "CSIDriver"]
  # One entry per object, keyed "<driver>/<kind>/<namespace>/<name>" (known at plan time).
  csi_objects = { for d in local.csi_docs :
    "${d.driver}/${d.obj.kind}/${try(d.obj.metadata.namespace, "-")}/${d.obj.metadata.name}" => (
      contains(local.immutable_kinds, d.obj.kind)
      ? yamlencode(merge(d.obj, { metadata = { for k, v in d.obj.metadata : k => v if k != "labels" } }))
      : yamlencode(d.obj)
    )
  }
}

resource "kubectl_manifest" "csi" {
  for_each = local.csi_objects

  yaml_body = each.value
  # StorageClass parameters and CSIDriver specs are immutable: replace them on change.
  force_new = contains(local.immutable_kinds, split("/", each.key)[1])

  depends_on = [kubectl_manifest.namespace, kubectl_manifest.proxmox_csi_config, kubectl_manifest.ceph_secret]
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
