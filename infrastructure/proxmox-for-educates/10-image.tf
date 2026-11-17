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
  talos_version = var.talos.version
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "nocloud"
  architecture  = "amd64"
  # qcow2, not raw.zst: Proxmox only decompresses downloads of ISO content, never "import".
  disk_image_format = "qcow2"
}

resource "proxmox_download_file" "talos" {
  # One download per Proxmox host, or a single one under the fixed key "shared" on a shared
  # datastore: changing the download host then replaces it in place (destroy, then create),
  # never two instances of the same file in one apply.
  for_each = local.image_downloads

  node_name    = each.value
  datastore_id = var.proxmox.image_datastore
  content_type = "import"
  url          = data.talos_image_factory_urls.this.urls.disk_image
  file_name    = "talos-${var.talos.version}-${substr(talos_image_factory_schematic.this.id, 0, 12)}-nocloud-amd64.qcow2"
  # Never re-download an existing file: the name already pins version and schematic.
  overwrite = false
}
