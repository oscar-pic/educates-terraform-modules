output "cluster_name" {
  description = "Cluster name."
  value       = var.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint (the VIP, or the only control-plane node)."
  value       = local.cluster_endpoint
}

output "kubeconfig" {
  description = "Admin kubeconfig. Break-glass access: hand out OIDC access to people instead."
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "kubernetes" {
  description = "Connection details for the kubernetes/helm/kubectl providers of the root module."
  value = {
    host                   = local.cluster_endpoint
    cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
    client_certificate     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
    client_key             = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
  }
  sensitive = true
}

output "talosconfig" {
  description = "talosctl client configuration."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "talos_installer_image" {
  description = "Installer image to use with 'talosctl upgrade --image' (same schematic as the running nodes)."
  value       = data.talos_image_factory_urls.this.urls.installer
}

output "nodes" {
  description = "Nodes with their VM ID, role and IP."
  value = {
    for k, n in var.nodes : local.hostnames[k] => {
      role         = n.role
      ip           = n.ip
      proxmox_node = n.proxmox_node
      vm_id        = proxmox_virtual_environment_vm.node[k].vm_id
    }
  }
}

output "health_check" {
  description = "Set once the cluster passed the Talos health check (etcd, API, all nodes Ready)."
  value       = data.talos_cluster_health.this.id
}

output "storage_classes" {
  description = "StorageClasses created by this module (CSI drivers)."
  value       = local.storage_classes
}

output "default_storage_class" {
  description = "Default StorageClass."
  value       = var.default_storage_class
}
