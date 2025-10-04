resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" { # ISO content type stored on 'local' (supports iso)
  content_type = "iso"
  datastore_id = "local"
  node_name    = "node1"
  url          = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  file_name    = "ubuntu-24.04-cloudimg-amd64.img"
}

resource "proxmox_virtual_environment_vm" "portainer" {
  name      = "portainer"
  node_name = "node1"

  agent { enabled = true }

  operating_system { type = "l26" }

  cpu {
    cores = 2
    type  = "x86-64-v2-AES"
  }

  memory { dedicated = 4096 }

  network_device {
    bridge = "vmbr0"
  }

  disk {
    datastore_id = "local-zfs"
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image.id
    file_format  = "raw"
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 40 # GB
  }

  # Add serial device ired for Ubuntu per provider known issues to avoid kernel panic on resize
  serial_device {}

  initialization {
    datastore_id = "local-zfs"

    ip_config {
      ipv4 {
        address = "${var.portainer_ip_address}/24"
        gateway = var.default_gateway_address
      }
    }

    # Use full cloud-init as user_data_file_id; cannot include user_account simultaneously per schema, so embed in cloud-config
    user_data_file_id = proxmox_virtual_environment_file.portainer_user_cloud_init.id
  }
}

variable "portainer_ip_address" { type = string }
variable "ssh_authorized_key" { type = string }

resource "proxmox_virtual_environment_file" "portainer_user_cloud_init" {
  content_type = "snippets"
  datastore_id = "local" # Ensure 'Snippets' content type is enabled on 'local' storage in Proxmox UI
  node_name    = "node1"

  source_raw {
    data      = <<-EOT
      #cloud-config
      hostname: portainer
      users:
        - name: ubuntu
          shell: /bin/bash
          sudo: ALL=(ALL) NOPASSWD:ALL
          groups: [sudo]
          ssh_authorized_keys:
            - ${jsonencode(var.ssh_authorized_key)}
      package_update: true
      package_upgrade: true
      write_files:
        - path: /etc/docker/daemon.json
          permissions: '0644'
          owner: root:root
          content: |
            {"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}
      runcmd:
        - |
          export DEBIAN_FRONTEND=noninteractive
          apt-get update -y || true
          # Ensure SSH server present (in case image variant changes) and guest agent
          apt-get install -y openssh-server qemu-guest-agent || true
          systemctl enable --now qemu-guest-agent || true
        - |
          if ! command -v docker >/dev/null 2>&1; then
            curl -fsSL https://get.docker.com | sh
          fi
          usermod -aG docker ubuntu || true
          systemctl enable docker --now
        - docker volume create portainer_data || true
        - |
          if [ -z "$(docker ps -q -f name=portainer)" ]; then
            docker run -d \
              -p 8000:8000 -p 9443:9443 \
              --name portainer \
              --restart=always \
              -v /var/run/docker.sock:/var/run/docker.sock \
              -v portainer_data:/data \
              portainer/portainer-ce:latest
          fi
      final_message: "Portainer installation complete. Access at https://${var.portainer_ip_address}:9443"
    EOT
    file_name = "portainer-user.yaml"
  }
}

output "portainer_url" {
  value       = "https://${var.portainer_ip_address}:9443"
  description = "URL to access Portainer Web UI"
}
