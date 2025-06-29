Collecting workspace information# Homelab Setup Guide

This repository contains configurations for a Kubernetes homelab environment running on Proxmox with Talos Linux. The setup includes infrastructure as code (Terraform), Kubernetes configuration, and application deployment using Helmfile.

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) (v1.0.0+)
- [Proxmox VE](https://www.proxmox.com/en/proxmox-ve) already configured
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [talosctl](https://www.talos.dev/v1.9/introduction/getting-started/)
- [helmfile](https://github.com/helmfile/helmfile)
- [kustomize](https://kustomize.io/)

## Directory Structure

```
homelab/
├── kubernetes/            # Kubernetes configurations
│   ├── helmfile.yaml      # Helmfile definitions
│   ├── security.yaml      # Security context defaults
│   ├── kustomize/         # Kustomize configuration
│   └── values/            # Helm chart values
│       ├── alloy/
│       ├── grafana/
│       ├── ingress-nginx/
│       └── loki/
└── terraform/             # Infrastructure definitions
    ├── main.tf            # Terraform main configuration
    ├── kubernetes.tf      # Kubernetes cluster creation
    ├── patches/           # Talos configuration patches
    └── setup-talos-kube.sh  # Setup script
```

## Setup Instructions

### 1. Provision Infrastructure with Terraform

First, configure the Terraform variables:

```sh
cd terraform
cp variables.tfvars.example variables.tfvars
```

Edit `variables.tfvars` with your Proxmox connection details and IP configurations.

Initialize Terraform and apply the configuration:

```sh
terraform init
terraform apply -var-file="variables.tfvars"
```

This will:
1. Create Talos control plane and worker VMs in Proxmox
2. Configure the Talos machines
3. Bootstrap the Kubernetes cluster

### 2. Configure Kubernetes Access

Run the setup script to install required tools and configure access:

```sh
chmod +x setup-talos-kube.sh
./setup-talos-kube.sh
```

This script will:
- Install `talosctl` and `kubectl` if needed
- Configure the Talos and Kubernetes access credentials

### 3. Deploy Local Storage Provisioner

Apply the local-path-provisioner using kustomize:

```sh
cd ../kubernetes
kubectl apply -k kustomize/local-path-provisioner
```

This creates a default StorageClass for persistent volumes.

### 4. Deploy Applications with Helmfile

Deploy all applications defined in helmfile.yaml:

```sh
helmfile sync
```

This will deploy:
- Ingress NGINX Controller
- Grafana dashboard
- Loki log aggregation
- Alloy observability agent

## Accessing Services

After deployment, you can access the following services:

- Grafana: http://grafana.local
- Alloy: http://alloy.local
- Ingress controller: NodePort 30080 (HTTP) and 30443 (HTTPS)
- Syslog for OPNsense: TCP port 5140 (forwarded through ingress)

## Components

### Infrastructure
- **Proxmox VE**: Virtualization platform
- **Talos Linux**: Kubernetes-focused immutable Linux distribution

### Kubernetes Management
- **Local Path Provisioner**: Simple hostPath-based storage provisioner
- **Ingress NGINX**: Kubernetes ingress controller

### Observability Stack
- **Grafana**: Visualization and dashboarding
- **Loki**: Log aggregation system
- **Alloy**: All-in-one observability agent (replaces Promtail)

## Security

Default security contexts are applied to all deployments to enforce:
- Non-root containers
- Read-only root filesystems
- No privilege escalation
- Dropped capabilities

## Maintenance

To update configurations:
1. Modify Terraform files for infrastructure changes
2. Edit values in values for application configuration
3. Run `helmfile apply` to update applications

For Talos OS updates, refer to the [Talos documentation](https://www.talos.dev/v1.9/talos-guides/upgrading-talos/).