terraform {
  backend "remote" {
    hostname     = "app.terraform.io"
    organization = "jason-homelab"

    workspaces {
      name = "homelab"
    }
  }

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.72.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.7.1"
    }
  }
}

provider "proxmox" {
  endpoint = var.proxmox_api_url
  insecure = true
  username = var.proxmox_username
  password = var.proxmox_password

  # Unable to use api_token to work with siderolabs/talos

  # endpoint  = var.proxmox_api_url
  # api_token = var.proxmox_api_token
  # insecure  = true
  # ssh {
  #   agent    = true
  #   username = "terraform"
  # }
}

variable "proxmox_api_url" {
  description = "Proxmox API URL"
  type        = string
}

variable "proxmox_username" {
  description = "Proxmox Username"
  type        = string
  sensitive   = true
}

variable "proxmox_password" {
  description = "Proxmox Password"
  type        = string
}
