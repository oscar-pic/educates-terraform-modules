data "google_compute_zones" "this" {
  region  = var.region
  project = var.project_id
}

locals {
  zone = var.zone != "" ? var.zone : data.google_compute_zones.this.names[0]
}

resource "google_compute_address" "this" {
  name         = "${var.cluster_name}-ip"
  project      = var.project_id
  region       = var.region
  address_type = "EXTERNAL"
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

data "google_compute_image" "this" {
  family  = var.image_family
  project = var.image_project
}

resource "google_compute_instance" "this" {
  name         = "${var.cluster_name}-vm"
  project      = var.project_id
  zone         = local.zone
  machine_type = var.machine_type

  tags = ["${var.cluster_name}-educates"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.this.self_link
      size  = var.disk_size_gb
      type  = var.disk_type
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.this.id

    access_config {
      nat_ip = google_compute_address.this.address
    }
  }

  metadata = {
    ssh-keys = "${var.ssh_user}:${tls_private_key.ssh.public_key_openssh}"
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    apt-get update && apt-get install -y docker.io curl jq
    systemctl enable docker && systemctl start docker
    usermod -aG docker ${var.ssh_user}

    # Install kubectl
    curl -fsSL https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl -o /usr/local/bin/kubectl
    chmod +x /usr/local/bin/kubectl

    # Install k9s
    K9S_VERSION=$(curl -fsSL https://api.github.com/repos/derailed/k9s/releases/latest | jq -r '.tag_name')
    curl -fsSL https://github.com/derailed/k9s/releases/download/$${K9S_VERSION}/k9s_Linux_amd64.tar.gz | tar xz -C /usr/local/bin k9s

    # Auto-switch to educates user on login (for GCP web terminal and other users)
    cat > /etc/profile.d/switch-to-educates.sh << 'PROFILE'
    if [ "$(whoami)" != "${var.ssh_user}" ]; then
      exec sudo -i -u ${var.ssh_user}
    fi
    PROFILE

    touch /tmp/startup-complete
  EOF

  allow_stopping_for_update = true

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }
}
