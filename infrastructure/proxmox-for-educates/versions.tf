terraform {
  required_version = ">= 1.14.8"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.102.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.5.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.2.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.2.1"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = true # Set to true if you use self-signed certificates
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
  k8s_api_endpoint = var.k8s_api_endpoint_vip != "" ? var.k8s_api_endpoint_vip : local.nodes_list[0].ip_address
}

provider "kubernetes" {
  host     = "https://${local.k8s_api_endpoint}:6443"
  insecure = true
}

provider "kubectl" {
  host     = "https://${local.k8s_api_endpoint}:6443"
  insecure = true
}