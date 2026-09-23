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

# Rocky Linux packages used by the portal and multi-cluster scripts.
sudo dnf install -y ca-certificates curl gettext gzip openssh-clients openssl \
  podman tar util-linux wget
sudo update-ca-trust

# Installing kubectl
curl -LO "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/kubectl
kubectl version --client

# Installing helm
curl -LO "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz"
tar -zxvf helm-v${HELM_VERSION}-linux-amd64.tar.gz
sudo mv linux-amd64/helm /usr/local/bin/helm
helm version

podman version

# Installing step
wget "https://dl.smallstep.com/gh-release/cli/docs-cli-install/v${STEP_VERSION}/step-cli_${STEP_VERSION}_amd64.rpm"
sudo dnf install -y "./step-cli_${STEP_VERSION}_amd64.rpm"

# Installing istioctl
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=$ISTIO_VERSION sh -
sudo mv istio-$ISTIO_VERSION/bin/istioctl /usr/local/bin/istioctl
