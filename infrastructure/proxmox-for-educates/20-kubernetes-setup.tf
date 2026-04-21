resource "null_resource" "wait_for_k3s" {
  # We loop this resource just like we did with the VM
  for_each = var.kube_nodes

  # Link it directly to the specific VM it's waiting for
  depends_on = [proxmox_virtual_environment_vm.kube_node]

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      # Pull from the map for THIS specific node
      user        = each.value.vm_user
      # This takes "192.168.1.29/24" and turns it into "192.168.1.29"
      host        = split("/", each.value.ip_address)[0]
      
      # Use the private key to log in
      private_key = file(var.ssh_private_key_path)
    }

    inline = [
      "until [ -f /etc/rancher/k3s/k3s.yaml ]; do sleep 5; done",
      "echo 'K3s is officially ready on ${each.key}!'"
    ]
  }
}