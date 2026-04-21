terraform {
  required_version = ">= 1.14.8"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.102.0"
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