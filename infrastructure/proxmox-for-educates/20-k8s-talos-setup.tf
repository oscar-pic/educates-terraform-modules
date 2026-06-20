locals {
  is_talos_deployment = var.deployment_flavor == "talos-cluster"

  talos_bootstrap_node = local.is_talos_deployment ? {
    for k, v in var.kube_nodes : k => v if strcontains(v.type, "talos-controlplane-bootstrap")
  } : {}

  talos_bootstrap_node_name = keys(local.talos_bootstrap_node)[0]
  talos_bootstrap_node_ip = split("/", values(local.talos_bootstrap_node)[0].ip_address)[0]

  # Filter controlplane nodes (bootstrap and standard ones)
  talos_cp_nodes = local.is_talos_deployment ? {
    for k, v in var.kube_nodes : k => v if strcontains(v.type, "controlplane")
  } : {}

  # Filter worker nodes
  talos_worker_nodes = local.is_talos_deployment ? {
    for k, v in var.kube_nodes : k => v if strcontains(v.type, "worker")
  } : {}

  # Detect if the OS is Windows (contains 'windows' in the system architecture)
  is_windows = can(regex("(?i)windows", replace(lower(abspath(path.root)), "\\", "/")))
  
  # Define the interpreter based on the OS
  interpreter = local.is_windows ? ["PowerShell", "-Command"] : ["/bin/bash", "-c"]
}

resource "talos_image_factory_schematic" "cluster_schematic" {
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
  schematic_id  = talos_image_factory_schematic.cluster_schematic.id
}

resource "talos_machine_secrets" "talos_cluster_secrets" {
  count = local.is_talos_deployment ? 1 : 0
}

data "talos_machine_configuration" "talos_config" {
  for_each         = local.is_talos_deployment ? var.kube_nodes : {}
  cluster_name     = var.talos_cluster_name
  cluster_endpoint = "https://${var.k8s_api_endpoint_vip}:6443"
  machine_type     = strcontains(each.value.type, "controlplane") ? "controlplane" : "worker"
  machine_secrets  = talos_machine_secrets.talos_cluster_secrets[0].machine_secrets

  config_patches = [
    yamlencode({
      machine = {
        install = {
          disk = "/dev/sda" # Asegura que Talos instale el OS en el disco
          wipe = true
        }
        # Configuración de NTP y Timezone
        time = {
          disabled = false
          servers = ["time.cloudflare.com", "pool.ntp.org"]
          #timezone = "Europe/Madrid"
        }
        network = {
          hostname = each.key
          interfaces = [
            {
              interface = var.k8s_api_cp_interface # Red principal
              addresses = [each.value.ip_address]
              routes    = [{ network = "0.0.0.0/0", gateway = each.value.gateway }]
              vip       = each.value.type == "controlplane" ? { ip = var.k8s_api_endpoint_vip } : null
              dhcp      = false
            },
            {
              interface = var.k8s_ceph_node_interface # Interfaz para Ceph
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
            name = "none" # Esto deshabilita el CNI por defecto (Flannel)
          }
        }
        proxy = {
          disabled = true # Esto deshabilita kube-proxy
        }
      }
    })
  ]
}

data "talos_client_configuration" "talos_config_data" {
  count = local.is_talos_deployment ? 1 : 0

  cluster_name         = var.talos_cluster_name
  client_configuration = talos_machine_secrets.talos_cluster_secrets[0].client_configuration
  endpoints            = [for k, v in local.talos_cp_nodes : split("/", v.ip_address)[0]]
}

resource "null_resource" "wait_for_talos" {
  count      = length(local.talos_bootstrap_node) > 0 ? 1 : 0
  depends_on = [proxmox_virtual_environment_vm.kube_node]

  provisioner "local-exec" {
    interpreter = local.interpreter
    command     = <<EOT
      %{if local.is_windows}
      Write-Host "Waiting for Talos API on ${local.talos_bootstrap_node_ip}..." -ForegroundColor Cyan
      do {
        $status = talosctl --talosconfig ./build/talosconfig -n ${local.talos_bootstrap_node_ip} get members 2>&1
        Start-Sleep -Seconds 5
      } until ($LASTEXITCODE -eq 0)
      Write-Host "Talos API is up and running!" -ForegroundColor Green
      %{else}
      echo "Waiting for Talos API on ${local.talos_bootstrap_node_ip}..."
      until talosctl --talosconfig ./build/talosconfig -n ${local.talos_bootstrap_node_ip} get members >/dev/null 2>&1; do
        sleep 5
      done
      echo "Talos API is up and running!"
      %{endif}
    EOT
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
  filename = "${path.module}/build/talosconfig"
}

resource "local_file" "kubeconfig" {
  count    = local.is_talos_deployment ? 1 : 0
  content  = talos_cluster_kubeconfig.kubeconfig_auth[0].kubeconfig_raw
  filename = "${path.module}/build/k8s_config.yaml"
}

resource "null_resource" "wait_for_cluster_readiness" {
  count      = local.is_talos_deployment ? 1 : 0
  depends_on = [talos_machine_bootstrap.cluster_bootstrap]

  provisioner "local-exec" {
    interpreter = local.interpreter
    # Pasamos el comando directamente. 
    # Al estar en un bloque separado, Terraform no se confunde con los operadores.
    command = <<EOT
      %{if local.is_windows}
      $nodes = @{ ${join("; ", [for k, v in var.kube_nodes : "'$k'='${split("/", v.ip_address)[0]}'"])} };
      foreach ($name in $nodes.Keys) {
        $ip = $nodes[$name];
        Write-Host "Checking services on node $name ($ip)..." -ForegroundColor Cyan;
        do {
          $services = talosctl --talosconfig ./build/talosconfig -n $ip get services;
          $ready = ($services | Select-String "kubelet|containerd" | Where-Object { $_ -match "true\s+true" } | Measure-Object).Count;
          Start-Sleep -Seconds 10;
        } until ($ready -ge 2);
      }
      Write-Host "Waiting for node ${local.talos_bootstrap_node_ip} to join K8s API..." -ForegroundColor Cyan
      do {
        # IMPORTANT: Use the bootstrap node IP directly, bypass the VIP
        $nodesCount = (kubectl --kubeconfig ./build/k8s_config.yaml -s https://${local.talos_bootstrap_node_ip}:6443 get nodes --insecure-skip-tls-verify | Select-String "Ready|NotReady" | Measure-Object).Count
        Start-Sleep -Seconds 10
      } until ($nodesCount -ge ${length(var.kube_nodes)})
      %{else}
      %{for k, v in var.kube_nodes}
      echo "Checking services on node ${k} (${split("/", v.ip_address)[0]})..."
      until talosctl --talosconfig ./build/talosconfig -n ${split("/", v.ip_address)[0]} get services | grep -E "kubelet|containerd" | awk '{if($6=="true" && $7=="true") print "OK"}' | wc -l | grep -q "2"; do
        sleep 10
      done
      %{endfor}
      echo "Waiting for nodes to join K8s API..."
      until kubectl --kubeconfig ./build/k8s_config.yaml -s https://${local.talos_bootstrap_node_ip}:6443 get nodes --insecure-skip-tls-verify | grep -c "Ready\|NotReady" | grep -q "${length(var.kube_nodes)}"; do
        sleep 10
      done
      %{endif}
    EOT
  }
}