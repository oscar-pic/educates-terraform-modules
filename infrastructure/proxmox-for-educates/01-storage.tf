locals {
  # Calculamos el path de forma centralizada
  target_paths = {
    for node in (var.deployment_flavor == "talos-cluster" ? (
      var.proxmox_images_snippets_datastore.shared ? [var.proxmox_nodes[0]] : var.proxmox_nodes
    ) : []) : node => "${var.proxmox_images_snippets_datastore.shared ? "/mnt/pve/${var.proxmox_images_snippets_datastore.name}" : "/var/lib/vz"}/template/iso/talos-${var.talos_compiled_version}-nocloud-amd64.img"
  }
  iso_cleanup_map = {
    for node_name, node_cfg in var.kube_nodes : "${var.proxmox_nodes[node_cfg.proxmox_host]}_${node_name}" => {
      host = var.proxmox_nodes[node_cfg.proxmox_host]
      path = "${var.proxmox_images_snippets_datastore.shared ? "/mnt/pve/${var.proxmox_images_snippets_datastore.name}" : "/var/lib/vz"}/template/iso/talos-config-${node_name}.iso"
    }
  }
}

resource "proxmox_download_file" "os_image" {
  # Logic: If datastore.shared is true, loop once. If false, loop per node used.
  for_each = var.proxmox_images_snippets_datastore.shared ? toset([var.proxmox_nodes[0]]) : toset(var.proxmox_nodes)
  content_type = "iso"
  datastore_id = var.proxmox_images_snippets_datastore.name
  node_name    = each.value

  # 🔀 HYBRID URL EVALUATION
  # If flavor is Talos, fetch from factory data source. Otherwise, fall back to your var.cloud_image_url.
  # Added [0] because the data source uses a conditional count block
  url = var.deployment_flavor == "talos-cluster" ? data.talos_image_factory_urls.talos_iso_schematic[0].urls.disk_image : var.cloud_image_url
    
  # 🔀 HYBRID FILENAME EVALUATION
  # If flavor is Talos, build the filename with local version. Otherwise, use var.proxmox_image_filename.
  file_name = var.deployment_flavor == "talos-cluster" ? "talos-${var.talos_compiled_version}-nocloud-amd64.raw.xz.img" : var.proxmox_image_filename
    
# This prevents the error if the file is already there
  overwrite = false 
  overwrite_unmanaged = true # It allows Terraform to take control of the existing file 
  
  lifecycle {
    prevent_destroy = false
    # If the file is there, just trust it's the right one
    # We leave ignore_changes empty so changes in Talos locals or RKE2 vars trigger the download properly
    ignore_changes = []
  }
}

resource "null_resource" "decompress_talos_image" {
  for_each = var.deployment_flavor == "talos-cluster" ? (
    var.proxmox_images_snippets_datastore.shared ? toset([var.proxmox_nodes[0]]) : toset(var.proxmox_nodes)
  ) : []

  # We depend on the file being downloaded first
  depends_on = [proxmox_download_file.os_image]

  # Runs only if the URL changes or the original file is updated
  triggers = {
    file_id = proxmox_download_file.os_image[each.key].id
    talos_version = var.talos_compiled_version
  }

  connection {
    type        = "ssh"
    user        = "root"
    host        = each.value
    private_key = file(var.ssh_private_key_path)
  }

  provisioner "remote-exec" {
    inline = [
        "BASE_PATH='${var.proxmox_images_snippets_datastore.shared ? "/mnt/pve/${var.proxmox_images_snippets_datastore.name}" : "/var/lib/vz"}'",
        # Remove single quotes around $BASE_PATH so Bash can expand it
        "STORAGE_PATH=\"$BASE_PATH/template/iso\"",
        
        "FILE_PATH=\"$STORAGE_PATH/talos-${var.talos_compiled_version}-nocloud-amd64.raw.xz.img\"",
        "OUTPUT_PATH=\"$STORAGE_PATH/talos-${var.talos_compiled_version}-nocloud-amd64.img\"",
        
        #"mkdir -p \"$STORAGE_PATH\"",
        "if [ ! -f \"$OUTPUT_PATH\" ] || [ \"$FILE_PATH\" -nt \"$OUTPUT_PATH\" ]; then",
        "  xz -d -f -c \"$FILE_PATH\" > \"$OUTPUT_PATH\"",
        #"  rm -f \"$FILE_PATH\"",
        # Wait loop: check if Proxmox has indexed the file before finishing
        "  echo 'Waiting for Proxmox to index the file...'",
        "  for i in {1..10}; do",
        "    if pvesm list ${var.proxmox_images_snippets_datastore.name} | grep -q '${var.talos_compiled_version}-nocloud-amd64.img'; then",
        "      echo 'File detected!' && exit 0",
        "    fi",
        "    sleep 3",
        "  done",
        "  echo 'Timeout: The file did not appear in the catalog' && exit 1",
        "fi"
      ]
  }
}

resource "null_resource" "prepare_clean_config" {
  for_each = var.deployment_flavor == "talos-cluster" ? var.kube_nodes : {}
  
  triggers = {
    config = data.talos_machine_configuration.talos_config[each.key].machine_configuration
  }

  provisioner "local-exec" {
    command = <<EOT
      mkdir -p ${path.module}/build/config/original
      mkdir -p ${path.module}/build/config/clean
      
      echo "${data.talos_machine_configuration.talos_config[each.key].machine_configuration}" > "${path.module}/build/config/original/${each.key}.yaml"
      
      echo "${data.talos_machine_configuration.talos_config[each.key].machine_configuration}" | \
      yq 'select(.kind != "HostnameConfig")' > "${path.module}/build/config/clean/${each.key}.yaml"
    EOT
  }
}

resource "null_resource" "create_talos_config_iso" {
  for_each = var.deployment_flavor == "talos-cluster" ? var.kube_nodes : {}

  # Aseguramos que la configuración limpia existe antes de crear el ISO
  depends_on = [
    null_resource.prepare_clean_config,
    proxmox_download_file.os_image
  ]

  triggers = {
    config_hash = sha1(data.talos_machine_configuration.talos_config[each.key].machine_configuration)
  }

  connection {
    type        = "ssh"
    user        = "root"
    host        = var.proxmox_images_snippets_datastore.shared ? var.proxmox_nodes[0] : var.proxmox_nodes[each.value.proxmox_host]
    private_key = file(var.ssh_private_key_path)
  }

  provisioner "file" {
    source      = "${path.module}/build/config/clean/${each.key}.yaml"
    destination = "/tmp/user-data-${each.key}"
  }

  provisioner "remote-exec" {
    inline = [
      "BASE_PATH='${var.proxmox_images_snippets_datastore.shared ? "/mnt/pve/${var.proxmox_images_snippets_datastore.name}" : "/var/lib/vz"}'",
      "STORAGE_PATH=\"$BASE_PATH/template/iso\"",
      "CIDATA_PATH='/tmp/cidata-${each.key}'",
      
      # Prepare Cloud-Init structure
      "mkdir -p $CIDATA_PATH",
      
      # Movemos el archivo limpio que subimos anteriormente
      "mv /tmp/user-data-${each.key} $CIDATA_PATH/user-data",
      "echo 'instance-id: talos-${each.key}' > $CIDATA_PATH/meta-data",

      # Configuración de red
      "printf 'version: 2\\nethernets:\\n  ${var.k8s_api_cp_interface}:\\n    dhcp4: false\\n    addresses:\\n      - ${each.value.ip_address}\\n    routes:\\n      - to: default\\n        via: ${each.value.gateway}\\n    nameservers:\\n      addresses: [${join(",", each.value.dns_servers)}]\\n' > $CIDATA_PATH/network-config",

      "if [ -n '${each.value.ceph_ip_address}' ]; then printf '\\n  ${var.k8s_ceph_node_interface}:\\n    dhcp4: false\\n    addresses:\\n      - ${each.value.ceph_ip_address}\\n    mtu: 9000\\n' >> $CIDATA_PATH/network-config; fi",

      # Generar el ISO
      "genisoimage -input-charset utf-8 -output $STORAGE_PATH/talos-config-${each.key}.iso -volid cidata -joliet -rock $CIDATA_PATH",
      
      # Cleanup
      "rm -rf $CIDATA_PATH"
    ]
  }
}

resource "null_resource" "cleanup_talos_image" {
  for_each = local.target_paths

  depends_on = [null_resource.decompress_talos_image]

  triggers = {
    node = each.key
    path = each.value
    key_path = var.ssh_private_key_path
  }

  provisioner "local-exec" {
    when    = destroy
    command = "ssh -i ${self.triggers.key_path} -o StrictHostKeyChecking=no root@${self.triggers.node} 'rm -f ${self.triggers.path}'"
  }
}

resource "null_resource" "cleanup_node_isos" {
  for_each = local.iso_cleanup_map

  triggers = {
    host      = each.value.host
    file_path = each.value.path
    key_path  = var.ssh_private_key_path
  }

  provisioner "local-exec" {
    when    = destroy
    command = "ssh -i ${self.triggers.key_path} -o StrictHostKeyChecking=no root@${self.triggers.host} 'rm -f ${self.triggers.file_path}'"
  }
}

resource "proxmox_virtual_environment_file" "ubuntu_flavor_config" {
  # Logic: If flavor is Talos, we create 0 snippets.
  # If it's single-node-k3s, we create snippets for the nodes.
  for_each = contains(["single-node-k3s", "rke2-cluster"], var.deployment_flavor) ? var.kube_nodes : {}
  content_type = "snippets"
  # It's recommended to use a shared NFS datastore for snippets, if not, SSH connection will be used to upload the file to the specific node.
  # If you want to avoid SSH, use a shared datastore and comment out the ssh block in the provider configuration.
  # If you cannot use a shared datastore, content_type can be set to "iso" to upload the file as an ISO, 
  # and then use it as a cloud-init CD-ROM. But in this case, you need to set the file_name with the .iso or .img extension 
  # and the source_raw data should be the rendered template content without any base64 encoding, since Proxmox will treat it as a regular file.
  # In this case, change content_type = "iso"
  datastore_id = var.proxmox_images_snippets_datastore.name
  # Logic: If your storage is shared, we upload via the first node.
  # If it is local, we upload to the specific node where the VM will live.
  node_name = var.proxmox_images_snippets_datastore.shared ? (
    var.proxmox_nodes[0]
  ) : (
    var.proxmox_nodes[each.value.proxmox_host]
  )
  source_raw {
    data = templatefile("${path.module}/templates/ubuntu-payload.tftpl", {
      hostname            = each.key
      deployment_flavor   = var.deployment_flavor
      timezone            = var.system_timezone
      ceph_interface      = var.k8s_ceph_node_interface
      ceph_network        = var.k8s_ceph_network_cidr
    })
    # This names the file on the Proxmox storage (e.g., qemu-k3s-init-educates-01.yaml)
    file_name = "ubuntu-${var.deployment_flavor}-${each.key}.yaml"
  }
}