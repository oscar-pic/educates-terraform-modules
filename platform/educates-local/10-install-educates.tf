locals {
  educates_config_yaml = templatefile("${path.module}/templates/educates-config.yaml.tpl", {
    wildcard_domain = var.wildcard_domain
    gcp_project     = var.gcp_project
    dns_zone        = var.dns_zone
  })
}

# Step 1: Wait for the VM startup script to complete (Docker installed)
resource "null_resource" "wait_for_startup" {
  connection {
    type        = "ssh"
    host        = var.ssh_connection.host
    user        = var.ssh_connection.user
    private_key = var.ssh_connection.private_key
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for startup script to complete...'",
      "while [ ! -f /tmp/startup-complete ]; do sleep 5; done",
      "echo 'Startup script completed.'",
    ]
  }
}

# Step 2: Install educates CLI and create the Kind cluster
resource "null_resource" "install_educates" {
  triggers = {
    educates_version = var.educates_version
    config_hash      = sha256(local.educates_config_yaml)
  }

  connection {
    type        = "ssh"
    host        = var.ssh_connection.host
    user        = var.ssh_connection.user
    private_key = var.ssh_connection.private_key
    timeout     = "10m"
  }

  provisioner "file" {
    content     = local.educates_config_yaml
    destination = "/home/${var.ssh_connection.user}/educates-config.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "curl -sL -o /tmp/educates https://github.com/educates/educates-training-platform/releases/download/${var.educates_version}/educates-linux-amd64",
      "chmod +x /tmp/educates",
      "sudo mv /tmp/educates /usr/local/bin/educates",
      "educates completion bash > /etc/bash_completion.d/educates",
      "educates delete-cluster",
      "educates create-cluster --verbose --config /home/${var.ssh_connection.user}/educates-config.yaml 2>&1 | tee /home/${var.ssh_connection.user}/educates-install.log",
    ]
  }

  depends_on = [null_resource.wait_for_startup]
}

# Step 3: Make GCE metadata server reachable from Kind pods so that
# cert-manager and external-dns can authenticate via ADC (Application Default Credentials)
resource "null_resource" "enable_metadata_server" {
  connection {
    type        = "ssh"
    host        = var.ssh_connection.host
    user        = var.ssh_connection.user
    private_key = var.ssh_connection.private_key
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "# Find Kind's Docker network bridge and bind the metadata server IP to it",
      "BRIDGE=$(docker network inspect kind -f '{{(index .Options \"com.docker.network.bridge.name\")}}')",
      "sudo ip addr add 169.254.169.254/32 dev \"$BRIDGE\" || true",
      "echo 'GCE metadata server is now reachable from Kind pods'",
    ]
  }

  depends_on = [null_resource.install_educates]
}
