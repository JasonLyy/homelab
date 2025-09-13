# Homelab Setup Guide

This repository contains configurations for a Kubernetes homelab environment running on Proxmox with Talos Linux. The setup includes infrastructure as code (Terraform), Kubernetes configuration, and application deployment using Helmfile.

## Architecture Overview

### Infrastructure Stack

- **Hypervisor**: Proxmox VE with ZFS storage
- **Operating System**: Talos Linux v1.9.5 (immutable Kubernetes OS)
- **Cluster**: 1 control plane + 1 worker node (control plane scheduling enabled)
- **Network**: Static IP configuration (192.168.1.200/201)
- **Storage**: Local Path Provisioner with hostPath-based persistent volumes

### Application Stack

- **Ingress**: NGINX Controller with NodePort (30080/30443)
- **Monitoring**: Prometheus + Grafana + Node Exporter
- **Logging**: Loki + Alloy (modern replacement for Promtail)
- **Security**: Pod security contexts, non-root containers, capability dropping
- **Secure Remote Access**: Tailscale Operator providing a Kubernetes-based exit node

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
│   │   └── local-path-provisioner/  # Storage provisioner
│   └── values/            # Helm chart values
│       ├── alloy/         # Observability agent config
│       ├── grafana/       # Dashboard configuration
│       ├── ingress-nginx/ # Ingress controller config
│       ├── kube-prometheus-stack/  # Prometheus stack
│       └── loki/          # Log aggregation config
└── terraform/             # Infrastructure definitions
    ├── main.tf            # Terraform main configuration
    ├── kubernetes.tf      # Kubernetes cluster creation
    ├── variables.tfvars   # Environment variables
    ├── patches/           # Talos configuration patches
    └── setup-talos-kube.sh  # Setup script
```

## Setup Instructions

### (Optional) Tailscale Exit Node Setup (Kubernetes-Based)

This repo includes a minimal Tailscale Operator deployment that provisions a single exit node pod via a `Connector` custom resource.

#### 1. Create a Tailscale OAuth Client

In the Tailscale admin console:

- Scopes: Devices (Core) read/write, Auth Keys read/write
- Tags: `tag:k8s-operator`

#### 2. Add / Update Tailnet Policy (ACL)

Add a minimal ACL snippet (merge into your existing policy file):

```json
{
  "tagOwners": {
    "tag:k8s-operator": [],
    "tag:k8s": ["tag:k8s-operator"]
  },
  "autoApprovers": {
    "exitNode": ["tag:k8s"]
  }
}
```

This allows the operator (tagged `tag:k8s-operator`) to create the exit node instance (tagged `tag:k8s`) and auto-approve exit node advertising.

#### 3. Create the OAuth Secret

Replace the placeholders with your client credentials:

```sh
kubectl -n tailscale create secret generic operator-oauth \
  --from-literal=client_id="<CLIENT_ID>" \
  --from-literal=client_secret="<CLIENT_SECRET>"
```

Note: The operator (chart v1.86.5) expects the secret name `operator-oauth` with keys `client_id` and `client_secret`.

#### 4. Deploy / Reconcile with Helmfile

```sh
cd kubernetes
helmfile sync --selector name=tailscale-operator
```

The Helmfile preSync hook automatically labels the `tailscale` namespace with privileged Pod Security settings required for exit node networking (sysctls & NET_ADMIN).

#### 5. Verify Exit Node Pod

```sh
kubectl get pods -n tailscale -l tailscale.com/parent-resource=homelab-exit
kubectl logs -n tailscale deploy/operator | grep homelab-exit -i
```

You should see a pod named like `ts-homelab-exit-<suffix>-0` in Running state.

#### 6. Use the Exit Node

From any authorized Tailscale client:

```sh
tailscale up --exit-node=homelab-exit
```

Or pick it in the GUI clients (it will appear once the pod registers).

#### 7. Troubleshooting

| Symptom                                     | Likely Cause                     | Fix                                                |
| ------------------------------------------- | -------------------------------- | -------------------------------------------------- |
| Pod stuck Pending with PodSecurity warnings | Namespace not labeled privileged | Run namespace label command (see below)            |
| Operator crash: missing /oauth/client_id    | Secret key names incorrect       | Recreate secret with `client_id` / `client_secret` |
| Exit node not visible in clients            | ACL / tag policy missing         | Ensure ACL snippet merged & OAuth client tagged    |

Namespace label command (idempotent):

```sh
kubectl label ns tailscale \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged --overwrite
```

#### 8. Removing the Exit Node

```sh
kubectl delete connector homelab-exit
helmfile destroy --selector name=tailscale-operator
```

That will remove the CR, StatefulSet, and operator deployment.

### 1. Configure Terraform Variables

First, configure the Terraform variables for your environment:

```sh
cd terraform
# Edit variables.tfvars with your specific values
```

Required variables in `variables.tfvars`:

- `proxmox_api_url`: Your Proxmox API endpoint (e.g., `https://192.168.1.169:8006/api2/json`)
- `default_gateway_address`: Network gateway IP
- `talos_cp_01_ip_address`: Control plane node IP
- `talos_worker_01_ip_address`: Worker node IP

Also configure `secret.tfvars` with your Proxmox credentials:

- `proxmox_username`: Proxmox username
- `proxmox_password`: Proxmox password

### 2. Provision Infrastructure with Terraform

Initialize Terraform and apply the configuration:

```sh
terraform init
terraform apply -var-file="variables.tfvars" -var-file="secret.tfvars"
```

This will:

1. Download Talos Linux v1.9.5 ISO to Proxmox
2. Create control plane VM (4 vCPU, 2GB RAM, 20GB disk)
3. Create worker VM (4 vCPU, 4GB RAM, 180GB disk)
4. Configure Talos machines with proper disk settings
5. Bootstrap the Kubernetes cluster
6. Generate talosconfig and kubeconfig

### 3. Configure Kubernetes Access

Run the setup script to install required tools and configure access:

```sh
chmod +x setup-talos-kube.sh
./setup-talos-kube.sh
```

This script will:

- Install `talosctl` and `kubectl` if needed
- Configure the Talos and Kubernetes access credentials
- Set proper permissions on config files

### 4. Deploy Local Storage Provisioner

Apply the local-path-provisioner using kustomize:

```sh
cd ../kubernetes
kubectl apply -k kustomize/local-path-provisioner
```

This creates:

- A default StorageClass for persistent volumes
- Privileged namespace with proper security policies
- Storage path at `/var/local-path-provisioner` on nodes

### 5. Deploy Applications with Helmfile

Deploy all applications defined in helmfile.yaml:

```sh
helmfile sync
```

This will deploy (in order):

1. **Ingress NGINX Controller** (with NodePort access)
2. **Grafana** (dashboard and visualization)
3. **Loki** (log aggregation with MinIO backend)
4. **Alloy** (observability agent, replaces Promtail)
5. **Prometheus Stack** (metrics, alerting, and monitoring)

## Accessing Services

After deployment, you can access the following services:

### Web Interfaces

- **Grafana**: http://grafana.local (dashboards and visualization)
- **Alloy**: http://alloy.local (observability agent status)

### Internal Services (via kubectl port-forward)

- **Prometheus**: `kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090`
- **Alertmanager**: `kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093`
- **Loki**: `kubectl port-forward -n monitoring svc/loki 3100:3100`

### Network Access

- **Ingress Controller**: NodePort 30080 (HTTP) and 30443 (HTTPS)
- **OPNsense Syslog**: TCP port 5140 (forwarded through ingress to Alloy)

### DNS Configuration

Add these entries to your local DNS or `/etc/hosts`:

```
<node-ip>  grafana.local
<node-ip>  alloy.local
```

## Component Details

### Infrastructure Components

- **Proxmox VE**: Virtualization platform with ZFS storage
- **Talos Linux**: Immutable Kubernetes-focused OS (v1.9.5)
  - Control plane: 4 vCPU, 2GB RAM, 20GB disk
  - Worker: 4 vCPU, 4GB RAM, 180GB disk
  - Scheduling enabled on control plane for single-node tolerance

### Kubernetes Management

- **Local Path Provisioner**: Simple hostPath-based storage provisioner
  - Default StorageClass with 777 permissions for compatibility
  - Uses `/var/local-path-provisioner` on nodes
- **Ingress NGINX**: Kubernetes ingress controller
  - NodePort service for external access
  - JSON logging format for structured logs
  - TCP port 5140 forwarding for OPNsense

### Observability Stack

- **Prometheus**: Metrics collection and alerting engine
  - 15-day retention, 8GB retention size
  - Scrapes cluster metrics, node metrics, and application metrics
- **Grafana**: Visualization and dashboarding
  - Pre-configured with Prometheus and Loki data sources
  - Automatic dashboard discovery from ConfigMaps
  - 10GB persistent storage
- **Loki**: Log aggregation system
  - Single binary deployment mode for simplicity
  - MinIO backend for object storage (25GB)
  - 48-hour log retention
  - Pattern ingestion enabled for structured logs
- **Alloy**: All-in-one observability agent
  - Replaces Promtail with modern River configuration
  - Kubernetes log collection from all pods
  - OPNsense syslog reception on TCP port 5140
  - Forwards logs to Loki instance
- **Alertmanager**: Alert routing and management
  - Integrated with Prometheus for alert handling
  - 2GB persistent storage

### Security Features

- **Pod Security Contexts**: Applied to all deployments
  - Non-root containers (runAsNonRoot: true)
  - Dropped capabilities (ALL capabilities removed)
  - No privilege escalation
  - Seccomp profiles (RuntimeDefault)
- **Init Containers**: For permission management
  - Runs as root only to fix ownership/permissions
  - Minimal capabilities (CHOWN, FOWNER only)
- **Resource Limits**: Defined for all components
  - CPU and memory limits to prevent resource exhaustion
  - Appropriate for homelab environment

## Maintenance and Operations

### Updating Configurations

1. **Infrastructure changes**: Modify Terraform files and run `terraform apply`
2. **Application configuration**: Edit values in `kubernetes/values/` directories
3. **Apply changes**: Run `helmfile apply` to update applications

### Scaling Operations

- **Add worker nodes**: Modify `kubernetes.tf` to add more worker VMs
- **Increase resources**: Adjust CPU/memory in VM configurations
- **Storage expansion**: Modify disk sizes in Terraform configuration

### Backup and Recovery

- **Talos configuration**: Backup `~/.talos/config` and `~/.kube/config`
- **Persistent data**: Backup `/var/local-path-provisioner` on nodes
- **Terraform state**: Stored in Terraform Cloud (remote backend)

### Monitoring and Alerting

- **Grafana dashboards**: Auto-discovered from ConfigMaps with label `grafana_dashboard=1`
- **Prometheus rules**: Comprehensive alerting rules for cluster health
- **Log analysis**: Use Loki for centralized log analysis and troubleshooting

### Troubleshooting

- **Cluster status**: `kubectl get nodes -o wide`
- **Talos health**: `talosctl health --nodes <node-ip>`
- **Pod logs**: `kubectl logs -n <namespace> <pod-name>`
- **Storage issues**: Check `/var/local-path-provisioner` on nodes
- **Ingress issues**: Verify NodePort 30080/30443 accessibility

### Upgrades

- **Talos OS**: Follow [official upgrade guide](https://www.talos.dev/v1.9/talos-guides/upgrading-talos/)
- **Kubernetes**: Managed automatically by Talos
- **Applications**: Update chart versions in `helmfile.yaml`

## Network Configuration

### Port Mappings

- **30080**: HTTP ingress (external access)
- **30443**: HTTPS ingress (external access)
- **30514**: OPNsense syslog (external to internal port 5140)

### Internal Service Discovery

- **Prometheus**: `kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`
- **Loki**: `loki.monitoring.svc.cluster.local:3100`
- **Alloy**: `alloy.monitoring.svc.cluster.local:12345`

## Advanced Configuration

### OPNsense Integration

Configure OPNsense to send syslog to `<node-ip>:30514`:

1. System → Advanced → Logging
2. Add remote syslog server: `<node-ip>:30514`
3. Logs will be forwarded to Loki via Alloy

### Custom Dashboards

Add custom Grafana dashboards:

1. Create ConfigMap with label `grafana_dashboard: "1"`
2. Place in `monitoring` namespace
3. Dashboard will be auto-discovered

### Storage Classes

- **Default**: `local-path` (hostPath-based)
- **Path**: `/var/local-path-provisioner`
- **Permissions**: 777 (world-writable for compatibility)

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test in your environment
5. Submit a pull request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
