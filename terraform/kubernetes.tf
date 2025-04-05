resource "proxmox_virtual_environment_vm" "talos-master-1" {
  name      = "k3s-master-1"
  node_name = "node1"

  agent {
    enabled = true
  }

  operating_system {
    type = "l26" # Linux Kernel 2.6 - 5.X.
  }

  cpu {
    cores = 2
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 2148 // 2048 MiB 
  }

  network_device {
    bridge = "vmbr0"
  }

  disk {
    datastore_id = "local-zfs"
    file_id      = proxmox_virtual_environment_download_file.talos_cloud_image.id
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
        address = "${var.talos_cp_01_ip_address}/24"
        gateway = var.default_gateway_address
      }
    }
  }
}

resource "proxmox_virtual_environment_vm" "talos-worker-1" {
  name      = "k3s-worker-1"
  node_name = "node1"

  agent {
    enabled = true
  }

  operating_system {
    type = "l26" # Linux Kernel 2.6 - 5.X.
  }

  cpu {
    cores = 1
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 1074 // 1024 MiB
  }

  network_device {
    bridge = "vmbr0"
  }

  disk {
    datastore_id = "local-zfs"
    file_id      = proxmox_virtual_environment_download_file.talos_cloud_image.id
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
        address = "${var.talos_worker_01_ip_address}/24"
        gateway = var.default_gateway_address
      }
    }
  }
}

resource "proxmox_virtual_environment_download_file" "talos_cloud_image" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = "node1"
  url          = "https://factory.talos.dev/image/fe51ff41dd26cd8f531afcf2df2e776ad9cbf2cce9358dd2c1899b63cda9a021/v1.9.5/nocloud-amd64.iso"
  file_name    = "talos-1.9.5-metal-amd64.img"
}

resource "talos_machine_secrets" "machine_secrets" {}

data "talos_client_configuration" "talosconfig" {
  cluster_name         = local.cluster_name
  client_configuration = talos_machine_secrets.machine_secrets.client_configuration
  endpoints            = [var.talos_cp_01_ip_address]
}

data "talos_machine_configuration" "machineconfig_cp" {
  cluster_name     = local.cluster_name
  cluster_endpoint = "https://${var.talos_cp_01_ip_address}:6443"
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.machine_secrets.machine_secrets
  config_patches = [
    yamlencode({
      machine = {
        install = {
          disk = "/dev/vda" # Match Proxmox's disk interface (e.g., "/dev/vda" for virtio)
        }
      }
    })
  ]
}

resource "talos_machine_configuration_apply" "cp_config_apply" {
  depends_on                  = [proxmox_virtual_environment_vm.talos-master-1]
  client_configuration        = talos_machine_secrets.machine_secrets.client_configuration
  machine_configuration_input = data.talos_machine_configuration.machineconfig_cp.machine_configuration
  node                        = var.talos_cp_01_ip_address
}

data "talos_machine_configuration" "machineconfig_worker" {
  cluster_name     = local.cluster_name
  cluster_endpoint = "https://${var.talos_cp_01_ip_address}:6443"
  machine_type     = "worker"
  machine_secrets  = talos_machine_secrets.machine_secrets.machine_secrets
  config_patches = [
    yamlencode({
      machine = {
        install = {
          disk = "/dev/vda" # Match Proxmox's disk interface (e.g., "/dev/vda" for virtio)
        }
      }
    })
  ]
}

resource "talos_machine_configuration_apply" "worker_config_apply" {
  depends_on                  = [proxmox_virtual_environment_vm.talos-worker-1]
  client_configuration        = talos_machine_secrets.machine_secrets.client_configuration
  machine_configuration_input = data.talos_machine_configuration.machineconfig_worker.machine_configuration
  node                        = var.talos_worker_01_ip_address
}

resource "talos_machine_bootstrap" "bootstrap" {
  depends_on           = [talos_machine_configuration_apply.cp_config_apply]
  client_configuration = talos_machine_secrets.machine_secrets.client_configuration
  node                 = var.talos_cp_01_ip_address
  timeouts = {
    create = "60s"
  }
}

data "talos_cluster_health" "health" {
  depends_on             = [talos_machine_configuration_apply.cp_config_apply, talos_machine_configuration_apply.worker_config_apply]
  client_configuration   = data.talos_client_configuration.talosconfig.client_configuration
  control_plane_nodes    = [var.talos_cp_01_ip_address]
  worker_nodes           = [var.talos_worker_01_ip_address]
  endpoints              = data.talos_client_configuration.talosconfig.endpoints
  skip_kubernetes_checks = true
  timeouts = {
    read = "180s"
  }
}

resource "talos_cluster_kubeconfig" "kubeconfig" {
  depends_on           = [talos_machine_bootstrap.bootstrap, data.talos_cluster_health.health]
  client_configuration = talos_machine_secrets.machine_secrets.client_configuration
  node                 = var.talos_cp_01_ip_address
}

output "talosconfig" {
  value     = data.talos_client_configuration.talosconfig.talos_config
  sensitive = true
}

output "kubeconfig" {
  value     = resource.talos_cluster_kubeconfig.kubeconfig.kubeconfig_raw
  sensitive = true
}

locals {
  cluster_name = "homelab"
}

variable "default_gateway_address" {
  type = string
}

variable "talos_cp_01_ip_address" {
  type = string
}

variable "talos_worker_01_ip_address" {
  type = string
}
