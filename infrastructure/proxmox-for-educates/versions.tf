terraform {
  # Works with OpenTofu and Terraform.
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
    # Only used to render the Cilium chart (data "helm_template"); this module never
    # talks to the cluster through Helm. Pass a Helm provider without cluster access.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
  }
}
