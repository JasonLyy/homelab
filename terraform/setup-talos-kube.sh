#!/usr/bin/env bash
set -euo pipefail

# Verify Terraform is installed
if ! command -v terraform &> /dev/null; then
  echo "Error: Terraform not found in PATH"
  exit 1
fi

# Create temporary directory for configs
CONFIG_DIR=$(mktemp -d)
trap 'rm -rf "$CONFIG_DIR"' EXIT

# Generate Talos config
echo "Extracting talosconfig from Terraform..."
terraform output -raw talosconfig > "${CONFIG_DIR}/talosconfig" || {
  echo "Error: Failed to get talosconfig from Terraform outputs"
  exit 1
}

# Generate Kubernetes config
echo "Extracting kubeconfig from Terraform..."
terraform output -raw kubeconfig > "${CONFIG_DIR}/kubeconfig" || {
  echo "Error: Failed to get kubeconfig from Terraform outputs"
  exit 1
}

# Install talosctl
echo "Installing talosctl..."
curl -sL https://talos.dev/install | sudo sh

# Install kubectl
echo "Installing kubectl..."
KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

# Configure Talos
# todo: this can sometimes error out. fix me.
echo "Configuring talosctl..."
mkdir -p "${HOME}/.talos"
mv -v "${CONFIG_DIR}/talosconfig" "${HOME}/.talos/config"
chmod 600 "${HOME}/.talos/config"
TALOS_CONTEXT=$(talosctl config context 2>/dev/null | awk '/current/ {print $2}')
[ -n "${TALOS_CONTEXT}" ] && talosctl config context "${TALOS_CONTEXT}"

# Configure Kubernetes
echo "Configuring kubectl..."
mkdir -p "${HOME}/.kube"
mv -v "${CONFIG_DIR}/kubeconfig" "${HOME}/.kube/config"
chmod 600 "${HOME}/.kube/config"
KUBE_CONTEXT=$(kubectl config get-contexts -o name | head -n1)
[ -n "${KUBE_CONTEXT}" ] && kubectl config use-context "${KUBE_CONTEXT}"

# Verification
echo -e "\nVerification:"
echo "Talos endpoints: $(talosctl config endpoint)"
echo "Kubernetes contexts:"
kubectl config get-contexts
echo -e "\nCluster access configured successfully!"