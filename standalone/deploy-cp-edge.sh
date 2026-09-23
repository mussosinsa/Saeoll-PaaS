#!/bin/bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || exit 1
source scripts/activate-rocky-env.sh || exit 1

ansible-playbook -i localhost, -c local playbooks/local-edge.yml
RET=$?
if [ "$RET" -ne 0 ]; then
  exit 1
else
  ansible-playbook -i inventory/mycluster/edge-hosts.yaml --become --become-user=root playbooks/edge.yml
fi
