terraform {
  required_version = ">= 1.6.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.122"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.12"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure
  # No ssh block: the Talos path only uses the Proxmox API.
}

provider "talos" {}

# Helm without cluster access: only renders charts (Cilium, the storage drivers).
provider "helm" {
  alias = "template"
}

provider "kubectl" {
  host                   = module.cluster.kubernetes.host
  cluster_ca_certificate = module.cluster.kubernetes.cluster_ca_certificate
  client_certificate     = module.cluster.kubernetes.client_certificate
  client_key             = module.cluster.kubernetes.client_key
  load_config_file       = false
  # Retry for ~8 minutes (exponential backoff, 3 s to 30 s) instead of failing the first
  # apply. The Talos health check can pass before Cilium registers its CRDs (LoadBalancer
  # IP pool), and before the API is stable: etcd on slow shared storage can lose its
  # leader for a minute right after bootstrap, while every node pulls images.
  apply_retry_count = 20
}
