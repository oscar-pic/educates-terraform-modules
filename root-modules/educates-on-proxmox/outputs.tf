output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = module.cluster.cluster_endpoint
}

output "nodes" {
  description = "Cluster nodes."
  value       = module.cluster.nodes
}

output "talos_installer_image" {
  description = "Installer image for 'talosctl upgrade --image'."
  value       = module.cluster.talos_installer_image
}

output "kubeconfig" {
  description = "Admin kubeconfig ('tofu output -raw kubeconfig')."
  value       = module.cluster.kubeconfig
  sensitive   = true
}

output "talosconfig" {
  description = "talosctl configuration ('tofu output -raw talosconfig')."
  value       = module.cluster.talosconfig
  sensitive   = true
}

output "storage_classes" {
  description = "StorageClasses available in the cluster (default first)."
  value       = concat([module.cluster.default_storage_class], [for c in module.cluster.storage_classes : c if c != module.cluster.default_storage_class])
}
