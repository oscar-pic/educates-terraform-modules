resource "null_resource" "wait_for_k8s" {
  # We loop this resource just like we did with the VM
  for_each = var.kube_nodes

  # Link it directly to the specific VM it's waiting for
  depends_on = [proxmox_virtual_environment_vm.kube_node]

  # STEP 1: all the loop and preparation is done in the Linux VM
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
      "set -e",
      "echo '⏳ Waiting for K3s configuration file...'",
      "until [ -f /etc/rancher/k3s/k3s.yaml ]; do sleep 5; done",
      
      "echo 'Patching kubeconfig with external IP...'",
      "sudo cp /etc/rancher/k3s/k3s.yaml /tmp/k3s_external.yaml",
      "sudo chown ${each.value.vm_user}:${each.value.vm_user} /tmp/k3s_external.yaml",
      "chmod 600 /tmp/k3s_external.yaml",
      "sed -i 's/127.0.0.1/${split("/", each.value.ip_address)[0]}/g' /tmp/k3s_external.yaml",

      "echo '------------------------------------------------------------'",
      "echo '✔ Kubeconfig retrieved and patched for localhost'",
      "echo '⏳ Waiting for Cluster to initialize pods...'",
      "MAX_RETRIES=30",
      "COUNT=0",
      "while true; do",
      "  TOTAL_PODS=$(KUBECONFIG=/tmp/k3s_external.yaml /usr/local/bin/kubectl get pods -n kube-system --no-headers 2>/dev/null | wc -l)",
      "  NOT_READY=$(KUBECONFIG=/tmp/k3s_external.yaml /usr/local/bin/kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -vE 'Running|Completed' | wc -l)",
      "  if [ \"$TOTAL_PODS\" -gt 0 ] && [ \"$NOT_READY\" -eq 0 ]; then",
      "    echo \"🚀 System pods are RUNNING ($TOTAL_PODS pods detected)!\";",
      "    break;",
      "  fi",
      "  echo \"Status: Total=$TOTAL_PODS, Waiting=$NOT_READY... retrying in 10s ($((COUNT+1))/$MAX_RETRIES)\"",
      "  sleep 10",
      "  COUNT=$((COUNT+1))",
      "  if [ $COUNT -eq $MAX_RETRIES ]; then",
      "    echo '❌ Timeout waiting for system pods';",
      "    exit 1;",
      "  fi",
      "done",
      "echo '⏳ Final 30s for RBAC stabilization...'",
      "sleep 30",
      "echo '------------------------------------------------------------'"
    ]
  }
}

# STEP 2: Download the file using a Terraform native library (Valid for all Client Platforms)
resource "ssh_resource" "k8s_config" {
  for_each   = var.kube_nodes
  depends_on = [null_resource.wait_for_k8s]

  user        = each.value.vm_user
  host        = split("/", each.value.ip_address)[0]
  private_key = file(var.ssh_private_key_path)

  commands = [
    "cat /tmp/k3s_external.yaml"
  ]
}

resource "local_file" "save_kubeconfig" {
  for_each = var.kube_nodes

  content  = ssh_resource.k8s_config[each.key].result
  filename = "${path.module}/k8s_config.yaml"
}

###############################################################################
# MAINTENANCE: REBOOT IF REQUIRED
###############################################################################

# This resource triggers a safe reboot if Ubuntu updates requires it.
resource "null_resource" "reboot_node" {
  for_each = var.kube_nodes

  # This must run AFTER the cluster is verified and ready, and the kubeconfig file is downloaded to client machine
  depends_on = [local_file.save_kubeconfig]

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = each.value.vm_user
      host        = split("/", each.value.ip_address)[0]
      private_key = file(var.ssh_private_key_path)
    }

    inline = [
      "echo '------------------------------------------------------------'",
      "echo '🔍 Checking for pending reboot on ${split("/", each.value.ip_address)[0]}...'",
      "if [ -f /var/run/reboot-required ]; then",
      "  echo '⚠️  System restart IS required. Initiating reboot now...';",
      # Reboot with a 1m delay in order to SSH connection close correctly with exit code 0
      "  sudo shutdown -r +1 'Terraform OS Update Reboot' &",
      "  echo '⏳ Reboot scheduled. Safe exit from current SSH session...';",
      "else",
      "  echo '   No reboot required for this node. Skipping.';",
      "fi",
      "echo '------------------------------------------------------------'"
    ]
  }
}

# Navite sleeper: to git time to VM to poweroff and boot from BIOS/GRUB
resource "time_sleep" "wait_for_reboot_cycle" {
  depends_on = [null_resource.reboot_node]

  # Internal Terraform pause. Independent of Windows, Linux or Mac.
  create_duration = "70s"
}

resource "null_resource" "verify_node_online" {
  for_each   = var.kube_nodes
  depends_on = [time_sleep.wait_for_reboot_cycle]

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = each.value.vm_user
      host        = split("/", each.value.ip_address)[0]
      private_key = file(var.ssh_private_key_path)
      timeout     = "5m" 
    }

    inline = [
      "echo '✅ Node ${split("/", each.value.ip_address)[0]} is officially back online and responding over SSH!'"
    ]
  }
}