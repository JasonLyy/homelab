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

### Ancillary / External Management

- **Portainer** (external VM/host): Used to deploy and manage a standalone Docker stack (e.g. Home Assistant) via GitOps-style synchronization with this repository.

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
    "exitNode": ["tag:k8s"],
    "routes": {
      "10.0.0.0/24": ["tag:k8s"],
      "10.0.10.0/24": ["tag:k8s"]
    }
  }
}
```

This allows the operator (tagged `tag:k8s-operator`) to create the exit node instance (tagged `tag:k8s`) and auto-approve exit node and subnet route advertising.

#### 3. Create the OAuth Secret

Replace the placeholders with your client credentials:

```sh
kubectl -n tailscale create secret generic operator-oauth \
  --from-literal=client_id="<CLIENT_ID>" \
  --from-literal=client_secret="<CLIENT_SECRET>"
```

Note: The operator (chart v1.94.2) expects the secret name `operator-oauth` with keys `client_id` and `client_secret`.

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

### Deploying Home Assistant via Portainer (Git-based Stack)

This repository contains a standalone Docker Compose file at `docker/docker-compose.yaml` for running Home Assistant outside the Kubernetes cluster (recommended for easier host network / USB / multicast support). You can deploy it in Portainer without SSH access by pointing a Git-based stack at this repo.

#### 1. Prerequisites

- A running Portainer instance (CE or BE) with access to the Docker endpoint (local or remote agent).
- This repository accessible via HTTPS (public) or with credentials / deploy key if private.

#### 2. (If Private) Configure Git Credentials in Portainer

1. In Portainer UI: Settings → Git credentials (or during stack creation if prompted).
2. Provide either:
   - Username + Personal Access Token (GitHub: repo scope at minimum), or
   - Deploy key (read-only) added to the repository.

#### 3. Create the Git-based Stack

1. Navigate: Stacks → Add stack → Repository tab.
2. Stack name: `homeassistant`.
3. Repository URL: `https://github.com/<your-user>/homelab.git` (adjust for your fork/owner).
4. Repository reference: `main` (or a tag / commit SHA to pin a version).
5. Compose path: `docker/docker-compose.yaml` (no leading slash, relative to repo root).
6. (Optional) Enable automatic updates:
   - Poll: choose an interval (e.g. 5m/15m) – Portainer periodically pulls and redeploys on change.
   - Webhook: after first deploy, Portainer provides a webhook URL; add it as a GitHub repository webhook (event: `push`).
7. Click Retrieve (if your Portainer version exposes a button) to validate the file, then Deploy the stack.

#### 4. First Startup & Access

- Home Assistant will bind directly on the Docker host’s IP at `http://<host-ip>:8123` because `network_mode: host` is configured.
- Initial container pull + setup may take several minutes; monitor logs in Portainer (Container → Logs).

#### 5. Updating the Stack

- Make changes to `docker/docker-compose.yaml` (e.g., pin image version, add volumes) and push to the tracked branch.
- Auto-update (poll/webhook) will redeploy; otherwise manually open the stack → Update & redeploy.
- To force pulling the latest `:stable` tag, use the Portainer action “Recreate / Pull latest image”.

#### 6. Data Persistence & Backups

- Persistent data is stored in the stack working directory bind mount (`./config` inside the stack’s Git working copy path that Portainer maintains). For portability you may alternatively convert to a named volume (see below).
- To switch to a named volume (optional):
  1. Edit compose file `volumes` section under the service to: `homeassistant_config:/config`.
  2. Append at file end: `volumes:\n  homeassistant_config:`.
  3. Commit & push; stack redeploys preserving existing data if you manually migrate contents (copy old bind mount data into the new volume beforehand if needed).

#### 7. Environment Variable Overrides

- Portainer allows specifying environment variables in the UI; these override those in the compose file at deploy time.
- For timezone changes, you can either edit the compose file or add `TZ=Australia/Melbourne` in the UI for quick overrides.

#### 8. Rollbacks / Pinning

- To pin a known-good state, change Repository reference to a specific commit SHA (immutable) in the stack edit view.
- To roll back: select a prior commit, or revert in Git and push.

#### 9. Converting From Manual (Web Editor) Stack

If you initially deployed by pasting YAML:

1. Duplicate the stack (optional backup).
2. Remove or stop the original stack (leave volumes intact).
3. Recreate via Git method pointing to this repo so future changes are Git-driven.

#### 10. Optional Additions

- Watchtower sidecar (auto image update) – generally not needed if you rely on redeploy cadence; evaluate risk of breaking changes in Home Assistant.
- Backup sidecar that tars `/config` and uploads to S3/Backblaze – outside scope here; can be added later.

### Deploying Portainer Agent for Kubernetes Management

Portainer can also attach to the Kubernetes cluster defined in this repository. This requires deploying the Portainer **Agent** (or full Portainer) inside the cluster, then connecting it from your existing Portainer UI (if you run a central Portainer instance) or accessing the in-cluster Portainer service.

#### 1. Decide Topology

Option A (Central Portainer managing both Docker host & K8s):

- Keep existing external Portainer instance.
- Deploy only the Portainer **Agent** into Kubernetes.
- Add environment (endpoint) in the central Portainer UI (Agent option).

Option B (Dedicated Portainer inside cluster):

- Deploy full Portainer (Server + optional Agent) via Helm or manifest.
- Access via NodePort / Ingress.

For a lightweight approach, Option A is recommended.

#### 2. Install Portainer Agent (Kubernetes)

Apply the official manifest (adjust namespace if desired):

```sh
kubectl apply -f https://downloads.portainer.io/ce2-33/portainer-agent-k8s-lb.yaml
```

This creates:

- Namespace `portainer`
- ServiceAccount / RBAC
- Deployment `portainer-agent`
- LoadBalancer (or NodePort depending on manifest variant) service exposing the agent (default 9001)

If you do not have a LoadBalancer implementation, you can edit the Service to `NodePort`:

```sh
kubectl -n portainer patch svc portainer-agent --type='json' \
  -p='[{"op":"replace","path":"/spec/type","value":"NodePort"}]'
```

Retrieve the node port:

```sh
kubectl -n portainer get svc portainer-agent -o wide
```

#### 3. Add Kubernetes Environment in Portainer UI

1. In Portainer: Environments → Add environment.
2. Choose: Agent.
3. Endpoint URL: `tcp://<node-ip>:<nodePort or LB IP>:9001` (omit protocol if UI asks only for host/port; some versions just require the IP:port pair).
4. Name it: `homelab-k8s`.
5. (Optional) Assign groups / tags for organization.
6. Save – Portainer will query the agent and list namespaces, etc.

#### 4. (Alternative) Deploy Full Portainer in Cluster

If you prefer running Portainer entirely inside Kubernetes (and optionally decommissioning the external instance):

```sh
kubectl apply -f https://downloads.portainer.io/ce2-33/portainer-lb.yaml
```

Then access the LoadBalancer / NodePort at port 9000 (UI) and 9443 (if TLS enabled). Initialize admin credentials, then add your external Docker host via **Agent** or **Docker** endpoint as needed.

#### 5. Security Considerations

- Limit network exposure: prefer private network / VPN (e.g. Tailscale) for Agent port (9001).
- Use Portainer roles to restrict access to namespaces if on Business Edition (RBAC granularity). Community Edition is broader in scope.
- Keep Portainer updated; watch release notes for CVEs.

#### 6. Uninstalling the Agent

```sh
kubectl delete ns portainer
```

This removes the agent resources (ensure no other workloads reside in the `portainer` namespace before deleting).

#### 7. Troubleshooting Agent Connectivity

| Symptom                         | Likely Cause                               | Resolution                                               |
| ------------------------------- | ------------------------------------------ | -------------------------------------------------------- |
| Timeout when adding environment | Service type unsupported or no NodePort/LB | Patch to NodePort or expose via Ingress/Tailscale proxy  |
| 403 / RBAC errors               | Missing ClusterRole binding                | Re-apply official manifest; verify ServiceAccount        |
| Namespaces not listing          | Agent not fully ready                      | Check `kubectl logs -n portainer deploy/portainer-agent` |

### Summary of External Management Flow

| Component        | Location                  | Deployment Method             | Purpose                           |
| ---------------- | ------------------------- | ----------------------------- | --------------------------------- |
| Home Assistant   | Docker host (outside K8s) | Git-based Portainer stack     | Home automation, host networking  |
| Portainer Agent  | Kubernetes cluster        | Official manifest             | Remote management endpoint        |
| Portainer Server | External VM (existing)    | Manual install (pre-existing) | Central UI (manages Docker + K8s) |

With this approach you achieve separation of concerns: Kubernetes workloads managed declaratively via Helmfile; specialized host-centric workload (Home Assistant) managed via Git + Portainer; unified visibility in Portainer across both environments.

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
