#!/bin/bash
source istio-vars-mc.sh

mkdir -p tools
cd tools

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

# Installing podman
sudo apt-get update
sudo apt-get -y install podman
podman version

# Installing ca-certificates
sudo apt-get update
sudo apt-get install -y ca-certificates

# Installing step
wget https://dl.smallstep.com/gh-release/cli/docs-cli-install/v${STEP_VERSION}/step-cli_${STEP_VERSION}_amd64.deb
sudo dpkg -i step-cli_${STEP_VERSION}_amd64.deb

# Installing istioctl
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=$ISTIO_VERSION sh -
sudo mv istio-$ISTIO_VERSION/bin/istioctl /usr/local/bin/istioctl

cd ..
rm -r tools