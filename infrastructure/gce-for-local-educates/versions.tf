terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "6.47.0"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "4.1.0"
    }
  }

  required_version = ">= 1.5.0"
}
