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
    # Only renders charts, without cluster access (alias helm.template): Cilium into the
    # Talos configuration, and the storage drivers, applied with kubectl.
    helm = {
      source                = "hashicorp/helm"
      version               = "~> 3.3"
      configuration_aliases = [helm.template]
    }
    # Same provider as platform/educates. Applies the cluster services (storage drivers,
    # Cilium IP pools) object by object, and retries while the API settles.
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
  }
}
