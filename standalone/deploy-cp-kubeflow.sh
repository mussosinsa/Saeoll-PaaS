#!/bin/bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || exit 1
source scripts/activate-rocky-env.sh || exit 1

ansible-playbook -i inventory/mycluster/inventory.ini --become --become-user=root playbooks/kubeflow.yml
