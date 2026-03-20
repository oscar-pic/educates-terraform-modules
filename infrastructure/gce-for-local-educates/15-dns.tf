data "google_dns_managed_zone" "this" {
  name    = var.dns_zone_name
  project = var.project_id
}

resource "google_dns_record_set" "wildcard" {
  name         = "*.${var.cluster_name}.${var.TLD}."
  type         = "A"
  ttl          = 300
  managed_zone = data.google_dns_managed_zone.this.name
  project      = var.project_id

  rrdatas = [google_compute_address.this.address]
}
