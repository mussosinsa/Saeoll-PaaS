#!/bin/bash

MODE="$1"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || exit 1

# Rocky Linux 9.7 controller prerequisites and isolated Ansible environment.
source /etc/os-release
if [[ "${ID:-}" != "rocky" || "${VERSION_ID:-}" != "9.7" ]]; then
  echo "ERROR: Rocky Linux 9.7 is required (detected ${PRETTY_NAME:-unknown})." >&2
  exit 1
fi

sudo dnf install -y python3 python3-pip net-tools jq
python3 -m venv "$HOME/kpaas-venv"
# shellcheck disable=SC1091
source "$HOME/kpaas-venv/bin/activate"
python -m pip install --upgrade pip
python -m pip install -r requirements.txt

if [ "$MODE" == "single" ]; then
  ansible-playbook -i localhost, -c local -e mode=single playbooks/local.yml
  RET=$?
  if [ "$RET" -ne 0 ]; then
    exit 1
  else
    ansible-playbook -i inventory/mycluster/inventory.ini -e mode=single --become --become-user=root playbooks/cluster.yml
    RET=$?
    if [ "$RET" -ne 0 ]; then
      exit 1
    else
      ansible-playbook -i inventory/mycluster/inventory.ini --become --become-user=root playbooks/single.yml
    fi
  fi
elif [ "$MODE" == "multi" ]; then
  CLUSTER_CNT="$2"
  for i in $(seq 1 $CLUSTER_CNT); do
    ansible-playbook -i localhost, -c local -e mode=multi -e cluster_no=$i playbooks/local.yml
    RET=$?
    if [ "$RET" -ne 0 ]; then
      exit 1
    else
      ansible-playbook -i inventory/mycluster/inventory.ini -e mode=multi -e cluster_no=$i --become --become-user=root playbooks/cluster.yml
      RET=$?
      if [ "$RET" -ne 0 ]; then
        exit 1
      fi
    fi
  done
  ansible-playbook -i inventory/mycluster/inventory.ini -e cluster_cnt=$CLUSTER_CNT --become --become-user=root playbooks/multi.yml
elif [ "$MODE" == "federation" ]; then
  ansible-playbook -i localhost, -c local -e mode=single playbooks/local.yml
  RET=$?
  if [ "$RET" -ne 0 ]; then
    exit 1
  else
    ansible-playbook -i inventory/mycluster/inventory.ini -e mode=single --become --become-user=root playbooks/cluster.yml
    RET=$?
    if [ "$RET" -ne 0 ]; then
      exit 1
    else
      ansible-playbook -i inventory/mycluster/inventory.ini --become --become-user=root playbooks/single.yml
      RET=$?
      if [ "$RET" -ne 0 ]; then
        exit 1
      fi
    fi
  fi
  CLUSTER_CNT="$2"
  for i in $(seq 1 $CLUSTER_CNT); do
    ansible-playbook -i localhost, -c local -e mode=multi -e cluster_no=$i playbooks/local.yml
    RET=$?
    if [ "$RET" -ne 0 ]; then
      exit 1
    else
      ansible-playbook -i inventory/mycluster/inventory.ini -e mode=multi -e cluster_no=$i --become --become-user=root playbooks/cluster.yml
      RET=$?
      if [ "$RET" -ne 0 ]; then
        exit 1
      fi
    fi
  done
  ansible-playbook -i inventory/mycluster/inventory.ini -e cluster_cnt=$CLUSTER_CNT --become --become-user=root playbooks/multi.yml
  RET=$?
  if [ "$RET" -ne 0 ]; then
    exit 1
  else
    ansible-playbook -i inventory/mycluster/inventory.ini -e cluster_cnt=$CLUSTER_CNT --become --become-user=root playbooks/federation.yml
  fi
fi
