resource "proxmox_download_file" "os_image" {
  # Logic: If datastore.shared is true, loop once. If false, loop per node used.
  for_each = var.proxmox_images_snippets_datastore.shared ? toset([var.proxmox_nodes[0]]) : toset(var.proxmox_nodes)
  content_type = "iso"
  datastore_id = var.proxmox_images_snippets_datastore.name # Use the 'name' property
  node_name    = each.value
  url          = var.cloud_image_url
  file_name    = var.proxmox_image_filename
  
# This prevents the error if the file is already there
  overwrite = false 
  overwrite_unmanaged = true # It allows Terraform to take control of the existing file 
  
  lifecycle {
    prevent_destroy = false
    # If the file is there, just trust it's the right one
    ignore_changes = [url] 
  }
}

resource "proxmox_virtual_environment_file" "ubuntu_flavor_config" {
  # Logic: If flavor is Talos, we create 0 snippets.
  # If it's single-node-k3s, we create snippets for the nodes.
  #for_each = var.deployment_flavor == "single-node-k3s" ? var.kube_nodes : {}
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
      # This adds 6 spaces to the start of every line in your config_patches list
      extra_configs       = join("\n      ", each.value.config_patches)
      timezone            = var.system_timezone
      ceph_interface_name = var.k8s_ceph_storage_interface_name
    })
    # This names the file on the Proxmox storage (e.g., qemu-k3s-init-educates-01.yaml)
    file_name = "ubuntu-${var.deployment_flavor}-${each.key}.yaml"
    # If content_type is "iso", you need to rename the file with .iso or .img extension and ensure the data is the rendered template content without base64 encoding.
    # file_name = "ubuntu-${var.deployment_flavor}-${each.key}.yaml.iso or .yaml.img"
  }
}