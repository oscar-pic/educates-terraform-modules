resource "proxmox_virtual_environment_pool" "cluster_pool" {
  pool_id = var.k8s_cluster_name
  comment = "Nodes for Kubernetes cluster '${var.k8s_cluster_name}' (${var.deployment_flavor})"
}

resource "proxmox_virtual_environment_vm" "kube_node" {
  # We use the flavor variable to control which nodes are created
  for_each = var.kube_nodes

  name      = "${var.k8s_cluster_name}-${each.key}"
  node_name = var.proxmox_nodes[each.value.proxmox_host]
  pool_id   = proxmox_virtual_environment_pool.cluster_pool.pool_id

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    proxmox_download_file.os_image,
    null_resource.talos_create_config_iso
  ]
  
  agent { 
    #enabled = var.deployment_flavor == "talos-cluster" ? false : true
    enabled = true
    trim    = true
    timeout = "15m"
  }

  # Needed for qemu-guest-agent
  serial_device {
    device = "socket"
  }

   cpu {
    cores = each.value.vm_cores
    # Using 'host' allows nested virtualization/better performance 
    # but requires identical CPUs in the cluster.
    # 🚀 CRITICAL UPDATE A: Force CPU type to 'host' for Talos as requested by documentation
    #type  = "x86-64-v2-AES" 
    #type = var.deployment_flavor == "talos-cluster" ? "host" : "x86-64-v2-AES"
    type = "host"
  }

  memory { 
    dedicated = each.value.vm_memory 
    # 🚀 CRITICAL UPDATE B: Memory Ballooning settings for Talos stability
    #floating  = var.deployment_flavor == "talos-cluster" ? 0 : each.value.vm_memory
    floating = 0
  }

  operating_system { 
    type = "l26" # Linux Kernel 2.6+
  } 

  # 🔀 Hybrid Evaluation of Chipset and BIOS
  # If it's Talos, use q35 and ovmf (UEFI), otherwise maintain i440fx and SeaBIOS (default)
  machine = var.deployment_flavor == "talos-cluster" ? "q35" : null
  bios    = var.deployment_flavor == "talos-cluster" ? "ovmf" : null

  # 🔀 BOOT ORDER (The one you already had configured)
  # Talos boots from ISO (ide2) first to install, then from disk (scsi0).
  # Ubuntu boots directly from its pre-provisioned cloud image disk (scsi0).
  boot_order = var.deployment_flavor == "talos-cluster" ? ["scsi0", "ide2"] : ["scsi0"]

  # 🔀 Dynamic Injection of the EFI Disk
  # Only the efi_disk structure is generated if we are deploying a Talos cluster
  dynamic "efi_disk" {
    for_each = var.deployment_flavor == "talos-cluster" ? [1] : []
    content {
      datastore_id = var.proxmox_vms_datastore.name
      file_format  = "raw"
      type         = "4m" # Standard format for the modern OVMF BIOS in PVE
    }
  }

  # 🔀 Recommended SCSI controller for Talos
  # We apply the same criterio to avoid the 'single' mode (virtio-scsi-single) that causes issues during Talos bootstrap
  #scsi_hardware = var.deployment_flavor == "talos-cluster" ? "virtio-scsi-pci" : "virtio-scsi-single"
  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = var.proxmox_vms_datastore.name
    file_format  = var.deployment_flavor == "talos-cluster" ? "raw" : null
    size         = each.value.vm_disk_size
    #iothread     = var.deployment_flavor == "talos-cluster" ? false : true
    iothread     = true
    discard      = "on"

    # Dynamic interface assignment: Talos requires standard scsi0. Ubuntu maintains virtio0.
    #interface    = var.deployment_flavor == "talos-cluster" ? "scsi0" : "virtio0"
    interface    = "scsi0"

    file_id = var.deployment_flavor == "talos-cluster" ? (
      var.proxmox_images_snippets_datastore.shared ? (
        # If SHARED, only the datastore name (the cluster knows the rest)
        "${var.proxmox_images_snippets_datastore.name}:iso/talos-${var.talos_compiled_version}-nocloud-amd64.img"
      ) : (
        # If LOCAL, you need the node + datastore
        "${each.value.proxmox_host}:${var.proxmox_images_snippets_datastore.name}/iso/talos-${var.talos_compiled_version}-nocloud-amd64.img"
      )
    ) : (
      # Your Ubuntu logic (which already worked)
      var.proxmox_images_snippets_datastore.shared ? 
        proxmox_download_file.os_image[var.proxmox_nodes[0]].id : 
        proxmox_download_file.os_image[each.value.proxmox_host].id
    )
  }

  dynamic "cdrom" {
    for_each = var.deployment_flavor == "talos-cluster" ? [1] : []
    content {
      interface    = "ide2"
      # We use the path where the null_resource creates the ISO
      file_id = "${var.proxmox_images_snippets_datastore.name}:iso/talos-config-${each.key}.iso"
    }
  }

  network_device {
    mac_address = lookup(each.value, "mac_address", null)
    bridge      = each.value.network_bridge
    model  = "virtio"
  }

  dynamic "network_device" {
    for_each = each.value.ceph_network_bridge != "" ? [1] : []
    #for_each = []
    content {
      bridge = each.value.ceph_network_bridge
      model  = "virtio"
      mtu    = 9000
    }
  }

  # --- CONDITIONAL CLOUD-INIT ISOLATION GUARD FOR UBUNTU ---
  dynamic "initialization" {
    for_each = var.deployment_flavor != "talos-cluster" ? [1] : []
    #for_each = [1]
    content {
      datastore_id        = var.proxmox_vms_datastore.name
      interface           = "scsi1"
      #interface = var.deployment_flavor != "talos-cluster" ? "scsi1" : null
      upgrade             = true
      #upgrade   = var.deployment_flavor != "talos-cluster" ? true : null

      # Always use the flavor-aware snippet for Ubuntu/Debian nodes
      # (Unless it's Talos, which you'd handle at the resource/dynamic block level)
      vendor_data_file_id = proxmox_virtual_environment_file.ubuntu_flavor_config[each.key].id
      #vendor_data_file_id = var.deployment_flavor != "talos-cluster" ? proxmox_virtual_environment_file.ubuntu_flavor_config[each.key].id : null

      # Keep user_data NULL to protect your SSH keys!
      #user_data_file_id   = null
      user_data_file_id   = var.deployment_flavor == "talos-cluster" ? data.talos_machine_configuration.talos_config[each.key].id : null

      ip_config {
        ipv4 {
          address = each.value.ip_address
          gateway = each.value.gateway
        }
      }

      dns {
        servers = each.value.dns_servers
      }

      dynamic "ip_config" {
        for_each = each.value.ceph_ip_address != "" ? [1] : []
        #for_each = (var.deployment_flavor != "talos-cluster" && each.value.ceph_ip_address != "") ? [1] : []
        content {
          ipv4 {
            address = "${each.value.ceph_ip_address}"
          }
        }
      }

      user_account {
        username = each.value.vm_user
        password = each.value.vm_password
        keys     = [trimspace(file(pathexpand(var.ssh_public_key_path)))]
      }
    }
  }
}

resource "proxmox_haresource" "kube_node_ha" {
  for_each = var.kube_nodes

  # The ID of the Proxmox resource in the format "vm:<vmid>"
  resource_id = "vm:${proxmox_virtual_environment_vm.kube_node[each.key].vm_id}"

  # The desired state for the VM in the HA cluster (started, stopped, ignored, disabled)
  state       = "started"

  # Optional: Define the HA group if you have one configured in your datacenter (e.g., "my-ha-group")
  # group = "my-ha-group"

  # Ensure the VM is created completely before Proxmox attempts to include it in HA
  depends_on = [proxmox_virtual_environment_vm.kube_node]
}
