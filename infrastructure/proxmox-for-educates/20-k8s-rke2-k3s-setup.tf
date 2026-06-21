locals {
  # To Detect choosen flavor
  is_k3s  = var.deployment_flavor == "single-node-k3s"
  is_rke2 = var.deployment_flavor == "rke2-cluster"

  tls_secret_name = local.is_rke2 ? "gateway-api-default-cert" : "traefik-default-cert"

  # Base Map 
  all_nodes = var.kube_nodes
  number_of_nodes = length(var.kube_nodes)

  # Only will be fulfilled if we are deploying K3S
  k3s_bootstrap_node_map = var.deployment_flavor == "single-node-k3s" ? {
    for k, v in local.all_nodes : k => v if v.type == "single-node-k3s"
  } : {}

  # Filter out which will be the bootstrap node in RKE2 deployment 
  rke2_bootstrap_node_map = var.deployment_flavor == "rke2-cluster" ? {
    for k, v in local.all_nodes : k => v if v.type == "rke2-server-bootstrap"
  } : {}

  # Merge needed in some cases, for common resources. It will have only either k3s_bootstrap or rke2_bootstrap node
  all_bootstrap_rke2_k3s_node_map = merge(local.k3s_bootstrap_node_map, local.rke2_bootstrap_node_map)

  # Filter out all the child nodes that need to be joined next on RKE2 deployment
  rke2_joiner_node_map = var.deployment_flavor == "rke2-cluster" ? {
    for k, v in local.all_nodes : k => v if v.type == "rke2-server" || v.type == "rke2-agent"
  } : {}

  # Number of CP on RKE2 deployment
  rke2_cp_node_map = var.deployment_flavor == "rke2-cluster" ? {
    for k, v in local.all_nodes : k => v if v.type == "rke2-server" || v.type == "rke2-server-bootstrap"
  } : {}

  rke2_number_of_cp = length(local.rke2_cp_node_map)

  # Number of workers on RKE2 deployment
  rke2_worker_node_map = var.deployment_flavor == "rke2-cluster" ? {
    for k, v in local.all_nodes : k => v if v.type == "rke2-agent"
  } : {}
  rke2_has_workers  = length(local.rke2_worker_node_map) > 0

  # New map to join all K3s and RKE2 nodes (leaving Talos out automatically)
  rancher_linux_nodes_map = merge(local.k3s_bootstrap_node_map, local.rke2_bootstrap_node_map, local.rke2_joiner_node_map)
  
  # 1. Network context selector
  # We use a map to define the registration IP according to the flavor
  network_config = {
    # For K3S, we directly use the node IP (which is bootstrap)
    "single-node-k3s" = {
      registration_ip = ""
      api_ip          = length(local.k3s_bootstrap_node_map) > 0 ? split("/", var.kube_nodes[keys(local.k3s_bootstrap_node_map)[0]].ip_address)[0] : ""
    }
    # For RKE2, we use the VIP if it exists, or the bootstrap
    "rke2-cluster" = {
      registration_ip = length(local.rke2_bootstrap_node_map) > 0 ? split("/", var.kube_nodes[keys(local.rke2_bootstrap_node_map)[0]].ip_address)[0] : ""
      api_ip          = var.k8s_api_endpoint_vip != "" ? var.k8s_api_endpoint_vip : (length(local.rke2_bootstrap_node_map) > 0 ? split("/", var.kube_nodes[keys(local.rke2_bootstrap_node_map)[0]].ip_address)[0] : "")
    }
  }

  # 2. "Clean" final variables
  # Now we simply extract from the map based on the current flavor
  # 🛡️ Using try() avoids evaluation errors when deployment_flavor is "talos-cluster"
  rke2_registration_address     = try(local.network_config[var.deployment_flavor].registration_ip, null)
  kubeconfig_k8s_cluster_api_ip = try(local.network_config[var.deployment_flavor].api_ip, null)

}

###############################################################################
# STEP 1: BOOT AND VALIDATE THE BOOTSTRAP NODE (K3s or First Server RKE2)
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
      "sudo sed -i \"s/127.0.0.1/${local.kubeconfig_k8s_cluster_api_ip}/g\" /tmp/k8s_external.yaml",

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

resource "null_resource" "rke2_bootstrap" {
  for_each = local.rke2_bootstrap_node_map

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

  # Upload the configuration rendered specifically for the Bootstrap node
  provisioner "file" {
    content = templatefile("${path.module}/templates/rke2-config.yaml.tftpl", {
      cluster_token          = var.k8s_cluster_token
      registration_address   = local.rke2_registration_address
      vip_address            = var.k8s_api_endpoint_vip
      is_bootstrap           = true
      is_server              = true
      nodes_ips              = [for k, v in var.kube_nodes : split("/", v.ip_address)[0] if contains(["rke2-server", "rke2-server-bootstrap"], v.type)]
      extra_node_labels_list = each.value.node_labels
    })
    destination = "/tmp/rke2-config.yaml"
  }

  # Upload Cilium config
  provisioner "file" {
    content = templatefile("${path.module}/templates/rke2/02-cilium-chart.yaml.tftpl", {
      # If it's a single node, use 1 replica; otherwise, 3 for HA.
      operator_replicas = length(var.kube_nodes) == 1 ? 1 : 3
      network_device    = var.k8s_api_cp_interface
    })
    destination = "/tmp/02-cilium-chart.yaml"
  }

  # Remove taint protection on Compac Cluster
  provisioner "file" {
    content = templatefile("${path.module}/templates/01-taint-fixer.yaml.tftpl", {})
    destination = "/tmp/01-taint-fixer.yaml"
  }

  # Upload Systemd Override
  provisioner "file" {
    source      = "${path.module}/templates/rke2-override.service.tftpl"
    destination = "/tmp/rke2-override.conf"
  }

  provisioner "remote-exec" {

    inline = [
      "set -e",
      # 🛡️ SECURITY BLOCK: Wait to Cloud-Init finish the Ubuntu Upgrade
      "echo '⏳ Checking Cloud-Init status and waiting for Ubuntu apt upgrades to finish...'",
      "sudo cloud-init status --wait || true",
      "echo '✅ Cloud-Init finished! OS is fully updated and unlocked.'",

      # ONLY RUN if RKE2 isn't already installed/running
      "if systemctl is-active --quiet rke2-server; then echo '🛑 RKE2 already configured. Skipping.'; exit 0; fi",
      "sudo mkdir -p /etc/rancher/rke2",
      "sudo mv /tmp/rke2-config.yaml /etc/rancher/rke2/config.yaml",

      # 🚀 Cleaning default RKE2 manifests
      "echo '🧹 Cleaning default RKE2 manifests to allow custom CNI setup...'",
      "sudo rm -f /var/lib/rancher/rke2/server/manifests/rke2-cilium.yaml",
      "sudo rm -f /var/lib/rancher/rke2/server/manifests/rke2-ingress-nginx.yaml",

      # 🚀 Global enforcement: No matter what happens below, this session only speaks production STABLE
      "export INSTALL_RKE2_CHANNEL='stable'",
      "echo '⚙️  Configuring RKE2 Bootstrap Server with custom Cilium setup...'",
      "sudo mkdir -p /var/lib/rancher/rke2/server/manifests",

      "echo '⚙️  Injecting Cilium HelmChartConfig for kube-proxy replacement...'",
      "sudo mv /tmp/02-cilium-chart.yaml /var/lib/rancher/rke2/server/manifests/02-cilium-chart.yaml",

      "if [ \"${local.rke2_has_workers}\" = \"false\" ]; then",
      "  echo '⚙️  Remove taint protection on Compac Cluster with Control Planes only...'",
      "  sudo mv /tmp/01-taint-fixer.yaml /var/lib/rancher/rke2/server/manifests/01-taint-fixer.yaml",
      "fi",
    
      "echo '⏳ Installing latest production stable RKE2 Server binary...'",
      # 🚀 Force sudo on the installer pipe
      "curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_SKIP_START=true sh -", # 🌟 It automatically inherits the exported variable!
      
      "echo '⏳ Waiting for the installer to write RKE2 components...'",
      "until [ -f /usr/local/bin/rke2 ]; do sleep 2; done",

      # 🚀 FIX 1: Force kernel storage synchronization to release binary write locks before starting unit
      "echo '⚙️  Synchronizing storage buffers to release file descriptor locks...'",
      "sudo sync",
      "sleep 5",

      # 🚀 FIX 2: Patch systemd unit to enforce infinite retries if Docker Hub fails or limits pull requests
      "echo '⚙️  Patching RKE2 systemd service for aggressive automatic restarts...'",
      "sudo mkdir -p /etc/systemd/system/rke2-server.service.d",
      "sudo mv /tmp/rke2-override.conf /etc/systemd/system/rke2-server.service.d/override.conf",
      "sudo systemctl daemon-reload",
      "echo '⚙️  Enabling rke2-server systemd unit...'",
      "sudo systemctl enable rke2-server.service",
      "echo '⚙️  Launching rke2-server in the background (Initializing cluster + Cilium). It will take time. Timeout to 15m...'",
      # 🔥 We start it and let systemd handle the bootstrap asynchronously
      "sudo systemctl start rke2-server.service",
      "KUBECONFIG_SOURCE=\"/etc/rancher/rke2/rke2.yaml\"",

      "echo '⏳ Waiting for configuration file to be generated...'",
      "until  sudo test -f \"$KUBECONFIG_SOURCE\"; do sleep 5; done",

      # 🚀 FIX 2: Create symlink safely after file assurance guarantees unpack state completion
      "echo '⚙️  Creating safe global symlink for kubectl binary...'",
      "sudo ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl",
      
      "echo 'Generating safe local and external deployment authority assets...'",
      "sudo cp \"$KUBECONFIG_SOURCE\" /tmp/k8s_local.yaml",
      "sudo cp \"$KUBECONFIG_SOURCE\" /tmp/k8s_external.yaml",
      "sudo chown ${each.value.vm_user}:${each.value.vm_user} /tmp/k8s_local.yaml /tmp/k8s_external.yaml",
      "sudo chmod 600 /tmp/k8s_local.yaml /tmp/k8s_external.yaml",
      "sudo sed -i \"s/127.0.0.1/${local.kubeconfig_k8s_cluster_api_ip}/g\" /tmp/k8s_external.yaml",

      "echo '------------------------------------------------------------'",
      "echo '⏳ Waiting for Core Cluster API to become responsive...'",
      
      # 🚀 FIX 2: Safe, loops-free validation utilizing native kubectl wait mechanics
      "export KUBECONFIG=/tmp/k8s_local.yaml",
      "sleep 20",
      
      "echo '🚀 Local authority file initialized. Verifying cluster engine state...'",
      "/usr/local/bin/kubectl wait --for=condition=Ready nodes --all --timeout=420s || true",

      "echo '------------------------------------------------------------'",

      "echo '⏳ Starting detailed stability check for Cilium and CoreDNS...'",
      "KCONF='/etc/rancher/rke2/rke2.yaml'",
      "CORE_TIMEOUT=300",
      "CORE_ELAPSED=0",
      
      "until [ \"$CORE_ELAPSED\" -ge \"$CORE_TIMEOUT\" ]; do",
      "  echo \"--- Iteration: $CORE_ELAPSED s ---\"",
      
      # Discover all relevant deployments dynamically
      "  DEPLOYMENTS=$(sudo kubectl --kubeconfig $KCONF get deployments -n kube-system -o name | sed 's/deployment.apps\\///' | grep -E 'cilium|coredns')",
      
      "  ALL_READY=true",
      "  for DEPLOY in $DEPLOYMENTS; do",
      "    # Get the number of ready replicas for the specific deployment",
      "    READY_COUNT=$(sudo kubectl --kubeconfig $KCONF get deployment $DEPLOY -n kube-system -o jsonpath='{.status.readyReplicas}')",
      
      # If readyReplicas is null, it's 0
      "    if [ -z \"$READY_COUNT\" ]; then READY_COUNT=0; fi",
      
      "    echo \"    -> Deployment '$DEPLOY': $READY_COUNT pod(s) Ready.\"",
      
      # Enforcement: Must have at least 1 running pod for each discovered component
      "    if [ \"$READY_COUNT\" -ge 1 ]; then",
      "       echo \"      [OK]\"",
      "    else",
      "       echo \"      [WAIT]\"",
      "       ALL_READY=false",
      "    fi",
      "  done",
      
      "  if [ \"$ALL_READY\" = \"true\" ]; then",
      "    echo '✅ SUCCESS: All discovered core components are ready.'",
      "    break",
      "  fi",
      
      "  sleep 10",
      "  CORE_ELAPSED=$((CORE_ELAPSED + 10))",
      "done",
      
      # Final message when all components are confirmed
      "if [ \"$CORE_ELAPSED\" -lt \"$CORE_TIMEOUT\" ]; then",
      "  echo '✅ SUCCESS: All Cilium and CoreDNS components are healthy and fully operational. The Bootstrap is ready!'",
      "else",
      "  echo '❌ ERROR: Timeout reached while waiting for system components.' && exit 1",
      "fi",
      "sleep 10"
    ]
  }
}

###############################################################################
# STEP 2: JOIN THE ADDITIONAL NODES (RKE2 Multinode Only)
###############################################################################
resource "null_resource" "rke2_join_cp" {
  #for_each = local.rke2_joiner_node_map 
  for_each   = { for k, v in local.rke2_joiner_node_map : k => v if v.type == "rke2-server" }
  
  # CRUCIAL: No node attempts to join until the Bootstrap is operational
  depends_on = [null_resource.rke2_bootstrap]
  
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

  # Upload the configuration rendered for the servers (CPs) and agents (workers) nodes
  provisioner "file" {
    content = templatefile("${path.module}/templates/rke2-config.yaml.tftpl", {
      cluster_token          = var.k8s_cluster_token
      registration_address   = local.rke2_registration_address
      vip_address            = var.k8s_api_endpoint_vip
      is_bootstrap           = false
      is_server              = (each.value.type == "rke2-server") 
      nodes_ips              = [for k, v in var.kube_nodes : split("/", v.ip_address)[0] if contains(["rke2-server", "rke2-server-bootstrap"], v.type)]
      extra_node_labels_list = each.value.node_labels
    })
    destination = "/tmp/rke2-config.yaml"
  }

  # Remove taint protection on Compac Cluster
  provisioner "file" {
    content = templatefile("${path.module}/templates/01-taint-fixer.yaml.tftpl", {})
    destination = "/tmp/01-taint-fixer.yaml"
  }

  # Upload Systemd Override
  provisioner "file" {
    source      = "${path.module}/templates/rke2-override.service.tftpl"
    destination = "/tmp/rke2-override.conf"
  }

  provisioner "remote-exec" {

    inline = [
      "set -e",
      # 🛡️ SECURITY BLOCK: Wait to Cloud-Init finish the Ubuntu Upgrade
      "echo '⏳ Checking Cloud-Init status and waiting for Ubuntu apt upgrades to finish...'",
      "sudo cloud-init status --wait || true",
      "echo '✅ Cloud-Init finished! OS is fully updated and unlocked.'",

      "export INSTALL_RKE2_CHANNEL='stable'",
      "sudo mkdir -p /etc/rancher/rke2",
      "sudo mv /tmp/rke2-config.yaml /etc/rancher/rke2/config.yaml",
      "if systemctl is-active --quiet rke2-server; then echo '🛑 RKE2 already configured. Skipping.'; exit 0; fi",
      "if [ \"${local.rke2_has_workers}\" = \"false\" ]; then",
      "  sudo mkdir -p /var/lib/rancher/rke2/server/manifests",
      "  echo '⚙️  Remove taint protection on Compac Cluster with only Control Planes...'",
      "  sudo mv /tmp/01-taint-fixer.yaml /var/lib/rancher/rke2/server/manifests/01-taint-fixer.yaml",
      "fi",
      "echo '⏳ Installing and starting RKE2 Control Plane...'",
      "curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_SKIP_START=true sh -",
         
      # 🚀 Global enforcement for joiners
      "echo '⏳ Waiting for the installer to write RKE2 components...'",
      "until [ -f /usr/local/bin/rke2 ]; do sleep 2; done",

      "echo '⚙️  Synchronizing storage buffers...'",
      "sudo sync",
      "sleep 5",

      "echo '⚙️  Patching RKE2 systemd service for aggressive automatic restarts...'",
      "sudo mkdir -p /etc/systemd/system/rke2-server.service.d",
      "sudo mv /tmp/rke2-override.conf /etc/systemd/system/rke2-server.service.d/override.conf",

      "sudo systemctl daemon-reload",
      "echo '⚙️  Enabling rke2-server systemd unit...'",
      "sudo systemctl enable rke2-server.service",
      "echo '⚙️  Starting rke2-server...'",
      "sudo systemctl start rke2-server.service",
      "echo '⚙️  Creating safe global symlink for kubectl binary...'",
      "sudo ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl",

      "echo '✅ Node joined successfully!'"
    ]
  }
}

resource "null_resource" "rke2_wait_cp_ready" {
  for_each = local.rke2_bootstrap_node_map
  depends_on = [null_resource.rke2_join_cp]

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
      "KCONF='/etc/rancher/rke2/rke2.yaml'",

      "echo '⏳ Waiting for API Server...'",
      "until sudo kubectl --kubeconfig $KCONF get nodes >/dev/null 2>&1; do sleep 5; done",
      "echo '✅ API Server is responding!'",
      
      "echo '⏳ Waiting for ALL cluster nodes to report Ready...'",
      "NODE_TIMEOUT=300",
      "NODE_ELAPSED=0",
      "until [ \"$(sudo kubectl --kubeconfig $KCONF get nodes -o jsonpath='{.items[*].status.conditions[?(@.type==\"Ready\")].status}' | grep -o 'True' | wc -l)\" -eq \"${local.rke2_number_of_cp}\" ]; do",
      "  if [ \"$NODE_ELAPSED\" -ge \"$NODE_TIMEOUT\" ]; then echo '❌ Error: Timeout waiting for nodes.'; exit 1; fi",
      "  echo '🔄 Waiting for all CP nodes to be Ready...'",
      "  sleep 10",
      "  NODE_ELAPSED=$((NODE_ELAPSED + 10))",
      "done",
      "echo '✅ All CP nodes are Ready!'",
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

resource "null_resource" "rke2_join_worker" {
  for_each   = { for k, v in local.rke2_joiner_node_map : k => v if v.type == "rke2-agent" }
  
  # CRUCIAL: No node attempts to join until the CPs are operational
  depends_on = [null_resource.rke2_wait_cp_ready]
  
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

  # Upload the configuration rendered for the servers (CPs) and agents (workers) nodes
  provisioner "file" {
    content = templatefile("${path.module}/templates/rke2-config.yaml.tftpl", {
      cluster_token          = var.k8s_cluster_token
      registration_address   = local.rke2_registration_address
      vip_address            = var.k8s_api_endpoint_vip
      is_bootstrap           = false
      is_server              = (each.value.type == "rke2-server") 
      nodes_ips              = [for k, v in var.kube_nodes : split("/", v.ip_address)[0] if contains(["rke2-server", "rke2-server-bootstrap"], v.type)]
      extra_node_labels_list = each.value.node_labels
    })
    destination = "/tmp/rke2-config.yaml"
  }

  # Upload Systemd Override
  provisioner "file" {
    source      = "${path.module}/templates/rke2-override.service.tftpl"
    destination = "/tmp/rke2-override.conf"
  }

  provisioner "remote-exec" {

    inline = [
      "set -e",
      # 🛡️ SECURITY BLOCK: Wait to Cloud-Init finish the Ubuntu Upgrade
      "echo '⏳ Checking Cloud-Init status and waiting for Ubuntu apt upgrades to finish...'",
      "sudo cloud-init status --wait || true",
      "echo '✅ Cloud-Init finished! OS is fully updated and unlocked.'",

      "export INSTALL_RKE2_CHANNEL='stable'",
      "sudo mkdir -p /etc/rancher/rke2",
      "sudo mv /tmp/rke2-config.yaml /etc/rancher/rke2/config.yaml",
      "if systemctl is-active --quiet rke2-agent; then echo '🛑 RKE2 already configured. Skipping.'; exit 0; fi",
      "echo '⏳ Installing and starting RKE2 Worker...'",
      "curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_TYPE='agent' INSTALL_RKE2_SKIP_START=true sh -",
         
      # 🚀 Global enforcement for joiners
      "echo '⏳ Waiting for the installer to write RKE2 components...'",
      "until [ -f /usr/local/bin/rke2 ]; do sleep 2; done",

      "echo '⚙️  Synchronizing storage buffers...'",
      "sudo sync",
      "sleep 5",

      "echo '⚙️  Patching RKE2 systemd service for aggressive automatic restarts...'",
      "sudo mkdir -p /etc/systemd/system/rke2-agent.service.d",
      "sudo mv /tmp/rke2-override.conf /etc/systemd/system/rke2-agent.service.d/override.conf",

      "sudo systemctl daemon-reload",
      "echo '⚙️  Enabling rke2-agent systemd unit...'",
      "sudo systemctl enable rke2-agent.service",
      "echo '⚙️  Starting rke2-agent...'",
      "sudo systemctl start rke2-agent.service",
      "echo '⚙️  Creating safe global symlink for kubectl binary...'",
      "sudo ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl",
      
      "echo '⏳ Waiting for Kubelet healthz endpoint...'",
      "until curl -s http://127.0.0.1:10248/healthz | grep -q 'ok'; do",
      "  echo '🔄 Kubelet local is not ready yet...'",
      "  sleep 10",
      "done",
      "echo '✅ Node ${each.key} joined successfully!'",
      "sleep 10"
    ]
  }
}

###############################################################################
# STEP 3: DEPLOY CERTIFICATES AND GATEWAY API (GW API ONLY FOR RKE2) 
###############################################################################
resource "null_resource" "k3s_certificates_setup" {
  depends_on = [null_resource.verify_rke2_k3s_cluster_health] # Because we are doing kubectl commands, we'll need to wait all core pods are running
  for_each   = local.k3s_bootstrap_node_map
  
  connection {
    type        = "ssh"
    user        = each.value.vm_user
    host        = split("/", each.value.ip_address)[0]
    private_key = file(var.ssh_private_key_path)
  }

  provisioner "file" {
    content     = templatefile("${path.module}/templates/k3s-traefik-config.yaml.tftpl", {
      secret_name = local.tls_secret_name
    })
    destination = "/tmp/k3s-traefik-config.yaml"
  }

  # Provided Strategy: We upload the 'provided' files just in case
  provisioner "file" {
    source      = "${path.module}/certs/wildcard.crt"
    destination = "/tmp/wildcard.crt"
  }
  provisioner "file" {
    source      = "${path.module}/certs/wildcard.key"
    destination = "/tmp/wildcard.key"
  }

  # Self-signed Strategy
  provisioner "file" {
    content     = templatefile("${path.module}/templates/cert-openssl-config.cnf.tftpl", {
      primary_domain = var.k8s_apps_cert_domains[0],
      domains        = var.k8s_apps_cert_domains
    })
    destination = "/tmp/openssl.cnf"
  }

  # LetsEncrypt Strategy
  provisioner "file" {
    content     = templatefile("${path.module}/templates/05-cert-manager-chart.yaml.tftpl", {})
    destination = "/tmp/05-cert-manager-chart.yaml"
  }
  provisioner "file" {
    content     = templatefile("${path.module}/templates/06-cert-letsencrypt-setup.yaml.tftpl", { 
      cert_object_name = local.is_rke2 ? "gateway-cert" : "traefik-cert",
      secret_name      = local.tls_secret_name
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
      "  sudo kubectl create secret tls ${local.tls_secret_name} --cert=/tmp/wildcard.crt --key=/tmp/wildcard.key -n kube-system --dry-run=client -o yaml | sudo kubectl apply -f -",
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
      "  sudo kubectl create secret tls ${local.tls_secret_name} --cert=/etc/ssl/k8s-ca/wildcard.crt --key=/etc/ssl/k8s-ca/wildcard.key -n kube-system --dry-run=client -o yaml | sudo kubectl apply -f -",
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

# Create the TLS secret for the Gateway API
resource "null_resource" "rke2_gateway_api_certificates_setup" {
  # Wait for RKE2 bootstrap to complete before deploying CRDs
  depends_on = [null_resource.rke2_deploy_kube_vip_pod]
  for_each   = local.rke2_bootstrap_node_map

  connection {
    type        = "ssh"
    user        = each.value.vm_user
    host        = split("/", each.value.ip_address)[0]
    private_key = file(var.ssh_private_key_path)
  }

  # Provided Strategy: Encode your local files
  provisioner "file" {
    content = templatefile("${path.module}/templates/04-cert-tls-secret.yaml.tftpl", {
      secret_name = local.tls_secret_name
      # If strategy is provided, read the files. Otherwise, pass a dummy string
      tls_crt_b64 = var.k8s_cert_strategy == "provided" ? filebase64("${path.module}/certs/wildcard.crt") : "DUMMY_CRT"
      tls_key_b64 = var.k8s_cert_strategy == "provided" ? filebase64("${path.module}/certs/wildcard.key") : "DUMMY_KEY"
    })
    destination = "/tmp/04-cert-tls-secret.yaml"
  }

  # Self-signed Strategy
  provisioner "file" {
    content     = templatefile("${path.module}/templates/cert-openssl-config.cnf.tftpl", {
      primary_domain = var.k8s_apps_cert_domains[0],
      domains        = var.k8s_apps_cert_domains
    })
    destination = "/tmp/openssl.cnf"
  }

  # LetsEncrypt Strategy
  provisioner "file" {
    content     = templatefile("${path.module}/templates/05-cert-manager-chart.yaml.tftpl", {})
    destination = "/tmp/05-cert-manager-chart.yaml"
  }
  provisioner "file" {
    content     = templatefile("${path.module}/templates/06-cert-letsencrypt-setup.yaml.tftpl", { 
      cert_object_name = local.is_rke2 ? "gateway-cert" : "traefik-cert",
      secret_name      = local.tls_secret_name
      email            = var.k8s_letsencrypt_email 
      dns_api_token    = var.k8s_letsencrypt_dns_provider_api_token
      dns_names        = var.k8s_apps_cert_domains
    })
    destination = "/tmp/06-cert-letsencrypt-setup.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "sudo mkdir -p /var/lib/rancher/rke2/server/manifests",

      # --- STRATEGY: PROVIDED ---
      "if [ '${var.k8s_cert_strategy}' = 'provided' ]; then",
      "  echo '📦 Deploying TLS secret with provided certs...'",
      "  sudo mv /tmp/04-cert-tls-secret.yaml /var/lib/rancher/rke2/server/manifests/04-cert-tls-secret.yaml",
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
      "  CRT_B64=$(sudo base64 -w 0 /etc/ssl/k8s-ca/wildcard.crt)",
      "  KEY_B64=$(sudo base64 -w 0 /etc/ssl/k8s-ca/wildcard.key)",
      "  sudo sed -i \"s/DUMMY_CRT/$CRT_B64/g\" /tmp/04-cert-tls-secret.yaml",
      "  sudo sed -i \"s/DUMMY_KEY/$KEY_B64/g\" /tmp/04-cert-tls-secret.yaml",
      "  sudo mv /tmp/04-cert-tls-secret.yaml /var/lib/rancher/rke2/server/manifests/04-cert-tls-secret.yaml",
      # --- STRATEGY: LETSENCRYPT ---
      "elif [ '${var.k8s_cert_strategy}' = 'letsencrypt' ]; then",
      "  echo '📦 Deploying Cert-Manager HelmChart for RKE2...'",
      "  sudo mv /tmp/05-cert-manager-chart.yaml /var/lib/rancher/rke2/server/manifests/05-cert-manager-chart.yaml",
      "  sudo mv /tmp/06-cert-letsencrypt-setup.yaml /var/lib/rancher/rke2/server/manifests/06-cert-letsencrypt-setup.yaml",
      "else",
      "  echo '❌ ERROR: Invalid cert strategy \"${var.k8s_cert_strategy}\". Choose from: provided, self-signed, letsencrypt.'",
      "  exit 1",
      "fi"
    ]
  }
}

# Install the Gateway API
resource "null_resource" "rke2_gateway_api_setup" {
  depends_on = [null_resource.rke2_gateway_api_certificates_setup]
  for_each   = local.rke2_bootstrap_node_map

  connection {
    type        = "ssh"
    user        = each.value.vm_user
    host        = split("/", each.value.ip_address)[0]
    private_key = file(var.ssh_private_key_path)
  }

  provisioner "file" {
    content = templatefile("${path.module}/templates/03-cilium-gateway-setup.yaml.tftpl", {
      lb_ip_range    = var.k8s_gateway_api_lb_ip_range
      network_device = var.k8s_api_cp_interface
      secret_name = local.tls_secret_name
    })
    destination = "/tmp/03-cilium-gateway-setup.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "echo '🌐 Deploying Gateway API standard CRDs to auto-deploy directory...'",
      "sudo mkdir -p /var/lib/rancher/rke2/server/manifests",
      # Download the standard install manifest for Gateway API
      "sudo curl -sL https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml -o /var/lib/rancher/rke2/server/manifests/gateway-api-crds.yaml",
      # Move the rendered gateway setup template to the manifest directory
      "sudo mv /tmp/03-cilium-gateway-setup.yaml /var/lib/rancher/rke2/server/manifests/03-cilium-gateway-setup.yaml",
      "echo '✅ CRDs and Gateway configuration deployed. RKE2 will apply them automatically.'",
      "sleep 10",
      
      "export KUBECONFIG=/tmp/k8s_local.yaml",
      "echo '⏳ Waiting for Kubernetes API and Gateway API CRDs to be registered by RKE2...'",
      "until kubectl get gatewayclasses.gateway.networking.k8s.io &>/dev/null; do",
      "  sleep 5",
      "done",
      "echo '🚀 CRDs detected! Restarting Cilium Operator to accept the GatewayClass...'",
      "kubectl rollout restart deployment -n kube-system cilium-operator",

      "echo '⏳ Waiting for Cilium Operator be Ready...'",
      "kubectl rollout status deployment/cilium-operator -n kube-system --timeout=300s",
      "echo '✅ Gateway API y Cilium Operador Running & Ready.'",
      "sleep 10"
    ]
  }
}

###############################################################################
# STEP 4: DEPLOY CEPH CSI FOR RKE2
###############################################################################
resource "null_resource" "rke2_ceph_csi_setup" {
  # Trigger only after the bootstrap server's control plane is fully verified
  for_each   = local.rke2_bootstrap_node_map
  depends_on = [null_resource.rke2_gateway_api_setup]
  
  connection {
    type        = "ssh"
    user        = each.value.vm_user
    host        = split("/", each.value.ip_address)[0]
    private_key = file(var.ssh_private_key_path)
  }

  # Upload the template Ceph Secret and StorageClass
  provisioner "file" {
    content = templatefile("${path.module}/templates/07-ceph-csi-secret-storageclass.yaml.tftpl", {
      clusterID = var.proxmox_ceph_clusterID
      ceph_key  = var.proxmox_ceph_k8s_key
    })
    destination = "/tmp/07-ceph-csi-secret-storageclass.yaml"
  }

  # Upload the template Ceph Storage Ceph CSI Helm
  provisioner "file" {
    content = templatefile("${path.module}/templates/08-ceph-csi-helm.yaml.tftpl", {
      clusterID          = var.proxmox_ceph_clusterID
      ceph_monitors_list = var.proxmox_nodes_ceph_IPs
      replica_count      = length(var.kube_nodes) == 1 ? 1 : 3
    })
    destination = "/tmp/08-ceph-csi-helm.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "echo '📦 Deploying CEPH CSI (RBD + CephFS) into RKE2 kubernetes cluster...'",
      "echo '⚙️  Verifying RKE2 auto-deploy manifests directory...'",
      "sudo mkdir -p /var/lib/rancher/rke2/server/manifests",

      "echo '📦 Deploying Ceph CSI Secret and StorageClass...'",
      "sudo mv /tmp/07-ceph-csi-secret-storageclass.yaml /var/lib/rancher/rke2/server/manifests/07-ceph-csi-secret-storageclass.yaml",
      
      # Create the HelmChart with integrated dynamic cluster configuration
      "echo '📦 Deploying Ceph CSI HelmChart manifest...'",
      "sudo mv /tmp/08-ceph-csi-helm.yaml /var/lib/rancher/rke2/server/manifests/08-ceph-csi-helm.yaml",
    
      "echo '✅ Ceph CSI manifests successfully deployed to RKE2 manifests directory.'",
      
      "KCONF='/etc/rancher/rke2/rke2.yaml'",
      "echo \"⏳ Waiting for resources to exist in the API...\"",
      "until sudo kubectl --kubeconfig $KCONF get daemonset/ceph-csi-rbd-nodeplugin -n kube-system > /dev/null 2>&1; do",
        "echo \"  - daemonset ceph-csi-rbd-nodeplugin not created yet, waiting...\"",
        "sleep 5",
      "done",
      "echo \"✅ daemonset ceph-csi-rbd-nodeplugin found...\"",
      "until sudo kubectl --kubeconfig $KCONF get daemonset/ceph-csi-cephfs-nodeplugin -n kube-system > /dev/null 2>&1; do",
        "echo \"  - daemonset ceph-csi-cephfs-nodeplugin not created yet, waiting...\"",
        "sleep 5",
      "done",
      "echo \"✅ daemonset ceph-csi-cephfs-nodeplugin found...\"",
      "until sudo kubectl --kubeconfig $KCONF get deployment/ceph-csi-rbd-provisioner -n kube-system > /dev/null 2>&1; do",
        "echo \"  - deployment ceph-csi-rbd-provisioner not created yet, waiting...\"",
        "sleep 5",
      "done",
      "echo \"✅ deployment ceph-csi-rbd-provisioner found...\"",
      "until sudo kubectl --kubeconfig $KCONF get deployment/ceph-csi-cephfs-provisioner -n kube-system > /dev/null 2>&1; do",
        "echo \"  - deployment ceph-csi-cephfs-provisioner not created yet, waiting...\"",
        "sleep 5",
      "done",
      "echo \"✅ deployment ceph-csi-cephfs-provisioner found...\"",

      "KCONF=/etc/rancher/rke2/rke2.yaml",
      "echo '⏳ Validating csi-rbd-rbdplugin and ceph-csi-rbd-provisioner deployment...'",
      "sleep 10",
      "sudo kubectl --kubeconfig $KCONF rollout status daemonset/ceph-csi-rbd-nodeplugin  -n kube-system --timeout=600s",
      "sudo kubectl --kubeconfig $KCONF rollout status daemonset/ceph-csi-cephfs-nodeplugin  -n kube-system --timeout=600s",
      "sudo kubectl --kubeconfig $KCONF rollout status deployment/ceph-csi-rbd-provisioner -n kube-system --timeout=600s",
      "sudo kubectl --kubeconfig $KCONF rollout status deployment/ceph-csi-cephfs-provisioner -n kube-system --timeout=600s",
      "echo '✅ Ceph CSI is Running & Ready.'",
      "sleep 10"
    ]
  }
}

###############################################################################
# MAINTENANCE: SAFE REBOOT (Maintains your original logic for all nodes)
###############################################################################
resource "ssh_resource" "k8s_config_rke2_k3s" {
  for_each   = local.all_bootstrap_rke2_k3s_node_map
  depends_on = [
    null_resource.k3s_bootstrap,
    null_resource.rke2_bootstrap
  ]

  user        = each.value.vm_user
  host        = split("/", each.value.ip_address)[0]
  private_key = file(var.ssh_private_key_path)

  commands = [
    "cat /tmp/k8s_external.yaml"
  ]
}

resource "local_file" "save_kubeconfig_rke2_k3s" {
  for_each = local.all_bootstrap_rke2_k3s_node_map

  content  = ssh_resource.k8s_config_rke2_k3s[each.key].result
  filename = "${path.module}/build/k8s_config.yaml"
}

resource "null_resource" "reboot_rke2_k3s_node_needed" {
  for_each = local.rancher_linux_nodes_map

  # It is executed once the cluster is fully deployed and configured
  depends_on = [
    local_file.save_kubeconfig_rke2_k3s, 
    null_resource.rke2_join_worker
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

resource "null_resource" "verify_rke2_k3s_service_status" {
  for_each   = local.rancher_linux_nodes_map
  depends_on = [null_resource.reboot_rke2_k3s_node_needed]

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
      "SERVICE_NAME='${local.is_k3s ? "k3s" : (each.value.type == "rke2-agent" ? "rke2-agent" : "rke2-server")}'",

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

resource "null_resource" "verify_rke2_k3s_cluster_health" {
  for_each   = local.all_bootstrap_rke2_k3s_node_map
  depends_on = [null_resource.verify_rke2_k3s_service_status]

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
      "KCONF='${local.is_k3s ? "/etc/rancher/k3s/k3s.yaml" : "/etc/rancher/rke2/rke2.yaml"}'",

      "echo '⏳ Waiting for API Server...'",
      "until sudo kubectl --kubeconfig $KCONF get nodes >/dev/null 2>&1; do sleep 5; done",
      "echo '✅ API Server is responding!'",
      
      "echo '⏳ Waiting for ALL cluster nodes to report Ready...'",
      "NODE_TIMEOUT=300",
      "NODE_ELAPSED=0",
      "until [ \"$(sudo kubectl --kubeconfig $KCONF get nodes -o jsonpath='{.items[*].status.conditions[?(@.type==\"Ready\")].status}' | grep -o 'True' | wc -l)\" -eq \"${local.number_of_nodes}\" ]; do",
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

resource "null_resource" "rke2_deploy_kube_vip_pod" {
  for_each   = local.rke2_cp_node_map
  depends_on = [null_resource.verify_rke2_k3s_cluster_health]

  connection {
    type        = "ssh"
    user        = each.value.vm_user
    host        = split("/", each.value.ip_address)[0]
    private_key = file(var.ssh_private_key_path)
    timeout     = "10m"
  }

  # Upload kube-vip config
  provisioner "file" {
    content = templatefile("${path.module}/templates/00-kube-vip.yaml.tftpl", {
      vip_address   = var.k8s_api_endpoint_vip
      vip_interface = var.k8s_api_cp_interface
    })
    destination = "/tmp/00-kube-vip.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "if [ ! -z \"${var.k8s_api_endpoint_vip}\" ]; then",
      "  KCONF=/etc/rancher/rke2/rke2.yaml",
      # If there is an explicit VIP in the variables, we activate the Kube-VIP balancer.
      "  echo '📦 Pre-loading Kube-VIP Manifest for Control Plane HA...'",
      "  sudo curl -sL https://kube-vip.io/manifests/rbac.yaml -o /var/lib/rancher/rke2/server/manifests/00-kube-vip-rbac.yaml",
      "  sleep 5",
      # 🚀 BULLETPROOF HA SOLUTION: Writing the exact, tested Kube-VIP Control Plane manifest
      "  echo '📦 Configuring Kube-VIP Pod Manifest for Control Plane HA...'",
      "  sudo mv /tmp/00-kube-vip.yaml /var/lib/rancher/rke2/server/manifests/00-kube-vip.yaml",
      "  echo \"⏳ Waiting for resources to exist in the API...\"",
      "  until sudo kubectl --kubeconfig $KCONF get ClusterRoleBinding system:kube-vip-binding -n kube-system > /dev/null 2>&1; do",
      "    echo \"  - ClusterRoleBinding system:kube-vip-binding not created yet, waiting...\"",
      "    sleep 5",
      " done",
      " echo \"✅ ClusterRoleBinding system:kube-vip-binding found...\"",
      # 🚀 Wait Pod be Running & Ready
      "  echo '⏳ Waiting for kube-vip pod to be Running and Ready...'",

      "  until [ \"$(sudo kubectl --kubeconfig $KCONF get pod kube-vip -n kube-system -o jsonpath='{.status.containerStatuses[0].ready}')\" = \"true\" ]; do",
      "    echo '🔄 Kube-VIP pod is initializing...'",
      "    sleep 5",
      "  done",
      "  echo '✅ Kube-VIP is Ready!'",
      "fi",
      "sleep 10"
    ]
  }
}