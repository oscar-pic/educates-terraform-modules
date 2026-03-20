locals {
  cluster_name_safe = lower(replace(var.cluster_name, "_", "-"))
  vm_account_id     = substr("${local.cluster_name_safe}-vm", 0, 30)
}

resource "google_service_account" "vm" {
  account_id   = local.vm_account_id
  display_name = "Service Account for educates VM ${var.cluster_name} (cert-manager + external-dns)"
  project      = var.project_id
}

resource "google_project_iam_member" "vm_dns_admin" {
  project = var.project_id
  role    = "roles/dns.admin"
  member  = "serviceAccount:${google_service_account.vm.email}"
}
