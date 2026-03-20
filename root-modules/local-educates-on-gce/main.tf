provider "google" {
  # project = var.project_id
  # region  = var.region
}

module "gce_for_local_educates" {
  source = "../../infrastructure/gce-for-local-educates"

  project_id    = var.project_id
  region        = var.region
  zone          = var.zone
  cluster_name  = var.cluster_name
  machine_type  = var.machine_type
  disk_size_gb  = var.disk_size_gb
  dns_zone_name = var.dns_zone_name
  TLD           = var.TLD
}

module "educates_local" {
  count = var.deploy_educates ? 1 : 0

  source = "../../platform/educates-local"

  educates_version   = var.educates_version
  cluster_name       = var.cluster_name
  wildcard_domain    = "${var.cluster_name}.${var.TLD}"
  # Data dependency through outputs ensures VM + IAM are ready
  ssh_connection = module.gce_for_local_educates.ssh_connection
  gcp_project    = var.project_id
  dns_zone           = var.TLD
}
