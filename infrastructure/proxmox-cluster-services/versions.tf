terraform {
  required_version = ">= 1.6.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    # Same provider as platform/educates; applies manifests whose CRDs only exist
    # once the cluster runs (Cilium IP pools).
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
  }
}
