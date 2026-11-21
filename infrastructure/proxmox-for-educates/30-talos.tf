###############################################################################
# Talos: secrets, machine configuration, bootstrap and health.
#
# The configuration uses the Talos multi-document format of the pinned contract
# (var.talos.config_contract). Patches are lists of YAML documents.
###############################################################################

resource "talos_machine_secrets" "this" {
  talos_version = var.talos.config_contract
}

data "helm_template" "cilium" {
  provider = helm.template

  name         = "cilium"
  namespace    = "kube-system"
  repository   = "https://helm.cilium.io"
  chart        = "cilium"
  version      = var.cilium.version
  kube_version = local.kubernetes_version

  values = compact([
    templatefile("${path.module}/templates/cilium-values.yaml.tftpl", {
      # The Cilium operator tolerates control-plane taints: every node counts.
      operator_replicas   = length(var.nodes) > 1 ? 2 : 1
      gateway_api_enabled = var.gateway_api.enabled
      hubble_enabled      = var.cilium.hubble_enabled
    }),
    var.cilium.extra_values,
  ])
}

locals {
  yaml_docs = { for k, v in {
    # Cluster-wide documents: only allowed on control-plane machines.
    no_flannel    = { apiVersion = "v1alpha1", kind = "KubeFlannelCNIConfig", "$patch" = "delete" }
    no_kube_proxy = { apiVersion = "v1alpha1", kind = "KubeProxyConfig", enabled = false }
    cilium        = { apiVersion = "v1alpha1", kind = "KubeInlineManifestConfig", name = "cilium", manifest = data.helm_template.cilium.manifest }
    gateway_api   = { apiVersion = "v1alpha1", kind = "KubeExternalManifestConfig", name = "gateway-api-crds", url = local.gateway_api_crds_url }
    api_vip       = { apiVersion = "v1alpha1", kind = "Layer2VIPConfig", name = local.api_vip, link = var.network.interface }
    time_sync     = { apiVersion = "v1alpha1", kind = "TimeSyncConfig", ntp = { servers = var.talos.ntp_servers } }
    # Talos merges maps, so removing the default control-plane taint means deleting
    # the document and adding it back (lesson 2).
    delete_node_config = { apiVersion = "v1alpha1", kind = "KubeNodeConfig", "$patch" = "delete" }
    # etcd must advertise its node-network address. With a second NIC (storage_network),
    # it could otherwise pick the storage address after a reboot and break the membership.
    etcd_subnets = { cluster = { etcd = { advertisedSubnets = [var.network.cidr] } } }
  } : k => yamlencode(v) }

  controlplane_patches = compact([
    local.yaml_docs.etcd_subnets,
    local.yaml_docs.no_flannel,
    local.yaml_docs.no_kube_proxy,
    local.yaml_docs.cilium,
    var.gateway_api.enabled ? local.yaml_docs.gateway_api : "",
    local.api_vip != "" ? local.yaml_docs.api_vip : "",
    local.schedulable_control_planes ? local.yaml_docs.delete_node_config : "",
  ])

  node_patches = {
    for k, n in var.nodes : k => compact(concat([
      # Default installer is the plain 'metal' one: 'talosctl upgrade' would drop the
      # extensions. Point it at this cluster's nocloud schematic.
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "UnattendedInstallConfig"
        installer  = { image = data.talos_image_factory_urls.this.urls.installer }
        # Patching this document drops the default selector, so restate it (scsi0).
        provisioning = { diskSelector = { match = "disk.dev_path == \"/dev/sda\"" } }
      }),
      yamlencode({ apiVersion = "v1alpha1", kind = "HostnameConfig", auto = "off", hostname = local.hostnames[k] }),
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "KubeNodeConfig"
        # With two NICs, the kubelet must register the node-network address.
        nodeIP = { validSubnets = [var.network.cidr] }
        labels = merge(
          # When the default KubeNodeConfig was deleted, add back the control-plane label.
          n.role == "controlplane" && local.schedulable_control_planes ? { "node-role.kubernetes.io/control-plane" = "" } : {},
          {
            "topology.kubernetes.io/region" = var.proxmox.region
            "topology.kubernetes.io/zone"   = n.proxmox_node
          },
          n.labels,
        )
      }),
      length(var.talos.ntp_servers) > 0 ? local.yaml_docs.time_sync : "",
      ], [
      for m in var.talos.kernel_modules : yamlencode({ apiVersion = "v1alpha1", kind = "KernelModuleConfig", name = m })
    ]))
  }
}

data "talos_machine_configuration" "node" {
  for_each = var.nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = each.value.role
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos.config_contract
  kubernetes_version = local.kubernetes_version
  docs               = false
  examples           = false

  config_patches = concat(
    each.value.role == "controlplane" ? local.controlplane_patches : [],
    local.node_patches[each.key],
    var.extra_config_patches.all,
    each.value.role == "controlplane" ? var.extra_config_patches.controlplane : var.extra_config_patches.worker,
  )
}

# Applies the configuration over the Talos API (maintenance mode on first boot)
# and re-applies it whenever it changes, so day-2 changes reach the nodes.
resource "talos_machine" "node" {
  for_each = var.nodes

  node                  = each.value.ip
  client_configuration  = talos_machine_secrets.this.client_configuration
  machine_configuration = data.talos_machine_configuration.node[each.key].machine_configuration

  # Kubernetes upgrades belong to talos_cluster (upgrade-k8s), not to parallel re-applies.
  ignore_kubernetes_upgrade_drift = true

  # The image the node already runs, so the provider never upgrades on create.
  # Without it, provider v0.12.0 treats the unknown computed value as set and tries
  # an upgrade to "" ("failed to parse image reference").
  image = data.talos_image_factory_urls.this.urls.installer
  # No OS upgrades through the provider, so nothing to drain (and no kubeconfig needed).
  drain_on_upgrade = false

  depends_on = [proxmox_virtual_environment_vm.node]

  lifecycle {
    # Talos OS upgrades are done with talosctl, one node at a time (docs/operations.md):
    # a new image here would upgrade every node in parallel and break etcd quorum.
    ignore_changes = [image]
  }
}

# Bootstraps etcd once, then owns Kubernetes upgrades (changing kubernetes_version
# runs upgrade-k8s, node by node with health gating).
resource "talos_cluster" "this" {
  node = local.bootstrap_ip
  # A node, never the API VIP: the VIP only comes up once etcd runs, after the bootstrap.
  endpoint             = local.bootstrap_ip
  control_plane_nodes  = local.cp_ips
  client_configuration = talos_machine_secrets.this.client_configuration
  kubernetes_version   = "v${local.kubernetes_version}"

  depends_on = [talos_machine.node]

  lifecycle {
    # The bootstrap node is the first control-plane key in alphabetical order. Adding a key
    # that sorts first, or removing that node, must never bootstrap etcd again.
    ignore_changes = [node]
  }
}

resource "talos_cluster_kubeconfig" "this" {
  node                 = local.bootstrap_ip
  endpoint             = local.bootstrap_ip
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [talos_cluster.this]
}

# etcd, API server and every node Ready (lesson 1). Run plan/apply from a machine
# close to the cluster network: over a slow link this check can hang.
data "talos_cluster_health" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = local.cp_ips
  control_plane_nodes  = local.cp_ips
  worker_nodes         = local.worker_ips

  timeouts = {
    read = var.health_check_timeout
  }

  # Wait for every node's configuration, not only the bootstrap. Otherwise adding a worker
  # (no change to talos_cluster) reads this during plan, and it waits for a node that does
  # not exist yet until it times out.
  depends_on = [talos_cluster.this, talos_machine.node]
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = local.cp_ips
  nodes                = [local.bootstrap_ip]
}
