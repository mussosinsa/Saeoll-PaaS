#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/rocky-linux.sh
source "$SCRIPT_DIR/../lib/rocky-linux.sh"
# shellcheck source=tool-versions.sh
source "$SCRIPT_DIR/tool-versions.sh"

require_rocky_linux_9_7

TOOLS_DIR=$(mktemp -d)
trap 'rm -rf "$TOOLS_DIR"' EXIT
cd "$TOOLS_DIR"

# Closed network: OFFLINE_FILES=<dir> (the files/ directory of the offline bundle, see docs/install-offline.md)
# holds kubectl, helm-v*-linux-amd64.tar.gz, step-cli_*_amd64.rpm and istio-*-linux-amd64.tar.gz;
# nothing is downloaded then.
OFFLINE_FILES=${OFFLINE_FILES:-}
fetch() { # url file
  if [[ -n "$OFFLINE_FILES" ]]; then
    [[ -f "$OFFLINE_FILES/$2" ]] || { echo "[ERROR] $2 not found in $OFFLINE_FILES (offline bundle)" >&2; exit 1; }
    cp "$OFFLINE_FILES/$2" "$2"
  else
    curl -fL -o "$2" "$1"
  fi
}

# Rocky Linux packages used by the portal and multi-cluster scripts.
REQUIRED_PACKAGES=(
  ca-certificates
  curl
  gettext
  gzip
  openssh-clients
  openssl
  podman
  tar
  util-linux
  wget
)
MISSING_PACKAGES=()

for package in "${REQUIRED_PACKAGES[@]}"; do
  if rpm -q "$package" >/dev/null 2>&1; then
    echo "[SKIP] Package already installed: $package"
  else
    MISSING_PACKAGES+=("$package")
  fi
done

if ((${#MISSING_PACKAGES[@]})); then
  sudo dnf install -y "${MISSING_PACKAGES[@]}"
  sudo update-ca-trust
else
  echo "[SKIP] All required Rocky Linux packages are already installed."
fi

# Installing kubectl
if command -v kubectl >/dev/null 2>&1; then
  echo "[SKIP] kubectl is already installed: $(command -v kubectl)"
else
  fetch "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" kubectl
  chmod +x kubectl
  sudo mv kubectl /usr/local/bin/kubectl
fi
kubectl version --client

# Installing helm
if command -v helm >/dev/null 2>&1; then
  echo "[SKIP] helm is already installed: $(command -v helm)"
else
  fetch "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" "helm-v${HELM_VERSION}-linux-amd64.tar.gz"
  tar -zxvf "helm-v${HELM_VERSION}-linux-amd64.tar.gz"
  sudo mv linux-amd64/helm /usr/local/bin/helm
fi
helm version

podman version

# Installing step
if command -v step >/dev/null 2>&1; then
  echo "[SKIP] step is already installed: $(command -v step)"
else
  fetch "https://dl.smallstep.com/gh-release/cli/docs-cli-install/v${STEP_VERSION}/step-cli_${STEP_VERSION}_amd64.rpm" "step-cli_${STEP_VERSION}_amd64.rpm"
  sudo dnf install -y "./step-cli_${STEP_VERSION}_amd64.rpm"
fi
step version

# Installing istioctl
if command -v istioctl >/dev/null 2>&1; then
  echo "[SKIP] istioctl is already installed: $(command -v istioctl)"
else
  fetch "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-linux-amd64.tar.gz" \
    "istio-${ISTIO_VERSION}-linux-amd64.tar.gz"
  tar -xzf "istio-${ISTIO_VERSION}-linux-amd64.tar.gz"
  sudo mv "istio-${ISTIO_VERSION}/bin/istioctl" /usr/local/bin/istioctl
fi
istioctl version --remote=false
