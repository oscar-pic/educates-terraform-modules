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
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.1.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.2.0"
    }
    # kubectl = {
    #   source  = "gavinbunney/kubectl"
    #   version = ">= 1.19.0"
    # }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.2.1"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.8.0"
    }
    null = { # Added this for completeness
      source  = "hashicorp/null"
      version = "~> 3.2.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13.1" # Or your preferred version
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
  # This line now takes "192.168.1.29/24" and results in "192.168.1.29"
  raw_endpoint     = var.k8s_api_endpoint_vip != "" ? var.k8s_api_endpoint_vip : local.nodes_list[0].ip_address
  k8s_api_endpoint = split("/", local.raw_endpoint)[0]
}

provider "kubernetes" {
  host     = "https://${local.k8s_api_endpoint}:6443"
  # insecure = true
  # This tells Terraform: "If the file isn't there yet, don't crash."
  # config_path = fileexists("${path.module}/k8s_config.yaml") ? "${path.module}/k8s_config.yaml" : null
  cluster_ca_certificate = base64decode(yamldecode(data.local_file.kubeconfig.content).clusters[0].cluster.certificate-authority-data)
  client_certificate     = base64decode(yamldecode(data.local_file.kubeconfig.content).users[0].user.client-certificate-data)
  client_key             = base64decode(yamldecode(data.local_file.kubeconfig.content).users[0].user.client-key-data)
}

provider "kubectl" {
  host     = "https://${local.k8s_api_endpoint}:6443"
  #insecure = true
# 1. Load the CA Certificate
  cluster_ca_certificate = base64decode(yamldecode(data.local_file.kubeconfig.content).clusters[0].cluster.certificate-authority-data)
  # 2. Load the Client Certificate (instead of token)
  client_certificate = base64decode(yamldecode(data.local_file.kubeconfig.content).users[0].user.client-certificate-data)
  # 3. Load the Client Key
  client_key = base64decode(yamldecode(data.local_file.kubeconfig.content).users[0].user.client-key-data)
  load_config_file = false
}