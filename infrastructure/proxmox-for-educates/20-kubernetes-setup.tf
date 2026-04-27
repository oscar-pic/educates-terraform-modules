resource "null_resource" "wait_for_k8s" {
  # We loop this resource just like we did with the VM
  for_each = var.kube_nodes

  # Link it directly to the specific VM it's waiting for
  depends_on = [proxmox_virtual_environment_vm.kube_node]

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      # Pull from the map for THIS specific node
      user        = each.value.vm_user
      # This takes "192.168.1.29/24" and turns it into "192.168.1.29, for example"
      host        = split("/", each.value.ip_address)[0]
      
      # Use the private key to log in
      private_key = file(var.ssh_private_key_path)
    }

    inline = [
      "until [ -f /etc/rancher/k3s/k3s.yaml ]; do sleep 5; done",
      # Ensures the user can actually read the file to SCP it
      "sudo chmod 644 /etc/rancher/k3s/k3s.yaml",
      "echo 'K3s is officially ready on ${each.key}!'"
    ]
  }
  # Pull and localize the config
  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/wait_for_k8s.sh ${var.ssh_private_key_path} ${each.value.vm_user} ${local.k8s_api_endpoint} ${path.module}/k8s_config.yaml"
  }
}

data "local_file" "kubeconfig" {
  # This ensures we don't try to read the file until it has been pulled/sed-ed
  depends_on = [null_resource.wait_for_k8s]
  filename   = "${path.module}/k8s_config.yaml"
}