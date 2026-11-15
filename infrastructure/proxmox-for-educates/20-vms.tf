###############################################################################
# Proxmox VMs.
# Network settings reach Talos through Proxmox's own cloud-init drive (nocloud
# platform). The machine configuration is not stored on Proxmox: it is pushed
# over the Talos API (30-talos.tf).
###############################################################################

# Optional resource pool for the cluster's VMs (proxmox.pool).
# - Default: an existing pool, kept by whoever runs Proxmox. Only referenced: never created,
#   changed or deleted.
# - proxmox.create_pool: the module creates the last level, and deletes it on destroy after the
#   VMs. Parent levels must exist. Proxmox only deletes an empty pool, so VMs that others put in
#   it are never touched. The comment identifies the pool as this cluster's (preflight.sh).
resource "proxmox_virtual_environment_pool" "this" {
  count = var.proxmox.pool != null && var.proxmox.create_pool ? 1 : 0

  pool_id = var.proxmox.pool
  comment = "Talos Kubernetes cluster '${var.cluster_name}' for Educates. Managed by OpenTofu/Terraform."
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = var.nodes

  name        = local.hostnames[each.key]
  node_name   = each.value.proxmox_node
  vm_id       = each.value.vm_id
  pool_id     = var.proxmox.create_pool ? proxmox_virtual_environment_pool.this[0].pool_id : var.proxmox.pool
  description = "Talos ${each.value.role} of Kubernetes cluster '${var.cluster_name}'. Managed by OpenTofu/Terraform."
  tags        = local.vm_tags[each.key]

  machine         = "q35"
  bios            = "ovmf"
  scsi_hardware   = "virtio-scsi-single" # also required by Proxmox CSI to hot-plug volumes
  on_boot         = true
  started         = true
  stop_on_destroy = true
  # Never let the provider reboot a node to apply a change: on a cluster that would happen to
  # several nodes at once (etcd quorum). Changes that need a reboot are left pending, and the
  # nodes are rebooted one at a time (docs/upgrades.md).
  reboot_after_update = false

  agent {
    enabled = local.guest_agent_enabled
    trim    = true
  }

  cpu {
    cores = each.value.cpu
    type  = var.proxmox.cpu_type
  }

  memory {
    dedicated = each.value.memory
    floating  = 0 # no ballooning: Kubernetes needs to see the real memory
  }

  operating_system {
    type = "l26"
  }

  efi_disk {
    datastore_id      = var.proxmox.vm_datastore
    type              = "4m"
    pre_enrolled_keys = false
  }

  disk {
    interface    = "scsi0"
    datastore_id = var.proxmox.vm_datastore
    import_from  = proxmox_download_file.talos[var.proxmox.image_datastore_shared ? local.image_nodes[0] : each.value.proxmox_node].id
    size         = each.value.disk_size
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  network_device {
    bridge      = var.network.bridge
    vlan_id     = var.network.vlan_id
    mtu         = var.network.mtu
    mac_address = each.value.mac_address
    model       = "virtio"
  }

  dynamic "network_device" {
    for_each = var.storage_network == null ? [] : [var.storage_network]
    content {
      bridge  = network_device.value.bridge
      vlan_id = network_device.value.vlan_id
      mtu     = network_device.value.mtu
      model   = "virtio"
    }
  }

  initialization {
    datastore_id = var.proxmox.vm_datastore

    ip_config {
      ipv4 {
        address = "${each.value.ip}/${local.network_prefix}"
        gateway = var.network.gateway
      }
    }

    dynamic "ip_config" {
      for_each = var.storage_network == null ? [] : [each.value.storage_ip]
      content {
        ipv4 {
          address = "${ip_config.value}/${local.storage_prefix}"
        }
      }
    }

    dns {
      servers = var.network.dns_servers
    }
  }

  serial_device {}

  lifecycle {
    # Upgrading Talos replaces the downloaded image; the VMs must stay (lesson 1).
    ignore_changes = [disk[0].import_from]

    precondition {
      condition     = length(local.cp_nodes) == 1 || local.api_vip != ""
      error_message = "network.api_vip is required when there is more than one control-plane node."
    }
    precondition {
      condition     = var.storage_network == null || each.value.storage_ip != null
      error_message = "Node '${each.key}' needs storage_ip because storage_network is set."
    }
  }
}

resource "proxmox_haresource" "node" {
  for_each = var.proxmox.ha_enabled ? var.nodes : {}

  resource_id = "vm:${proxmox_virtual_environment_vm.node[each.key].vm_id}"
  state       = "started"
  comment     = "Talos node ${local.hostnames[each.key]}"
}
