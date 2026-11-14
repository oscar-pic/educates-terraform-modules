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
    # Two Helm configurations:
    # - helm.template, without cluster access: renders the Cilium chart into the Talos
    #   configuration, before the cluster exists.
    # - helm (default), with access to the cluster this module creates: CSI drivers.
    helm = {
      source                = "hashicorp/helm"
      version               = "~> 3.3"
      configuration_aliases = [helm.template]
    }
    # Same provider as platform/educates; applies manifests whose CRDs only exist
    # once the cluster runs (Cilium IP pools).
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
  }
}
