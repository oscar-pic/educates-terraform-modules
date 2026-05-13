terraform {
  # Minimum Terraform version required
  required_version = ">= 1.14.8"

  required_providers {
    # Proxmox provider for VM orchestration
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.102.0"
    }
    # Local provider to manage the kubeconfig file on the host machine
    local = {
      source  = "hashicorp/local"
      version = ">= 2.8.0"
    }
    # Null provider for executing the K8s wait scripts (local-exec)
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2.0"
    }
    # Pause Multiplatform
    time = {
      source  = "hashicorp/time"
      version = ">= 0.14.0"
    }
    # To read files by SSH without local commands
    ssh = {
      source  = "loafoe/ssh"
      version = ">= 2.7.0"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = true # Set to false if you have valid SSL certs for Proxmox
  ssh {
    # Block to configure SSH access for Proxmox provider when needed (e.g., for file uploads, snippets or remote execution)
    # If snippets datasotre is local, provider will force to use SSH to upload files. 
    # If it's shared, it's recommended to use an NFS datastore and this ssh block can be commented out.
    agent       = false # Explicitly off
    username    = "root"
    private_key = file(var.ssh_private_key_path) # This is the "Key" (pun intended)
    # Force the provider to bypass the Proxmox API and resolve proxmox nodes by local DNS. 
    # It's to avoid that Proxmox API choose an incorrect IP for Proxmox node.
    node_address_source = "dns"
  }
}

# Provider configurations using your local IP
locals {
  # Logic: Use override if set, otherwise pull the IP from the specific node key
  nodes_list       = values(var.kube_nodes)
  # This line now takes "192.168.1.29/24" and results in "192.168.1.29, for example"
  raw_endpoint     = var.k8s_api_endpoint_vip != "" ? var.k8s_api_endpoint_vip : local.nodes_list[0].ip_address
  k8s_api_endpoint = split("/", local.raw_endpoint)[0]
}