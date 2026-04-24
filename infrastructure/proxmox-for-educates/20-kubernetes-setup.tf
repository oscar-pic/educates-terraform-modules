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
    command = "bash ${path.module}/wait_k8s.sh ${var.ssh_private_key_path} ${each.value.vm_user} ${local.k8s_api_endpoint} ${path.module}/k8s_config.yaml"
  }
  # provisioner "local-exec" {
  #   command = <<EOT
  #     # 1. Fetch the kubeconfig
  #     scp -o StrictHostKeyChecking=no -q -i ${var.ssh_private_key_path} ${each.value.vm_user}@${local.k8s_api_endpoint}:/etc/rancher/k3s/k3s.yaml ${path.module}/k8s_config.yaml
      
  #     # 2. Patch IP
  #     sed "s|127.0.0.1|${local.k8s_api_endpoint}|g" ${path.module}/k8s_config.yaml > ${path.module}/k8s_config.tmp
  #     mv ${path.module}/k8s_config.tmp ${path.module}/k8s_config.yaml
      
  #     echo "------------------------------------------------------------"
  #     echo "✔ Kubeconfig retrieved and patched."
  #     echo "⏳ Health-checking Kubernetes API at ${local.k8s_api_endpoint}..."
      
  #     # 3. REAL HEALTH CHECK: Loop until 'kubectl get nodes' returns 0 (success)
  #     # We give it a maximum of 10 attempts
  #     MAX_RETRIES=10
  #     COUNT=0
  #     until KUBECONFIG=${path.module}/k8s_config.yaml kubectl get nodes > /dev/null 2>&1 || [ $COUNT -eq $MAX_RETRIES ]; do
  #       echo "API not ready yet... retrying in 10s ($((COUNT+1))/$MAX_RETRIES)"
  #       sleep 10
  #       COUNT=$((COUNT+1))
  #     done

  #     echo "🚀 API is responding! Giving it 30 more seconds for final stabilization..."
  #     sleep 30
  #     echo "------------------------------------------------------------"
  #   EOT
  # }
}

data "local_file" "kubeconfig" {
  # This ensures we don't try to read the file until it has been pulled/sed-ed
  depends_on = [null_resource.wait_for_k8s]
  filename   = "${path.module}/k8s_config.yaml"
}