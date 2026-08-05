locals {
  # To Detect choosen flavor
  is_k3s  = var.deployment_flavor == "k3s"

  k3s_tls_secret_name = "traefik-default-cert"

  # Base Map 
  k3s_all_nodes = var.kube_nodes
  k3s_number_of_nodes = length(var.kube_nodes)

  # Only will be fulfilled if we are deploying K3S
  k3s_bootstrap_node_map = var.deployment_flavor == "k3s" ? {
    for k, v in local.k3s_all_nodes : k => v if v.type == "k3s-single-node"
  } : {}

  k3s_api_ip = length(local.k3s_bootstrap_node_map) > 0 ? split("/", var.kube_nodes[keys(local.k3s_bootstrap_node_map)[0]].ip_address)[0] : ""

  # 2. "Clean" final variables
  # Now we simply extract from the map based on the current flavor
  # 🛡️ Using try() avoids evaluation errors when deployment_flavor is "talos"
  k3s_kubeconfig_k8s_cluster_api_ip = try(local.k3s_api_ip, null)
}

###############################################################################
# STEP 1: BOOT AND VALIDATE THE BOOTSTRAP NODE
###############################################################################
resource "null_resource" "k3s_bootstrap" {
  for_each = local.k3s_bootstrap_node_map

  depends_on = [proxmox_virtual_environment_vm.kube_node]

  triggers = {
    # This ID will only change if the VM is destroyed and recreated
    vm_id = proxmox_virtual_environment_vm.kube_node[each.key].id
  }

  connection {
    type        = "ssh"
    user        = each.value.vm_user
    host        = split("/", each.value.ip_address)[0]
    private_key = file(var.ssh_private_key_path)
  }

  provisioner "remote-exec" {

    inline = [
      "set -e",
      # 🛡️ SECURITY BLOCK: Wait to Cloud-Init finish the Ubuntu Upgrade
      "echo '⏳ Checking Cloud-Init status and waiting for Ubuntu apt upgrades to finish...'",
      "sudo cloud-init status --wait || true",
      "echo '✅ Cloud-Init finished! OS is fully updated and unlocked.'",

      "echo '⏳ Installing K3s (Single Node)...'",
      "curl -sfL https://get.k3s.io | sh -",
      "KUBECONFIG_SOURCE=\"/etc/rancher/k3s/k3s.yaml\"",

      "echo '⏳ Waiting for configuration file to be generated...'",
      "until  sudo test -f \"$KUBECONFIG_SOURCE\"; do sleep 5; done",

      "echo 'Generating safe local and external deployment authority assets...'",
      "sudo cp \"$KUBECONFIG_SOURCE\" /tmp/k8s_local.yaml",
      "sudo cp \"$KUBECONFIG_SOURCE\" /tmp/k8s_external.yaml",
      "sudo chown ${each.value.vm_user}:${each.value.vm_user} /tmp/k8s_local.yaml /tmp/k8s_external.yaml",
      "sudo chmod 600 /tmp/k8s_local.yaml /tmp/k8s_external.yaml",
      "sudo sed -i \"s/127.0.0.1/${local.k3s_kubeconfig_k8s_cluster_api_ip}/g\" /tmp/k8s_external.yaml",

      "echo '------------------------------------------------------------'",
      "echo '⏳ Waiting for Core Cluster API to become responsive...'",
      
      # 🚀 FIX 2: Safe, loops-free validation utilizing native kubectl wait mechanics
      "export KUBECONFIG=/tmp/k8s_local.yaml",
      "sleep 20",
      
      "echo '🚀 Local authority file initialized. Verifying cluster engine state...'",
      "/usr/local/bin/kubectl wait --for=condition=Ready nodes --all --timeout=420s || true",

      "echo '------------------------------------------------------------'"
    ]
  }
}

###############################################################################
# STEP 2: DEPLOY CERTIFICATES 
###############################################################################
# This resource handles only the 'provided' strategy uploads
resource "null_resource" "k3s_upload_provided_certs" {
  # This makes the resource disappear if strategy is not 'provided', 
  # preventing the "file not found" error.
  for_each = var.k8s_cert_strategy == "provided" ? local.k3s_bootstrap_node_map : {}

  connection {
    type        = "ssh"
    user        = each.value.vm_user
    host        = split("/", each.value.ip_address)[0]
    private_key = file(var.ssh_private_key_path)
  }

  provisioner "file" {
    # We use k8s_certs_path (the variable we agreed upon)
    source      = "${path.module}/${var.k8s_certs_path}/wildcard.crt"
    destination = "/tmp/wildcard.crt"
  }
  provisioner "file" {
    source      = "${path.module}/${var.k8s_certs_path}/wildcard.key"
    destination = "/tmp/wildcard.key"
  }
}

resource "null_resource" "k3s_certificates_setup" {
  depends_on = [
    null_resource.verify_k3s_cluster_health, # Because we are doing kubectl commands, we'll need to wait all core pods are running
    null_resource.k3s_upload_provided_certs
  ]
  for_each   = local.k3s_bootstrap_node_map
  
  connection {
    type        = "ssh"
    user        = each.value.vm_user
    host        = split("/", each.value.ip_address)[0]
    private_key = file(var.ssh_private_key_path)
  }

  provisioner "file" {
    content     = templatefile("${path.module}/templates/k3s/k3s-traefik-config.yaml.tftpl", {
      secret_name = local.k3s_tls_secret_name
    })
    destination = "/tmp/k3s-traefik-config.yaml"
  }

  # Self-signed Strategy
  provisioner "file" {
    content     = templatefile("${path.module}/templates/common/cert-openssl-config.cnf.tftpl", {
      primary_domain = var.k8s_apps_cert_domains[0],
      domains        = var.k8s_apps_cert_domains
    })
    destination = "/tmp/openssl.cnf"
  }

  # LetsEncrypt Strategy
  provisioner "file" {
    content     = templatefile("${path.module}/templates/common/05-cert-manager-chart.yaml.tftpl", {
      cert_manager_version = var.k8s_cert_manager_version
    })
    destination = "/tmp/05-cert-manager-chart.yaml"
  }
  provisioner "file" {
    content     = templatefile("${path.module}/templates/common/06-cert-letsencrypt-setup.yaml.tftpl", { 
      cert_object_name = "traefik-cert",
      secret_name      = local.k3s_tls_secret_name
      email            = var.k8s_letsencrypt_email 
      dns_api_token    = var.k8s_letsencrypt_dns_provider_api_token
      dns_names        = var.k8s_apps_cert_domains
    })
    destination = "/tmp/06-cert-letsencrypt-setup.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml",
      "sleep 3",

      # --- STRATEGY: PROVIDED ---
      "if [ '${var.k8s_cert_strategy}' = 'provided' ]; then",
      "  echo '📦 Deploying TLS secret with provided certs...'",
      "  sudo kubectl create secret tls ${local.k3s_tls_secret_name} --cert=/tmp/wildcard.crt --key=/tmp/wildcard.key -n kube-system --dry-run=client -o yaml | sudo kubectl apply -f -",
      # --- STRATEGY: SELF-SIGNED ---
      "elif [ '${var.k8s_cert_strategy}' = 'self-signed' ]; then",
      "  echo '⚙️  Generating internal CA and certs...'",
      "  sudo mkdir -p /etc/ssl/k8s-ca",
      "  if [ ! -f /etc/ssl/k8s-ca/ca.key ]; then",
      "    sudo openssl genrsa -out /etc/ssl/k8s-ca/ca.key 4096",
      "    sudo openssl req -x509 -new -nodes -key /etc/ssl/k8s-ca/ca.key -sha256 -days 3650 -out /etc/ssl/k8s-ca/ca.crt -subj '/CN=K8s-Internal-CA'",
      "  fi",
      "  echo '⚙️  Generating wildcard certs using SANs...'",
      "  sudo openssl genrsa -out /etc/ssl/k8s-ca/wildcard.key 2048",
      "  sudo openssl req -new -key /etc/ssl/k8s-ca/wildcard.key -out /etc/ssl/k8s-ca/wildcard.csr -config /tmp/openssl.cnf",
      "  sudo openssl x509 -req -in /etc/ssl/k8s-ca/wildcard.csr -CA /etc/ssl/k8s-ca/ca.crt -CAkey /etc/ssl/k8s-ca/ca.key -CAcreateserial -out /etc/ssl/k8s-ca/wildcard.crt -days 825 -sha256 -extensions v3_req -extfile /tmp/openssl.cnf",
      "  sudo kubectl create secret tls ${local.k3s_tls_secret_name} --cert=/etc/ssl/k8s-ca/wildcard.crt --key=/etc/ssl/k8s-ca/wildcard.key -n kube-system --dry-run=client -o yaml | sudo kubectl apply -f -",
      # --- STRATEGY: LETSENCRYPT ---
      "elif [ '${var.k8s_cert_strategy}' = 'letsencrypt' ]; then",
      "  echo '📦 Deploying Cert-Manager...'",
      "  sudo kubectl apply -f /tmp/05-cert-manager-chart.yaml",
      "  sleep 30",
      "  echo '📦 Deploying Lets Encrypt stuff...'",
      "  sudo kubectl apply -f /tmp/06-cert-letsencrypt-setup.yaml",
      "else",
      "  echo '❌ ERROR: Invalid cert strategy \"${var.k8s_cert_strategy}\". Choose from: provided, self-signed, letsencrypt.'",
      "  exit 1",
      "fi",
      "echo '⚙️  Configuring Traefik TLS store...'",
      "sudo kubectl apply -f /tmp/k3s-traefik-config.yaml",
      "echo '⏳ Waiting for Traefik configuration to be reconciled...'",
      "sleep 10",
      "echo '🔄 Restarting Traefik to apply changes...'",
      "sudo kubectl rollout restart deployment traefik -n kube-system",
      "sleep 10"
    ]
  }
}

###############################################################################
# MAINTENANCE: SAFE REBOOT (Maintains your original logic for all nodes)
###############################################################################
resource "ssh_resource" "k8s_config_k3s" {
  for_each   = local.k3s_bootstrap_node_map
  depends_on = [
    null_resource.k3s_bootstrap
  ]

  user        = each.value.vm_user
  host        = split("/", each.value.ip_address)[0]
  private_key = file(var.ssh_private_key_path)

  commands = [
    "cat /tmp/k8s_external.yaml"
  ]
}

resource "local_file" "save_kubeconfig_k3s" {
  for_each = local.k3s_bootstrap_node_map

  content  = ssh_resource.k8s_config_k3s[each.key].result
  filename = "${path.root}/build/${var.environment}/${var.k8s_cluster_name}/k8s_config.yaml"

}

resource "null_resource" "reboot_k3s_node_needed" {
  for_each = local.k3s_bootstrap_node_map

  # It is executed once the cluster is fully deployed and configured
  depends_on = [
    local_file.save_kubeconfig_k3s
  ]

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
      "  echo '⚠️  WARNING: System restart IS required for Node ${each.key}'",
      "  echo 'To reboot safely, run:'",
      "  echo 'kubectl drain ${each.key} --ignore-daemonsets --delete-emptydir-data'",
      "  echo 'And then: sudo reboot'",
      "  echo 'After reboot, run:'",
      "  echo 'kubectl uncordon ${each.key}'",
      "  sleep 10",
      "else",
      "  echo '✅ No reboot required for this node. Skipping.';",
      "fi",
      "echo '------------------------------------------------------------'",
      "sleep 20"
    ]
  }
}

resource "null_resource" "verify_k3s_service_status" {
  for_each   = local.k3s_bootstrap_node_map
  depends_on = [null_resource.reboot_k3s_node_needed]

  connection {
    type        = "ssh"
    user        = each.value.vm_user
    host        = split("/", each.value.ip_address)[0]
    private_key = file(var.ssh_private_key_path)
    timeout     = "12m"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "SERVICE_NAME='k3s'",

      "echo \"⏳ Waiting for $SERVICE_NAME to start...\"",
      "TIMEOUT=300",
      "ELAPSED=0",
      "until sudo systemctl is-active --quiet \"$SERVICE_NAME\"; do",
      "  if [ \"$ELAPSED\" -ge \"$TIMEOUT\" ]; then",
      "    echo \"❌ ERROR: Kubernetes service ($SERVICE_NAME) failed to start within $TIMEOUT seconds.\"",
      "    exit 1",
      "  fi",
      "  echo \"🔄 Service '$SERVICE_NAME' is still initializing... ($ELAPSED/$TIMEOUT s)\"",
      "  sleep 10",
      "  ELAPSED=$((ELAPSED + 10))",
      "done",
      "echo \"✅ Systemd service ($SERVICE_NAME) is ACTIVE!\"",
      "sleep 10"
    ]
  }
}

resource "null_resource" "verify_k3s_cluster_health" {
  for_each   = local.k3s_bootstrap_node_map
  depends_on = [null_resource.verify_k3s_service_status]

  connection {
    type        = "ssh"
    user        = each.value.vm_user
    host        = split("/", each.value.ip_address)[0]
    private_key = file(var.ssh_private_key_path)
    timeout     = "12m"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "KCONF='/etc/rancher/k3s/k3s.yaml'",

      "echo '⏳ Waiting for API Server...'",
      "until sudo kubectl --kubeconfig $KCONF get nodes >/dev/null 2>&1; do sleep 5; done",
      "echo '✅ API Server is responding!'",
      
      "echo '⏳ Waiting for ALL cluster nodes to report Ready...'",
      "NODE_TIMEOUT=300",
      "NODE_ELAPSED=0",
      "until [ \"$(sudo kubectl --kubeconfig $KCONF get nodes -o jsonpath='{.items[*].status.conditions[?(@.type==\"Ready\")].status}' | grep -o 'True' | wc -l)\" -eq \"${local.k3s_number_of_nodes}\" ]; do",
      "  if [ \"$NODE_ELAPSED\" -ge \"$NODE_TIMEOUT\" ]; then echo '❌ Error: Timeout waiting for nodes.'; exit 1; fi",
      "  echo '🔄 Waiting for all nodes to be Ready...'",
      "  sleep 10",
      "  NODE_ELAPSED=$((NODE_ELAPSED + 10))",
      "done",
      "echo '✅ All nodes are Ready!'",
      "sleep 10",

      "echo '⏳ Checking for Pod stability in kube-system...'",
      "CORE_TIMEOUT=600",
      "CORE_ELAPSED=0",
      "until [ \"$CORE_ELAPSED\" -ge \"$CORE_TIMEOUT\" ]; do",
      "  BAD_PODS=$(sudo kubectl --kubeconfig $KCONF get pods -n kube-system --no-headers 2>/dev/null | grep -v 'helm-install' | grep -vE 'Running|Completed' | wc -l || echo 0)",
      "  NOT_READY_PODS=$(sudo kubectl --kubeconfig $KCONF get pods -n kube-system --field-selector=status.phase=Running --no-headers 2>/dev/null | grep -v 'helm-install' | awk '$2 ~ /0\\// {print $0}' | wc -l || echo 0)",
      
      "  if [ \"$BAD_PODS\" -eq 0 ] && [ \"$NOT_READY_PODS\" -eq 0 ]; then",
      "    echo '✅ All core pods are Running/Completed and Ready!'",
      "    sleep 10",
      "    break",
      "  fi",
      "  echo \"🔄 Waiting... (Bad: $BAD_PODS, Not-Ready: $NOT_READY_PODS). ($CORE_ELAPSED/$CORE_TIMEOUT s)\"",
      "  sleep 15",
      "  CORE_ELAPSED=$((CORE_ELAPSED + 15))",
      "done",
      "if [ \"$CORE_ELAPSED\" -ge \"$CORE_TIMEOUT\" ]; then",
      "  echo '⚠️   WARNING: Core pods are taking longer than expected to report Ready.'",
      "  sleep 10",
      "fi"
    ]
  }
}
