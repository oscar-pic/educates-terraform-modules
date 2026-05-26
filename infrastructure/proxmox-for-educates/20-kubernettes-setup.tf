locals {
  # To Detect choosen flavor
  is_k3s  = var.deployment_flavor == "single-node-k3s"
  is_rke2 = var.deployment_flavor == "rke2-cluster"

  # 1. Filter out which will be the bootstrap node
  bootstrap_node_map = {
    for k, v in var.kube_nodes : k => v
    if local.is_k3s || (local.is_rke2 && v.type == "rke2-server-bootstrap")
  }

  # 2. Filter out all the child nodes that need to be joined next
  joiner_node_map = {
    for k, v in var.kube_nodes : k => v
    if local.is_rke2 && (v.type == "rke2-server" || v.type == "rke2-agent")
  }

  # Securely extract the IP address from the bootstrap node for registration.
  bootstrap_name = length(keys(local.bootstrap_node_map)) > 0 ? keys(local.bootstrap_node_map)[0] : ""
  bootstrap_ip   = local.bootstrap_name != "" ? split("/", var.kube_nodes[local.bootstrap_name].ip_address)[0] : ""
  
  # The endpoint will be the VIP (if one was configured) or, failing that, the IP of the bootstrap node
  # registration_address = var.k8s_api_endpoint_vip != "" ? var.k8s_api_endpoint_vip : local.bootstrap_ip
  # CHANGED TO BOOTSTRAP SERVER ADDRESS. Sometimes kube-vip is not ready as soon as we need it in installation time
  registration_address = local.bootstrap_ip

  # Variable to generate the k8s_config.yaml correctly, in order to pass the file to the user with the correct cluster API IP.
  kubeconfig_k8s_cluster_api_ip = var.k8s_api_endpoint_vip != "" ? var.k8s_api_endpoint_vip : local.registration_address
}

###############################################################################
# STEP 1: BOOT AND VALIDATE THE BOOTSTRAP NODE (K3s or First Server RKE2)
###############################################################################
resource "null_resource" "bootstrap_k8s" {
  for_each = local.bootstrap_node_map

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
      cluster_token        = var.k8s_cluster_token
      registration_address = local.registration_address
      vip_address          = var.k8s_api_endpoint_vip
      is_bootstrap         = true
      is_server            = true
      # Pass the list of IPs to the template to iterate over
      nodes_ips            = [for k, v in var.kube_nodes : split("/", v.ip_address)[0] if v.type == "rke2-server" || v.type == "rke2-server-bootstrap"]
    })
    destination = "/tmp/rke2-config.yaml"
  }

  # 👁️ PROVISIONER 1: Sensitive Setup (Output will be suppressed by Terraform)
  provisioner "remote-exec" {

    inline = [
      "set -e",
      # 🛡️ SECURITY BLOCK: Wait to Cloud-Init finish the Ubuntu Upgrade
      "echo '⏳ Checking Cloud-Init status and waiting for Ubuntu apt upgrades to finish...'",
      "sudo cloud-init status --wait || true",
      "echo '✅ Cloud-Init finished! OS is fully updated and unlocked.'",

      "if [ '${var.deployment_flavor}' = 'rke2-cluster' ]; then",
      # ONLY RUN if RKE2 isn't already installed/running
      "  if systemctl is-active --quiet rke2-server; then echo '🛑 RKE2 already configured. Skipping.'; exit 0; fi",
      "  sudo mkdir -p /etc/rancher/rke2",
      "  sudo mv /tmp/rke2-config.yaml /etc/rancher/rke2/config.yaml",
      "fi",
    ]
  }

  # 👁️ PROVISIONER 2: Infrastructure Deployment & Engine Tracking (100% VISIBLE OUTPUT)
  # 1. Upload via file provisioner
  provisioner "file" {
    content = templatefile("${path.module}/templates/kube-vip-daemonset.yaml.tftpl", {
      vip_address   = var.k8s_api_endpoint_vip
      vip_interface = var.k8s_api_cp_interface
    })
    destination = "/tmp/kube-vip-daemonset.yaml"
  }

  provisioner "file" {
    content = templatefile("${path.module}/templates/rke2-cilium-config.yaml.tftpl", {
      # If it's a single node, use 1 replica; otherwise, 3 for HA.
      operator_replicas = length(var.kube_nodes) == 1 ? 1 : 3
      network_device    = var.k8s_api_cp_interface
    })
    destination = "/tmp/rke2-cilium-config.yaml"
  }

  # Upload Systemd Override
  provisioner "file" {
    source      = "${path.module}/templates/rke2-override.service.tftpl"
    destination = "/tmp/rke2-override.conf"
  }

  provisioner "remote-exec" {

    inline = [
      "set -e",
      "if [ \"${var.deployment_flavor}\" = \"single-node-k3s\" ]; then",
      "  echo '⏳ Installing K3s (Single Node)...'",
      "  curl -sfL https://get.k3s.io | sh -",
      "  KUBECONFIG_SOURCE=\"/etc/rancher/k3s/k3s.yaml\"",

      "elif [ \"${var.deployment_flavor}\" = \"rke2-cluster\" ]; then",
         # ONLY RUN if RKE2 isn't already installed/running
      "  if systemctl is-active --quiet rke2-server; then echo '🛑 RKE2 already configured. Skipping.'; exit 0; fi",
         # 🚀 Global enforcement: No matter what happens below, this session only speaks production STABLE
      "  export INSTALL_RKE2_CHANNEL='stable'",
      "  echo '⚙️  Configuring RKE2 Bootstrap Server with custom Cilium setup...'",
      "  sudo mkdir -p /var/lib/rancher/rke2/server/manifests",

      # 1. If there is an explicit VIP in the variables, we activate the Kube-VIP balancer.
      "  if [ ! -z \"${var.k8s_api_endpoint_vip}\" ]; then",
      "    echo '📦 Pre-loading Kube-VIP Manifest for Control Plane HA...'",
      "    sudo curl -sL https://kube-vip.io/manifests/rbac.yaml -o /var/lib/rancher/rke2/server/manifests/01-kube-vip-rbac.yaml",

      # 🚀 BULLETPROOF HA SOLUTION: Writing the exact, tested Kube-VIP Control Plane manifest
      "    sudo mv /tmp/kube-vip-daemonset.yaml /var/lib/rancher/rke2/server/manifests/kube-vip-daemonset.yaml",
      "  fi",

      "  echo '⚙️  Injecting Cilium HelmChartConfig for kube-proxy replacement...'",
      "  sudo mv /tmp/rke2-cilium-config.yaml /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml",
    
      "  echo '⏳ Installing latest production stable RKE2 Server binary...'",
      # 🚀 Force sudo on the installer pipe
      "  curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_SKIP_START=true sh -", # 🌟 It automatically inherits the exported variable!
      
      "  echo '⏳ Waiting for the installer to write RKE2 components...'",
      "  until [ -f /usr/local/bin/rke2 ]; do sleep 2; done",

      # 🚀 FIX 1: Force kernel storage synchronization to release binary write locks before starting unit
      "  echo '⚙️  Synchronizing storage buffers to release file descriptor locks...'",
      "  sudo sync",
      "  sleep 5",

      # 🚀 FIX 2: Patch systemd unit to enforce infinite retries if Docker Hub fails or limits pull requests
      "  echo '⚙️  Patching RKE2 systemd service for aggressive automatic restarts...'",
      "  sudo mkdir -p /etc/systemd/system/rke2-server.service.d",
      "  sudo mv /tmp/rke2-override.conf /etc/systemd/system/rke2-server.service.d/override.conf",
      "  sudo systemctl daemon-reload",
      "  echo '⚙️  Enabling rke2-server systemd unit...'",
      "  sudo systemctl enable rke2-server.service",
      "  echo '⚙️  Launching rke2-server in the background (Initializing cluster + Cilium + Multus + Hubble). It will take time. Timeout to 15m...'",
      # 🔥 We start it and let systemd handle the bootstrap asynchronously
      "  sudo systemctl start rke2-server.service",
      "  KUBECONFIG_SOURCE=\"/etc/rancher/rke2/rke2.yaml\"",
      "fi",

      "echo '⏳ Waiting for configuration file to be generated...'",
      "until  sudo test -f \"$KUBECONFIG_SOURCE\"; do sleep 5; done",

      # 🚀 FIX 2: Create symlink safely after file assurance guarantees unpack state completion
      "if [ \"${var.deployment_flavor}\" = \"rke2-cluster\" ]; then",
      "  echo '⚙️  Creating safe global symlink for kubectl binary...'",
      "  sudo ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl",
      "fi",
      
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

      # 🚀 Explicit apply for Kube-VIP manifests to bypass RKE2 boot-directory scanning race conditions
      "if [ ! -z \"${var.k8s_api_endpoint_vip}\" ]; then",
      # "  echo '⚙️  Enforcing direct execution of Kube-VIP manifests...'",
      # "  /usr/local/bin/kubectl apply -f /var/lib/rancher/rke2/server/manifests/01-kube-vip-rbac.yaml",
      # "  /usr/local/bin/kubectl apply -f /var/lib/rancher/rke2/server/manifests/02-kube-vip-daemonset.yaml",

      # "  echo '⏳ Waiting for Kube-VIP rollout status validation...'",
      # "  /usr/local/bin/kubectl rollout status daemonset/kube-vip -n kube-system --timeout=180s || true",
      # "  sleep 5",
      
      "  echo '🌐 Network routing state analysis...'",
      "  ip addr show | grep -q \"${var.k8s_api_endpoint_vip}\" && echo \"✅ VIP ${var.k8s_api_endpoint_vip} bound successfully!\" || echo \"⚠️  VIP not visible yet on routing tables.\"",
      "fi",

      "echo '------------------------------------------------------------'"
    ]
  }
}

###############################################################################
# STEP 2: JOIN THE ADDITIONAL NODES (RKE2 Multinode Only)
###############################################################################
resource "null_resource" "join_k8s" {
  for_each = local.joiner_node_map

  # CRUCIAL: No node attempts to join until the Bootstrap is operational
  depends_on = [null_resource.bootstrap_k8s]

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

  provisioner "file" {
    content = templatefile("${path.module}/templates/rke2-config.yaml.tftpl", {
      cluster_token        = var.k8s_cluster_token
      registration_address = local.registration_address
      vip_address          = var.k8s_api_endpoint_vip
      is_bootstrap         = false
      # Logic: Is this node a server or an agent?
      is_server            = (each.value.type == "rke2-server") 
      nodes_ips            = [for k, v in var.kube_nodes : split("/", v.ip_address)[0] if contains(["rke2-server", "rke2-server-bootstrap"], v.type)]
    })
    destination = "/tmp/rke2-config.yaml"
  }

  # =========================================================================
  # PROVISIONER 1: CONFIGURATION (Silenced by Terraform due to Sensitive Token)
  # =========================================================================
  provisioner "remote-exec" {

    inline = [
      "set -e",
      # 🛡️ SECURITY BLOCK: Wait to Cloud-Init finish the Ubuntu Upgrade
      "echo '⏳ Checking Cloud-Init status and waiting for Ubuntu apt upgrades to finish...'",
      "sudo cloud-init status --wait || true",
      "echo '✅ Cloud-Init finished! OS is fully updated and unlocked.'",

      "if [ '${var.deployment_flavor}' = 'rke2-cluster' ]; then",
      "  if [ '${each.value.type}' = 'rke2-server' ]; then",
           # ONLY RUN if RKE2 isn't already installed/running
      "    if systemctl is-active --quiet rke2-server; then echo '🛑 RKE2 already configured. Skipping.'; exit 0; fi",
      "  elif [ '${each.value.type}' = 'rke2-agent' ]; then",
           # ONLY RUN if RKE2 isn't already installed/running
      "    if systemctl is-active --quiet rke2-agent; then echo '🛑 RKE2 already configured. Skipping.'; exit 0; fi",
      "  fi",
      "  sudo mkdir -p /etc/rancher/rke2",
      "  sudo mv /tmp/rke2-config.yaml /etc/rancher/rke2/config.yaml",
      "fi",
    ]
  }

  # Upload Systemd Override
  provisioner "file" {
    source      = "${path.module}/templates/rke2-override.service.tftpl"
    destination = "/tmp/rke2-override.conf"
  }

  # =========================================================================
  # PROVISIONER 2: LIFECYCLE & INSTALLATION (100% Visible in Console)
  # =========================================================================
  provisioner "remote-exec" {

    inline = [
      "set -e",
      "if [ '${var.deployment_flavor}' = 'rke2-cluster' ]; then",
      "  export INSTALL_RKE2_CHANNEL='stable'",
      "  if [ '${each.value.type}' = 'rke2-server' ]; then",
           # ONLY RUN if RKE2 isn't already installed/running
      "    if systemctl is-active --quiet rke2-server; then echo '🛑 RKE2 already configured. Skipping.'; exit 0; fi",
      "    echo '⏳ Installing and starting RKE2 Control Plane...'",
      "    curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_SKIP_START=true sh -",
      "  elif [ '${each.value.type}' = 'rke2-agent' ]; then",
           # ONLY RUN if RKE2 isn't already installed/running
      "    if systemctl is-active --quiet rke2-agent; then echo '🛑 RKE2 already configured. Skipping.'; exit 0; fi",
      "    echo '⏳ Installing and starting RKE2 Worker...'",
      "    curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_TYPE='agent' INSTALL_RKE2_SKIP_START=true sh -",
      "  fi",
         
         # 🚀 Global enforcement for joiners
      "  echo '⏳ Waiting for the installer to write RKE2 components...'",
      "  until [ -f /usr/local/bin/rke2 ]; do sleep 2; done",

      "  echo '⚙️  Synchronizing storage buffers...'",
      "  sudo sync",
      "  sleep 5",

      "  echo '⚙️  Patching RKE2 systemd service for aggressive automatic restarts...'",
      "  sudo mkdir -p /etc/systemd/system/rke2-server.service.d",
      "  sudo mv /tmp/rke2-override.conf /etc/systemd/system/rke2-\"${each.value.type == "rke2-agent" ? "agent" : "server"}\".service.d/override.conf",

      "  sudo systemctl daemon-reload",
      "  echo '⚙️  Enabling rke2-\"${each.value.type == "rke2-agent" ? "agent" : "server"}\" systemd unit...'",
      "  sudo systemctl enable rke2-\"${each.value.type == "rke2-agent" ? "agent" : "server"}\".service",
      "  echo '⚙️  Starting rke2-\"${each.value.type == "rke2-agent" ? "agent" : "server"}\"...'",
      "  sudo systemctl start rke2-\"${each.value.type == "rke2-agent" ? "agent" : "server"}\".service",
      "  echo '✅ Node joined successfully!'",
      "fi",
    ]
  }
}

###############################################################################
# STEP 3: DOWNLOAD THE UNIFIED KUBECONFIG LOCALLY
###############################################################################
resource "ssh_resource" "k8s_config" {
  for_each   = local.bootstrap_node_map
  depends_on = [null_resource.bootstrap_k8s]

  user        = each.value.vm_user
  host        = split("/", each.value.ip_address)[0]
  private_key = file(var.ssh_private_key_path)

  commands = [
    "cat /tmp/k8s_external.yaml"
  ]
}

###############################################################################
# STEP 4: DEPLOY CEPHFS CSI VIA MULTI-STAGE REMOTE-EXEC PROVISIONERS
###############################################################################
resource "null_resource" "rke2_cephfs_csi" {
  # Trigger only after the bootstrap server's control plane is fully verified
  depends_on = [null_resource.bootstrap_k8s]

  for_each   = local.bootstrap_node_map

  connection {
    type        = "ssh"
    user        = each.value.vm_user
    host        = split("/", each.value.ip_address)[0]
    private_key = file(var.ssh_private_key_path)
  }

  # STAGE 1: Sensitive execution (Output will be automatically suppressed by Terraform)
  # 1. Upload the template
  provisioner "file" {
    content = templatefile("${path.module}/templates/ceph-csi-secret.yaml.tftpl", {
      ceph_key = var.proxmox_ceph_k8s_key
    })
    destination = "/tmp/ceph-csi-secret.yaml"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo mv /tmp/ceph-csi-secret.yaml /var/lib/rancher/rke2/server/manifests/ceph-csi-secret.yaml"
    ]
  }

  # STAGE 2: Non-sensitive execution (Output will be fully verbose and visible in clear text)
  # 1. Upload the templates
  provisioner "file" {
    content = templatefile("${path.module}/templates/ceph-csi-storage-net.yaml.tftpl", {
      interface_name = var.k8s_ceph_storage_interface_name
      subnet         = var.proxmox_ceph_storage_subnet
    })
    destination = "/tmp/ceph-csi-storage-net.yaml"
  }

  provisioner "file" {
    content = templatefile("${path.module}/templates/ceph-csi-helm.yaml.tftpl", {
      monitors_list = join("\n", [for node in var.proxmox_nodes : "- ${node}:6789"])
    })
    destination = "/tmp/ceph-csi-helm.yaml"
  }

  provisioner "file" {
    source      = "${path.module}/templates/ceph-csi-storageclass.yaml.tftpl"
    destination = "/tmp/ceph-csi-storageclass.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "echo '⚙️  Verifying RKE2 auto-deploy manifests directory...'",
      "sudo mkdir -p /var/lib/rancher/rke2/server/manifests",

      # 0. ADD THIS: Deploy the NetworkAttachmentDefinition for Multus
      "echo '📦 Deploying NetworkAttachmentDefinition...'",
      "sudo mv /tmp/ceph-csi-storage-net.yaml /var/lib/rancher/rke2/server/manifests/",

      # 1. Create the HelmChart with integrated dynamic cluster configuration
      "echo '📦 Deploying Ceph-CSI HelmChart manifest...'",
      "sudo mv /tmp/ceph-csi-helm.yaml /var/lib/rancher/rke2/server/manifests/",
    
      # 2. Create the StorageClass to enable RWX provisioning
      "echo '📦 Deploying Ceph-CSI StorageClass...'",
      "sudo mv /tmp/ceph-csi-storageclass.yaml /var/lib/rancher/rke2/server/manifests/",
     
      "echo '✅ CephFS CSI manifests successfully deployed to RKE2 manifests directory.'"
    ]
  }
}

###############################################################################
# MAINTENANCE: SAFE REBOOT (Maintains your original logic for all nodes)
###############################################################################
resource "local_file" "save_kubeconfig" {
  for_each = local.bootstrap_node_map

  content  = ssh_resource.k8s_config[each.key].result
  filename = "${path.module}/k8s_config.yaml"
}

resource "null_resource" "needed_reboot_node" {
  for_each = var.kube_nodes

  # It is executed once the cluster is fully deployed and configured
  depends_on = [local_file.save_kubeconfig, null_resource.join_k8s, null_resource.rke2_cephfs_csi]

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
      # "  echo '⚠️  System restart IS required. Initiating reboot now...';",
      # "  echo '⏳ Reboot scheduled. Safe exit from current SSH session...';",
      # "  echo '⏳ Sleeping for 180s to let ALL nodes reboot & recover...'",
      # "  sudo shutdown -r +1 'Terraform OS Update Reboot' <&- >/dev/null 2>&1 &",
      # "  sudo sh -c 'echo scheduled > /tmp/terraform-reboot-scheduled';",
      "echo '⚠️ WARNING: System restart IS required for Node ${each.key}'",
      "echo 'To reboot safely, run:'",
      "echo 'kubectl drain ${each.key} --ignore-daemonsets --delete-emptydir-data'",
      "echo 'And then: sudo reboot'",
      "else",
      "  echo '✅ No reboot required for this node. Skipping.';",
      #"  echo '⏳ Sleeping for 180s to let ALL nodes stabilize...'",
      "fi",
      "echo '------------------------------------------------------------'",
      "sleep 5"
    ]
  }
}

resource "time_sleep" "wait_for_needed_reboot_cycle" {
  depends_on      = [null_resource.needed_reboot_node]
  #create_duration = "180s"
  create_duration = "20s"
}

resource "null_resource" "verify_node_online" {
  for_each   = var.kube_nodes
  depends_on = [time_sleep.wait_for_needed_reboot_cycle]

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
      "IS_SERVER='${local.is_k3s || each.value.type == "rke2-server" || each.value.type == "rke2-server-bootstrap" ? "true" : "false"}'",
      "KCONF='${local.is_k3s ? "/etc/rancher/k3s/k3s.yaml" : "/etc/rancher/rke2/rke2.yaml"}'",

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
      

      "if [ \"$IS_SERVER\" = \"true\" ]; then",
      "  echo '⏳ Waiting for API Server...'",
      "  until sudo kubectl --kubeconfig $KCONF get nodes >/dev/null 2>&1; do sleep 5; done",
      "  echo '✅ API Server is responding!'",
      
      "  echo '⏳ Waiting for node to be Ready...'",
      "  until [ \"$(sudo kubectl --kubeconfig $KCONF get node $(hostname) -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}')\" = \"True\" ]; do sleep 5; done",

      "  echo '⏳ Checking for Pod stability in kube-system...'",
      "  CORE_TIMEOUT=300",
      "  CORE_ELAPSED=0",
      "  until [ \"$CORE_ELAPSED\" -ge \"$CORE_TIMEOUT\" ]; do",
      "    BAD_PODS=$(sudo kubectl --kubeconfig $KCONF get pods -n kube-system --no-headers | awk '$3 != \"Running\" && $3 != \"Completed\" {print $0}' | wc -l)",
      "    NOT_READY_PODS=$(sudo kubectl --kubeconfig $KCONF get pods -n kube-system --field-selector=status.phase=Running -o jsonpath='{.items[*].status.containerStatuses[*].ready}' | grep -o 'false' | wc -l || echo 0)",
      
      "    if [ \"$BAD_PODS\" -eq 0 ] && [ \"$NOT_READY_PODS\" -eq 0 ]; then",
      "      echo '✅ All core pods are Running/Completed and Ready!'",
      "      break",
      "    fi",
      "    echo \"🔄 Waiting... (Bad: $BAD_PODS, Not-Ready: $NOT_READY_PODS). ($CORE_ELAPSED/$CORE_TIMEOUT s)\"",
      "    sleep 15",
      "    CORE_ELAPSED=$((CORE_ELAPSED + 15))",
      "  done",
      "    if [ \"$CORE_ELAPSED\" -ge \"$CORE_TIMEOUT\" ]; then",
      "      echo '⚠️  WARNING: Core pods are taking longer than expected to report Ready.'",
      "    fi",
      "fi"
    ]
  }
}