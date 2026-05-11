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

  operating_system { type = "l26" }

  initialization {
    #datastore_id = var.proxmox_images_snippets_datastore.name
    datastore_id = var.proxmox_vms_datastore.name
    interface    = "scsi1"
    upgrade = true

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

    user_account {
      username = each.value.vm_user
      password = each.value.vm_password
      #keys     = [trimspace(file(each.value.ssh_key_path))]
      keys     = [trimspace(file(pathexpand(each.value.ssh_key_path)))]
    }
  }
}