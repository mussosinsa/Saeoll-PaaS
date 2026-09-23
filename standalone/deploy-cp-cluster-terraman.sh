#!/bin/bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || exit 1
source scripts/activate-rocky-env.sh || exit 1

# Registering container platform variable
source cp-cluster-terraman-vars.sh

# Container platform configuration settings
sed -i "s/metallb_enabled:.*/metallb_enabled: false/" inventory/mycluster/group_vars/k8s_cluster/addons.yml

# Deploy container platform
ansible-playbook -i inventory/mycluster/hosts-$CLUSTER_NAME.yaml -e master1_node_public_ip=$MASTER1_NODE_PUBLIC_IP --become --become-user=root playbooks/cluster_terraman.yml
