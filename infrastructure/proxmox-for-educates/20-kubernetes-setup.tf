resource "null_resource" "wait_for_k3s" {
  # This tells Terraform to wait for the VM to be created first
  depends_on = [proxmox_virtual_environment_vm.kube_node]

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = var.vm_user
      # Update: Use the first IP from your new map
      host        = values(var.kube_nodes)[0].ip_address
      private_key = file(var.ssh_private_key_path)
    }

    inline = [
      "until [ -f /etc/rancher/k3s/k3s.yaml ]; do sleep 5; done",
      "echo 'K3s is officially ready!'"
    ]
  }
}