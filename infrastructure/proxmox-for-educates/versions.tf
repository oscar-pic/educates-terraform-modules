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
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = true # Set to false if you have valid SSL certs for Proxmox
  ssh {
    agent       = false # Explicitly off
    username    = "root"
    private_key = file(var.ssh_private_key_path) # This is the "Key" (pun intended)
  }
}

# Provider configurations using your local IP
locals {
  # Logic: Use override if set, otherwise pull the IP from the specific node key
  nodes_list       = values(var.kube_nodes)
  # This line now takes "192.168.1.29/24" and results in "192.168.1.29"
  raw_endpoint     = var.k8s_api_endpoint_vip != "" ? var.k8s_api_endpoint_vip : local.nodes_list[0].ip_address
  k8s_api_endpoint = split("/", local.raw_endpoint)[0]
}