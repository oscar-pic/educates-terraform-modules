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
