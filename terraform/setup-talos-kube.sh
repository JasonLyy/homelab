#!/bin/bash
set -e
umask 077

KUBERNETES_API_HOST="${KUBERNETES_API_HOST:-10.0.10.200}"
KUBECTL_MINOR="${KUBECTL_MINOR:-1.32}"

echo "Installing required tools..."

# Install dependencies
if ! command -v curl &> /dev/null || ! command -v tar &> /dev/null; then
    sudo apt-get update
    sudo apt-get install -y curl tar
fi

# Install talosctl using official method
echo "Installing talosctl..."
curl -sL https://talos.dev/install | sudo sh

# Install kubectl from the cluster-compatible minor release line.
echo "Installing kubectl..."
KUBECTL_VERSION="$(curl -fsSL "https://dl.k8s.io/release/stable-${KUBECTL_MINOR}.txt")"
case "$(uname -m)" in
    x86_64) KUBECTL_ARCH=amd64 ;;
    aarch64|arm64) KUBECTL_ARCH=arm64 ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
kubectl_tmp="$(mktemp)"
trap 'rm -f "$kubectl_tmp"' EXIT
curl -fsSLo "$kubectl_tmp" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${KUBECTL_ARCH}/kubectl"
chmod +x "$kubectl_tmp"
sudo install -m 0755 "$kubectl_tmp" /usr/local/bin/kubectl

# Create config directories
mkdir -p ~/.talos ~/.kube

# Use Terraform's Talos credentials to retrieve a current kubeconfig.
echo "Fetching configurations from Terraform..."
terraform output -raw talosconfig > ~/.talos/config
talosctl --endpoints="$KUBERNETES_API_HOST" --nodes="$KUBERNETES_API_HOST" kubeconfig --merge=false --force "$HOME/.kube/config"
cluster="$(kubectl --kubeconfig="$HOME/.kube/config" config view --minify -o jsonpath='{.contexts[0].context.cluster}')"
kubectl --kubeconfig="$HOME/.kube/config" config set-cluster "$cluster" --server="https://${KUBERNETES_API_HOST}:6443"

# Set secure permissions
chmod 600 ~/.talos/config ~/.kube/config

echo -e "\nInstallation complete!"