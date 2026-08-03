locals {
  is_talos_deployment = var.deployment_flavor == "talos-cluster"

  talos_bootstrap_node = local.is_talos_deployment ? {
    for k, v in var.kube_nodes : k => v if strcontains(v.type, "talos-controlplane-bootstrap")
  } : {}

  talos_bootstrap_node_name = try(keys(local.talos_bootstrap_node)[0], "none")
  talos_bootstrap_node_ip   = try(split("/", values(local.talos_bootstrap_node)[0].ip_address)[0], "0.0.0.0")

  # Filter controlplane nodes (bootstrap and standard ones)
  talos_cp_nodes = local.is_talos_deployment ? {
    for k, v in var.kube_nodes : k => v if strcontains(v.type, "controlplane")
  } : {}

  # Filter worker nodes
  talos_worker_nodes = local.is_talos_deployment ? {
    for k, v in var.kube_nodes : k => v if strcontains(v.type, "worker")
  } : {}

  talos_cp_ips = [
    for v in local.talos_cp_nodes : split("/", v.ip_address)[0]
  ]

  talos_worker_ips = [
    for v in local.talos_worker_nodes : split("/", v.ip_address)[0]
  ]

  talos_workers_nodes_ips = join(",", local.talos_worker_ips)

  # Detect if the OS is Windows (contains 'windows' in the system architecture)
  is_windows = can(regex("(?i)windows", replace(lower(abspath(path.root)), "\\", "/")))
  
  # Define the interpreter based on the OS
  interpreter = local.is_windows ? ["PowerShell", "-Command"] : ["/bin/bash", "-c"]

  # Trigger only when certs strategy is provided
  is_talos_certs_provided = var.k8s_cert_strategy == "provided"

  # Because of the variable validation, we know for a fact these files exist 
  # if is_talos_certs_provided is true. No extra checks needed.
  provided_cert_rendered_yaml = local.is_talos_certs_provided ? templatefile("${path.module}/templates/common/04-cert-tls-secret.yaml.tftpl", {
    secret_name = "gateway-api-default-cert"
    tls_crt_b64 = filebase64("${path.module}/${var.k8s_certs_path}/wildcard.crt")
    tls_key_b64 = filebase64("${path.module}/${var.k8s_certs_path}/wildcard.key")
  }) : ""

  self_signed_cert_rendered_yaml  = templatefile("${path.module}/templates/talos/self-signed-cert.yaml.tftpl", {
      secret_name = "gateway-api-default-cert"
      dns_names   = var.k8s_apps_cert_domains
  })

  letsencrypt_cert_rendered_yaml = templatefile("${path.module}/templates/common/06-cert-letsencrypt-setup.yaml.tftpl", {
    cert_object_name = "gateway-cert"
    secret_name      = "gateway-api-default-cert"
    email            = var.k8s_letsencrypt_email
    dns_api_token    = var.k8s_letsencrypt_dns_provider_api_token
    dns_names        = var.k8s_apps_cert_domains
  })

  gateway_rendered_yaml = templatefile("${path.module}/templates/common/03-cilium-gateway-setup.yaml.tftpl", {
    lb_ip_range    = var.k8s_gateway_api_lb_ip_range
    network_device = var.k8s_api_cp_interface
    secret_name    = "gateway-api-default-cert"
  })

  ceph_csi_requisites_redered_yaml = templatefile("${path.module}/templates/common/07-ceph-csi-requisites.yaml.tftpl", {
    clusterID = var.proxmox_ceph_clusterID
    ceph_key  = var.proxmox_ceph_k8s_key
  })

  # Common configuration for Ceph CSI
  talos_ceph_csi_values = {
    clusterID          = var.proxmox_ceph_clusterID
    ceph_monitors_list = var.proxmox_nodes_ceph_IPs
    replica_count      = length(var.kube_nodes) == 1 ? 1 : 3
  }
}

provider "helm" {
  kubernetes = {
    config_path = "${path.root}/build/talos/k8s_config.yaml"
    host        = "https://${local.talos_bootstrap_node_ip}:6443"
    insecure    = true
  }
}

resource "talos_image_factory_schematic" "cluster_schematic" {
  count = local.is_talos_deployment ? 1 : 0
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = var.talos_compiled_extensions
      }
    }
  })
}

data "talos_image_factory_urls" "talos_iso_schematic" {
  count = local.is_talos_deployment ? 1 : 0

  talos_version = var.talos_compiled_version
  architecture  = "amd64"
  platform      = "nocloud"
  schematic_id  = talos_image_factory_schematic.cluster_schematic[count.index].id
}

resource "talos_machine_secrets" "talos_cluster_secrets" {
  count = local.is_talos_deployment ? 1 : 0
}

data "talos_machine_configuration" "talos_config" {
  for_each         = local.is_talos_deployment ? var.kube_nodes : {}
  cluster_name     = var.k8s_cluster_name
  cluster_endpoint = "https://${var.k8s_api_endpoint_vip}:6443"
  machine_type     = strcontains(each.value.type, "controlplane") ? "controlplane" : "worker"
  machine_secrets  = talos_machine_secrets.talos_cluster_secrets[0].machine_secrets

  config_patches = [
    yamlencode({
      machine = {
        nodeLabels = {
          for label in each.value.node_labels : 
          split("=", label)[0] => split("=", label)[1]
        }
        install = {
          disk = "/dev/sda" # Asegura que Talos instale el OS en el disco
          wipe = true
        }
        kernel = {
          modules = [
            { name = "rbd" },
            { name = "libceph" }
          ]
        }
        # NTP Configuration
        time = {
          disabled = false
          servers = ["time.cloudflare.com", "pool.ntp.org"]
        }
        network = {
          #hostname = each.key
          hostname = "${split("-", var.deployment_flavor)[0]}-${each.key}"
          interfaces = [
            {
              interface = var.k8s_api_cp_interface
              addresses = [each.value.ip_address]
              routes    = [{ network = "0.0.0.0/0", gateway = each.value.gateway }]
              vip       = (strcontains(each.value.type, "controlplane") ? { ip = var.k8s_api_endpoint_vip } : null)
              dhcp      = false
            },
            {
              interface = var.k8s_ceph_node_interface
              dhcp      = false
              addresses = [each.value.ceph_ip_address]
              mtu       = 9000
            }
          ]
          nameservers = each.value.dns_servers
        }
      }
      cluster = {
        network = {
          cni = {
            name = "none" # This disables the default CNI (Flannel) and allows you to use your own CNI plugin
          }
        }
        proxy = {
          disabled = true # This disables kube-proxy
        }
      }
    })
  ]
}

data "talos_client_configuration" "talos_config_data" {
  count = local.is_talos_deployment ? 1 : 0

  cluster_name         = var.k8s_cluster_name
  client_configuration = talos_machine_secrets.talos_cluster_secrets[0].client_configuration
  endpoints            = [for k, v in local.talos_cp_nodes : split("/", v.ip_address)[0]]
}

resource "null_resource" "wait_for_talos" {
  count      = length(local.talos_bootstrap_node) > 0 ? 1 : 0
  depends_on = [
    proxmox_virtual_environment_vm.kube_node,
    local_file.talosconfig
  ]

  provisioner "local-exec" {
    interpreter = local.interpreter
    command     = <<EOT
      %{if local.is_windows}
      Write-Host "Waiting for Talos API on ${local.talos_bootstrap_node_ip}..." -ForegroundColor Cyan
      do {
        $status = talosctl --talosconfig ./build/talos/talosconfig -n ${local.talos_bootstrap_node_ip} get members 2>&1
        Start-Sleep -Seconds 5
      } until ($LASTEXITCODE -eq 0)
      Write-Host "Talos API is up and running!" -ForegroundColor Green
      %{else}
      echo "Waiting for Talos API on ${local.talos_bootstrap_node_ip}..."
      until talosctl --talosconfig ./build/talos/talosconfig -n ${local.talos_bootstrap_node_ip} get members >/dev/null 2>&1; do
        sleep 5
      done
      echo "Talos API is up and running!"
      %{endif}
    EOT
    quiet = true
  }
}

resource "talos_machine_bootstrap" "cluster_bootstrap" {
  count                = length(local.talos_bootstrap_node) > 0 ? 1 : 0
  depends_on           = [null_resource.wait_for_talos]
  
  node                 = local.talos_bootstrap_node_ip
  client_configuration = talos_machine_secrets.talos_cluster_secrets[0].client_configuration
}

resource "talos_cluster_kubeconfig" "kubeconfig_auth" {
  count                = length(local.talos_bootstrap_node) > 0 ? 1 : 0
  depends_on           = [talos_machine_bootstrap.cluster_bootstrap]
  
  node                 = local.talos_bootstrap_node_ip
  client_configuration = talos_machine_secrets.talos_cluster_secrets[0].client_configuration
}

resource "local_file" "talosconfig" {
  count = local.is_talos_deployment ? 1 : 0

  content  = data.talos_client_configuration.talos_config_data[0].talos_config
  filename = "${path.root}/build/talos/talosconfig"
}

resource "local_file" "kubeconfig" {
  count    = local.is_talos_deployment ? 1 : 0
  content  = talos_cluster_kubeconfig.kubeconfig_auth[0].kubeconfig_raw
  filename = "${path.root}/build/talos/k8s_config.yaml"
}

resource "null_resource" "talos_wait_for_cluster_readiness" {
  count      = local.is_talos_deployment ? 1 : 0
  depends_on = [local_file.kubeconfig]

  provisioner "local-exec" {
    interpreter = local.interpreter
    command = <<EOT
      %{if local.is_windows}
      $nodes = @{ ${join("; ", [for k, v in var.kube_nodes : "'$k'='${split("/", v.ip_address)[0]}'"])} };
      foreach ($name in $nodes.Keys) {
        $ip = $nodes[$name];
        Write-Host "Checking services on node $name ($ip)..." -ForegroundColor Cyan;
        do {
          $services = talosctl --talosconfig ./build/talos/talosconfig -n $ip get services;
          $ready = ($services | Select-String "kubelet|containerd" | Where-Object { $_ -match "true\s+true" } | Measure-Object).Count;
          Start-Sleep -Seconds 10;
        } until ($ready -ge 2);
      }
      Write-Host "Waiting for node ${local.talos_bootstrap_node_ip} to join K8s API..." -ForegroundColor Cyan
      do {
        # IMPORTANT: Use the bootstrap node IP directly, bypass the VIP
        $nodesCount = (kubectl --kubeconfig ./build/talos/k8s_config.yaml -s https://${local.talos_bootstrap_node_ip}:6443 get nodes --insecure-skip-tls-verify | Select-String "Ready|NotReady" | Measure-Object).Count
        Start-Sleep -Seconds 10
      } until ($nodesCount -ge ${length(var.kube_nodes)})
      %{else}
      %{for k, v in var.kube_nodes}
      echo "Checking services on node ${k} (${split("/", v.ip_address)[0]})..."
      until talosctl --talosconfig ./build/talos/talosconfig -n ${split("/", v.ip_address)[0]} get services | grep -E "kubelet|containerd" | awk '{if($6=="true" && $7=="true") print "OK"}' | wc -l | grep -q "2"; do
        sleep 10
      done
      %{endfor}
      echo "Waiting for nodes to join K8s API..."
      until kubectl --kubeconfig ./build/talos/k8s_config.yaml -s https://${local.talos_bootstrap_node_ip}:6443 get nodes --insecure-skip-tls-verify | grep -c "Ready\|NotReady" | grep -q "${length(var.kube_nodes)}"; do
        sleep 10
      done
      %{endif}
    EOT
    quiet = true
  }
}

resource "terraform_data" "cilium_namespace_setup" {
  count = local.is_talos_deployment ? 1 : 0

  provisioner "local-exec" {
    command = <<EOT
      kubectl --kubeconfig ./build/talos/k8s_config.yaml create namespace cilium-system --dry-run=client -o yaml | kubectl --kubeconfig ./build/talos/k8s_config.yaml apply -f -
      kubectl --kubeconfig ./build/talos/k8s_config.yaml label namespace cilium-system pod-security.kubernetes.io/enforce=privileged --overwrite
      kubectl --kubeconfig ./build/talos/k8s_config.yaml label namespace cilium-system pod-security.kubernetes.io/audit=privileged --overwrite
      kubectl --kubeconfig ./build/talos/k8s_config.yaml label namespace cilium-system pod-security.kubernetes.io/warn=privileged --overwrite
    EOT
    quiet = true
  }

  depends_on = [
    null_resource.talos_wait_for_cluster_readiness
  ]
}

resource "helm_release" "talos_cilium_setup" {
  count            = local.is_talos_deployment ? 1 : 0
  name             = "cilium"
  repository       = "https://helm.cilium.io/"
  chart            = "cilium"
  namespace        = "cilium-system"
  create_namespace = false
  version          = var.k8s_cilium_version

  values = [
    templatefile("${path.module}/templates/talos/cilium-helm-values.yaml.tftpl", {
      network_device    = var.k8s_api_cp_interface 
      operator_replicas = length(local.talos_cp_nodes) >= 3 ? 3 : 1
      k8s_api_cp_ip     = local.talos_bootstrap_node_ip
    })
  ]

depends_on = [
    terraform_data.cilium_namespace_setup
  ]
}

resource "null_resource" "talos_wait_for_cilium" {
  count      = local.is_talos_deployment ? 1 : 0
  depends_on = [helm_release.talos_cilium_setup]

  provisioner "local-exec" {
    interpreter = local.interpreter
    # We use the bootstrap node IP (-s) to ensure the connection before the VIP works
    command = <<-EOT
      echo "⏳ Waiting for Cilium operator to start..."
      until kubectl --kubeconfig ./build/talos/k8s_config.yaml \
            -s https://${local.talos_bootstrap_node_ip}:6443 \
            --insecure-skip-tls-verify \
            rollout status deployment/cilium-operator -n cilium-system --timeout=300s; do
        echo "  - The operator is not ready yet, retrying..."
        sleep 10
      done
      echo "✅ Cilium operational."
    EOT
    quiet = true
  }
}

resource "null_resource" "talos_create_gateway_namespace" {
  count      = local.is_talos_deployment ? 1 : 0
  depends_on = [null_resource.talos_wait_for_cilium]

  provisioner "local-exec" {
    command = <<-EOT
      echo '📦 Ensuring gateway-system namespace exists...'
      kubectl --kubeconfig ./build/talos/k8s_config.yaml create namespace gateway-system --dry-run=client -o yaml | kubectl --kubeconfig ./build/talos/k8s_config.yaml apply -f -
      
      until kubectl --kubeconfig ./build/talos/k8s_config.yaml get namespace gateway-system &>/dev/null; do
        echo "   -> Waiting for gateway-system to be ready..."
        sleep 3
      done
      echo '✅ Namespace gateway-system is ready.'
    EOT
    quiet = true
  }
}

resource "null_resource" "talos_provided_tls_secret_cert" {
  count = (local.is_talos_certs_provided && var.deployment_flavor == "talos-cluster") ? 1 : 0
  depends_on = [null_resource.talos_create_gateway_namespace]

  provisioner "local-exec" {
    command = <<EOT
      echo '⚙️  Generating Secret for Provided certs...'
      echo '${local.provided_cert_rendered_yaml}' | kubectl --kubeconfig ./build/talos/k8s_config.yaml apply -f -
      sleep 5
    EOT
    quiet = true
  }
}

resource "helm_release" "talos_cert_manager" {
  count = (var.k8s_cert_strategy != "provided" && var.deployment_flavor == "talos-cluster") ? 1 : 0
  
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  version          = var.k8s_cert_manager_version

  set = [{
    name  = "crds.enabled"
    value = "true"
  }]

  depends_on = [
    talos_cluster_kubeconfig.kubeconfig_auth,
    null_resource.talos_create_gateway_namespace
  ]
}

resource "null_resource" "talos_wait_for_cert_manager_ready" {
  count = (var.k8s_cert_strategy != "provided" && var.deployment_flavor == "talos-cluster") ? 1 : 0

  depends_on = [helm_release.talos_cert_manager]

  provisioner "local-exec" {
    command = <<EOT
      echo "⏳ Waiting for all cert-manager pods to be in Ready..."
      kubectl --kubeconfig ./build/talos/k8s_config.yaml wait --for=condition=Ready pod -n cert-manager --all --timeout=120s
      echo "✅ All cert-manager pods are ready."
    EOT
    quiet = true
  }
}

resource "null_resource" "talos_self_signed_issuer" {
  count = (var.k8s_cert_strategy == "self-signed" && var.deployment_flavor == "talos-cluster") ? 1 : 0
  depends_on = [null_resource.talos_wait_for_cert_manager_ready]

  provisioner "local-exec" {
    command = <<EOT
      echo "🚀 Applying ClusterIssuer 'self-signed-issuer'..."
      cat <<EOF | kubectl --kubeconfig ./build/talos/k8s_config.yaml apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: self-signed-issuer
spec:
  selfSigned: {}
EOF
      # Verify the Issuer is ready
      echo "⏳ Waiting for ClusterIssuer 'self-signed-issuer' to be ready..."
      until kubectl --kubeconfig ./build/talos/k8s_config.yaml get clusterissuer self-signed-issuer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"; do
        sleep 5
      done
      echo "✅ ClusterIssuer is ready."
    EOT
    quiet = true
  }

}

resource "null_resource" "talos_self_signed_cert" {
  count = (var.k8s_cert_strategy == "self-signed" && var.deployment_flavor == "talos-cluster") ? 1 : 0
  depends_on = [null_resource.talos_self_signed_issuer]

  provisioner "local-exec" {
    command = <<EOT
      echo '⚙️  Generating self-signed wildcard certs...'
      echo '${local.self_signed_cert_rendered_yaml}' | kubectl --kubeconfig ./build/talos/k8s_config.yaml apply -f -
      sleep 5
    EOT
    quiet = true
  }
}

resource "null_resource" "talos_letsencrypt_cert" {
  count      = var.k8s_cert_strategy == "letsencrypt" ? 1 : 0
  depends_on = [null_resource.talos_wait_for_cert_manager_ready]
  
  provisioner "local-exec" {
    command = <<EOT
      echo '⚙️  Generating Lets Encrypt wildcard certs...'
      echo '${local.letsencrypt_cert_rendered_yaml}' | kubectl --kubeconfig ./build/talos/k8s_config.yaml apply -f -
      sleep 5
    EOT
    quiet = true
  }
}

resource "null_resource" "talos_cilium_gateway_setup" {
  count      = local.is_talos_deployment ? 1 : 0
  
  depends_on = [
    helm_release.talos_cert_manager,
    null_resource.talos_letsencrypt_cert,
    null_resource.talos_self_signed_cert,
    null_resource.talos_provided_tls_secret_cert,
    null_resource.talos_create_gateway_namespace
  ]

  triggers = {
    template_hash = sha1(local.gateway_rendered_yaml)
  }

  provisioner "local-exec" {
    command = <<EOT
      echo '🌐 Deploying Gateway API CRDs...'
      # Download the standard install manifest for Gateway API
      #kubectl --kubeconfig ./build/talos/k8s_config.yaml apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml
      # Cilium needs from 1.19.5 the 1.6.0 experimental-install CRDS. If not, it doesn't start up
      kubectl --kubeconfig ./build/talos/k8s_config.yaml apply --server-side=true --force-conflicts -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/experimental-install.yaml

      # We wait for those CRDs, that are critical to Gateway API before continue
      echo '⏳ Waiting for Gateway API CRDs to be registered by Talos...'
      until kubectl --kubeconfig ./build/talos/k8s_config.yaml get gatewayclasses.gateway.networking.k8s.io &>/dev/null && \
            kubectl --kubeconfig ./build/talos/k8s_config.yaml get gateways.gateway.networking.k8s.io &>/dev/null && \
            kubectl --kubeconfig ./build/talos/k8s_config.yaml get httproutes.gateway.networking.k8s.io &>/dev/null && \
            kubectl --kubeconfig ./build/talos/k8s_config.yaml get tlsroutes.gateway.networking.k8s.io &>/dev/null; do
        sleep 5
      done
      echo '✅ Gateway API CRDs successfully registered!'

      echo '${local.gateway_rendered_yaml}' | kubectl --kubeconfig ./build/talos/k8s_config.yaml apply -f -
      echo '✅ Gateway API configuration deployed.'
      sleep 10

      echo '🚀 Restarting Cilium Operator to accept the Gateway API CRDs...'
      kubectl --kubeconfig ./build/talos/k8s_config.yaml rollout restart deployment -n cilium-system cilium-operator
      
      echo '⏳ Waiting for Cilium Operator be Ready...'
      kubectl --kubeconfig ./build/talos/k8s_config.yaml rollout status deployment/cilium-operator -n cilium-system --timeout=300s
      echo '✅ Gateway API and Cilium Operador Running & Ready.'
      sleep 20
    EOT
    quiet = true
  }
}

resource "null_resource" "talos_ceph_csi_requisites" {

  count      = local.is_talos_deployment ? 1 : 0
  depends_on = [null_resource.talos_cilium_gateway_setup]

  provisioner "local-exec" {
    command = nonsensitive(<<-EOF
      echo '📦 Deploying CEPH CSI (RBD + CephFS) into Talos kubernetes cluster...'

      # Pre-load images to all nodes before deployment
      echo "🚀 Pre-loading Ceph CSI (${var.k8s_ceph_version}) images on Talos worker nodes..."
      talosctl --talosconfig ./build/talos/talosconfig image pull quay.io/cephcsi/cephcsi:v${var.k8s_ceph_version} --nodes ${local.talos_workers_nodes_ips} --namespace cri
      echo '✅ Images pre-loaded.'
      sleep 5

      echo '📦 Creating namespace ceph-system...'
      kubectl --kubeconfig ./build/talos/k8s_config.yaml create namespace ceph-system --dry-run=client -o yaml | kubectl --kubeconfig ./build/talos/k8s_config.yaml apply -f -
      kubectl --kubeconfig ./build/talos/k8s_config.yaml label namespace ceph-system pod-security.kubernetes.io/enforce=privileged --overwrite
      kubectl --kubeconfig ./build/talos/k8s_config.yaml label namespace ceph-system pod-security.kubernetes.io/audit=privileged --overwrite
      kubectl --kubeconfig ./build/talos/k8s_config.yaml label namespace ceph-system pod-security.kubernetes.io/warn=privileged --overwrite

      sleep 10

      echo '📦 Deploying Ceph CSI Secret and StorageClass...'
      cat <<-EOT > "./build/talos/rendered_ceph_config.yaml"
      ${local.ceph_csi_requisites_redered_yaml}
      EOT
      kubectl --kubeconfig ./build/talos/k8s_config.yaml apply -f "./build/talos/rendered_ceph_config.yaml"
      sleep 5
      rm -f "./build/talos/rendered_ceph_config.yaml"
      echo '✅ Ceph CSI Secret and StorageClass successfully deployed.'
      sleep 15
    EOF
    )
    quiet = true
  }
}

resource "null_resource" "talos_ceph_csi_shared_config" {
  count      = local.is_talos_deployment ? 1 : 0
  
  depends_on = [
    null_resource.talos_ceph_csi_requisites
  ]

  triggers = {
    config_data = jsonencode([
      {
        clusterID = local.talos_ceph_csi_values.clusterID
        monitors  = [for node in local.talos_ceph_csi_values.ceph_monitors_list : "${node}:6789"]
      }
    ])
  }

  provisioner "local-exec" {
    command = <<-EOT
      cat <<-EOF | kubectl --kubeconfig=./build/talos/k8s_config.yaml apply -f -
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: ceph-csi-config
        namespace: ceph-system
      data:
        config.json: '${self.triggers.config_data}'
      EOF
      echo '✅ Ceph Shared ConfigMap created.'
      sleep 10
    EOT
    quiet = true
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl --kubeconfig=./build/talos/k8s_config.yaml delete configmap ceph-csi-config -n ceph-system"
    quiet   = true
  }
}

resource "helm_release" "talos_ceph_csi_rbd" {
  count            = local.is_talos_deployment ? 1 : 0
  name             = "ceph-csi-rbd"
  repository       = "https://ceph.github.io/csi-charts"
  chart            = "ceph-csi-rbd"
  version          = var.k8s_ceph_version
  namespace        = "ceph-system"
  create_namespace = true

  atomic           = true 
  cleanup_on_fail  = true

  # Pass the logic from your template 
  values = [
    templatefile(
      "${path.module}/templates/talos/ceph-rbd-csi-helm-values.yaml.tftpl",
      { replica_count = local.talos_ceph_csi_values.replica_count } 
    )
  ]

  depends_on = [
    null_resource.talos_ceph_csi_requisites,
    null_resource.talos_ceph_csi_shared_config
  ]
}

resource "helm_release" "talos_ceph_csi_cephfs" {
  count            = local.is_talos_deployment ? 1 : 0
  name             = "ceph-csi-cephfs"
  repository       = "https://ceph.github.io/csi-charts"
  chart            = "ceph-csi-cephfs"
  version          = var.k8s_ceph_version
  namespace        = "ceph-system"
  create_namespace = true

  atomic           = true 
  cleanup_on_fail  = true

  values = [
    templatefile(
      "${path.module}/templates/talos/ceph-fs-csi-helm-values.yaml.tftpl",
      { replica_count = local.talos_ceph_csi_values.replica_count } 
    )
  ]

  depends_on = [
    null_resource.talos_ceph_csi_requisites,
    null_resource.talos_ceph_csi_shared_config,
    helm_release.talos_ceph_csi_rbd
  ]
}

resource "null_resource" "talos_verify_ceph_csi" {
  count      = local.is_talos_deployment ? 1 : 0
  depends_on = [helm_release.talos_ceph_csi_rbd, helm_release.talos_ceph_csi_cephfs]

  provisioner "local-exec" {
    command = <<EOT
      echo '⏳ Validating Ceph CSI deployment status...'
      
      # Define KUBECONFIG for clarity
      export KUBECONFIG=./build/talos/k8s_config.yaml

      # Wait for resources to be ready
      kubectl rollout status daemonset/ceph-csi-rbd-nodeplugin -n ceph-system --timeout=720s
      kubectl rollout status daemonset/ceph-csi-cephfs-nodeplugin -n ceph-system --timeout=720s
      kubectl rollout status deployment/ceph-csi-rbd-provisioner -n ceph-system --timeout=720s
      kubectl rollout status deployment/ceph-csi-cephfs-provisioner -n ceph-system --timeout=720s

      echo '✅ Ceph CSI is fully Running & Ready.'
      sleep 10
    EOT
    quiet = true
  }
}