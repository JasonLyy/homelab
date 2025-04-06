#!/bin/bash
set -e

echo "Installing required tools..."

# Install dependencies
if ! command -v curl &> /dev/null || ! command -v tar &> /dev/null; then
    sudo apt-get update
    sudo apt-get install -y curl tar
fi

# Install talosctl using official method
echo "Installing talosctl..."
curl -sL https://talos.dev/install | sudo sh

# Install kubectl
echo "Installing kubectl..."
KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

# Create config directories
mkdir -p ~/.talos ~/.kube

# Get configurations from Terraform
echo "Fetching configurations from Terraform..."
terraform output -raw talosconfig > ~/.talos/config
terraform output -raw kubeconfig > ~/.kube/config

# Set secure permissions
chmod 600 ~/.talos/config ~/.kube/config

echo -e "\nInstallation complete!"