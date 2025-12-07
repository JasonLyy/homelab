variable "portainer_ip_address" {
  description = "IP address for the Portainer VM"
  type        = string
}

variable "ssh_authorized_key" {
  description = "SSH public key for the VM"
  type        = string
}

resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = "node1"
  url          = "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
  file_name    = "ubuntu-24.04-server-cloudimg-amd64.img"
}

resource "proxmox_virtual_environment_file" "portainer_cloud_init" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = "node1"

  source_raw {
    data = templatefile("${path.module}/cloud-init/portainer.yaml", {
      ssh_key = var.ssh_authorized_key
    })
    file_name = "portainer-cloud-init.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "portainer" {
  name      = "portainer"
  node_name = "node1"

  agent {
    enabled = true
  }

  operating_system {
    type = "l26"
  }

  cpu {
    cores = 2
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 2048
  }

  network_device {
    bridge = "vmbr1"
  }

  disk {
    datastore_id = "local-zfs"
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image.id
    file_format  = "raw"
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 20
  }

  initialization {
    datastore_id = "local-zfs"
    ip_config {
      ipv4 {
        address = "${var.portainer_ip_address}/24"
        gateway = var.default_gateway_address
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.portainer_cloud_init.id
  }
}
