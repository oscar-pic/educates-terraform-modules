output "gce" {
  value = {
    cluster_name          = var.cluster_name
    instance_name         = google_compute_instance.this.name
    external_ip           = google_compute_address.this.address
    zone                  = local.zone
    service_account_email = google_service_account.vm.email
  }

  depends_on = [
    google_compute_instance.this,
    google_project_iam_member.vm_dns_admin,
    google_dns_record_set.wildcard,
  ]
}

output "ssh_connection" {
  value = {
    host        = google_compute_address.this.address
    user        = var.ssh_user
    private_key = tls_private_key.ssh.private_key_pem
  }
  sensitive = true

  depends_on = [
    google_compute_instance.this,
  ]
}
