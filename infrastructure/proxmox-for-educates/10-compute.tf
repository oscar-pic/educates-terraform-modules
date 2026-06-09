resource "proxmox_virtual_environment_vm" "kube_node" {
  # We use the flavor variable to control which nodes are created
  for_each = var.kube_nodes 

  name      = each.key
  node_name = var.proxmox_nodes[each.value.proxmox_host]
  agent { enabled = true }

  cpu {
    cores = each.value.vm_cores
    # Using 'host' allows nested virtualization/better performance 
    # but requires identical CPUs in the cluster.
    type  = "x86-64-v2-AES" 
  }

  memory { dedicated = each.value.vm_memory }

  disk {
    datastore_id = var.proxmox_vms_datastore.name
    
    file_id = var.proxmox_images_snippets_datastore.shared ? (
      proxmox_download_file.os_image[var.proxmox_nodes[0]].id
    ) : (
      proxmox_download_file.os_image[var.proxmox_nodes[each.value.proxmox_host]].id
    )

    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = each.value.vm_disk_size
  }

  network_device {
    mac_address = lookup(each.value, "mac_address", null)
    bridge      = each.value.network_bridge
  }

  dynamic "network_device" {
    for_each = each.value.ceph_network_bridge != "" ? [1] : []
    content {
      bridge = each.value.ceph_network_bridge
      mtu    = 9000
    }
  }

  operating_system { type = "l26" }

  initialization {
    datastore_id = var.proxmox_vms_datastore.name
    interface    = "scsi1"
    upgrade = true
    #upgrade = false

    # Always use the flavor-aware snippet for Ubuntu/Debian nodes
    # (Unless it's Talos, which you'd handle at the resource/dynamic block level)
    vendor_data_file_id = proxmox_virtual_environment_file.ubuntu_flavor_config[each.key].id

    # Keep user_data NULL to protect your SSH keys!
    user_data_file_id = null

    ip_config {
      ipv4 {
        address = "${each.value.ip_address}"
        gateway = each.value.gateway
      }
    }
    dns {
      servers = each.value.dns_servers
    }

    dynamic "ip_config" {
      for_each = each.value.ceph_ip_address != "" ? [1] : []
      content {
        ipv4 {
          address = "${each.value.ceph_ip_address}"
        }
      }
    }

    user_account {
      username = each.value.vm_user
      password = each.value.vm_password
      #keys     = [trimspace(file(each.value.ssh_key_path))]
      keys     = [trimspace(file(pathexpand(each.value.ssh_key_path)))]
    }
  }
  depends_on = [proxmox_virtual_environment_file.ubuntu_flavor_config]
}

resource "proxmox_haresource" "kube_node_ha" {
  for_each = var.kube_nodes

  # The ID of the Proxmox resource in the format "vm:<vmid>"
  resource_id = "vm:${proxmox_virtual_environment_vm.kube_node[each.key].vm_id}"
  
  # The desired state for the VM in the HA cluster (started, stopped, ignored, disabled)
  state = "started"

  # Optional: Define the HA group if you have one configured in your datacenter (e.g., "my-ha-group")
  # group = "my-ha-group"

  # Ensure the VM is created completely before Proxmox attempts to include it in HA
  depends_on = [proxmox_virtual_environment_vm.kube_node]
}
