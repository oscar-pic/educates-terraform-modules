###############################################################################
# Talos disk image from the Image Factory.
# Downloaded through the Proxmox API only (no SSH to the hypervisors) and imported
# by the VMs at creation time. A new Talos version replaces the downloaded file,
# never the VMs (import_from is only read at VM creation).
###############################################################################

resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = merge(
      { systemExtensions = { officialExtensions = var.talos.extensions } },
      length(var.talos.extra_kernel_args) > 0 ? { extraKernelArgs = var.talos.extra_kernel_args } : {},
    )
  })
}

data "talos_image_factory_urls" "this" {
  talos_version     = var.talos.version
  schematic_id      = talos_image_factory_schematic.this.id
  platform          = "nocloud"
  architecture      = "amd64"
  disk_image_format = "raw.zst"
}

resource "proxmox_download_file" "talos" {
  for_each = toset(local.image_nodes)

  node_name               = each.key
  datastore_id            = var.proxmox.image_datastore
  content_type            = "import"
  url                     = data.talos_image_factory_urls.this.urls.disk_image
  decompression_algorithm = "zst"
  file_name               = "talos-${var.talos.version}-${substr(talos_image_factory_schematic.this.id, 0, 12)}-nocloud-amd64.raw"
  # The URL serves a compressed file, so its size never matches the stored one:
  # without this, every plan would want to download it again.
  overwrite = false
}
