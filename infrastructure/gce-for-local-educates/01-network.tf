locals {
  network_ip_cidr_range = "10.0.0.0/24"
}

resource "google_compute_network" "this" {
  name                    = "${var.cluster_name}-vpc"
  project                 = var.project_id
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "this" {
  name          = "${var.cluster_name}-subnet"
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.this.id
  ip_cidr_range = local.network_ip_cidr_range
}

resource "google_compute_firewall" "allow_http" {
  name    = "${var.cluster_name}-allow-http"
  project = var.project_id
  network = google_compute_network.this.name

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["${var.cluster_name}-educates"]
}

resource "google_compute_firewall" "allow_https" {
  name    = "${var.cluster_name}-allow-https"
  project = var.project_id
  network = google_compute_network.this.name

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["${var.cluster_name}-educates"]
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "${var.cluster_name}-allow-ssh"
  project = var.project_id
  network = google_compute_network.this.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["${var.cluster_name}-educates"]
}
