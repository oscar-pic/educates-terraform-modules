module "proxmox_for_educates" {
  source = "../../infrastructure/proxmox-for-educates"

  deployment_flavor                      = var.deployment_flavor
  environment                            = var.environment
  proxmox_nodes                          = var.proxmox_nodes
  proxmox_nodes_ceph_IPs                 = var.proxmox_nodes_ceph_IPs
  proxmox_endpoint                       = var.proxmox_endpoint
  proxmox_api_token                      = var.proxmox_api_token
  proxmox_ceph_clusterID                 = var.proxmox_ceph_clusterID
  proxmox_ceph_k8s_key                   = var.proxmox_ceph_k8s_key
  k8s_cert_strategy                      = var.k8s_cert_strategy
  k8s_certs_path                         = var.k8s_cert_strategy == "provided" ? abspath(var.k8s_certs_path) : ""
  k8s_apps_cert_domains                  = var.k8s_apps_cert_domains
  k8s_letsencrypt_email                  = var.k8s_letsencrypt_email
  k8s_letsencrypt_dns_provider_api_token = var.k8s_letsencrypt_dns_provider_api_token
  k8s_gateway_api_lb_ip_range            = var.k8s_gateway_api_lb_ip_range
  proxmox_images_snippets_datastore      = var.proxmox_images_snippets_datastore
  proxmox_vms_datastore                  = var.proxmox_vms_datastore
  cloud_image_url                        = var.cloud_image_url
  proxmox_image_filename                 = var.proxmox_image_filename
  k8s_cluster_name                       = var.k8s_cluster_name
  talos_compiled_version                 = var.talos_compiled_version
  talos_compiled_extensions              = var.talos_compiled_extensions
  ssh_private_key_path                   = var.ssh_private_key_path
  ssh_public_key_path                    = var.ssh_public_key_path
  k8s_api_endpoint_vip                   = var.k8s_api_endpoint_vip
  k8s_api_cp_interface                   = var.k8s_api_cp_interface
  k8s_cluster_token                      = var.k8s_cluster_token
  k8s_ceph_node_interface                = var.k8s_ceph_node_interface
  k8s_ceph_network_cidr                  = var.k8s_ceph_network_cidr
  k8s_cilium_version                     = var.k8s_cilium_version
  k8s_cert_manager_version               = var.k8s_cert_manager_version
  k8s_ceph_version                       = var.k8s_ceph_version
  system_timezone                        = var.system_timezone
  kube_nodes                             = var.kube_nodes
}

# This "extracts" the summary that the module calculated and displays it in the root console.
output "infrastructure_summary" {
  value       = module.proxmox_for_educates.infrastructure_summary
  description = "Summary of the deployed infrastructure"
}


