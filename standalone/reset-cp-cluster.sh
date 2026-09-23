#!/bin/bash

MODE="$1"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || exit 1
source scripts/activate-rocky-env.sh || exit 1

if [ "$MODE" == "single" ]; then
  ansible-playbook -i localhost, -c local -e mode=single playbooks/local.yml
  RET=$?
  if [ "$RET" -ne 0 ]; then
    exit 1
  else
    ansible-playbook -i inventory/mycluster/inventory.ini -e reset_confirmation=yes --become --become-user=root reset.yml
    RET=$?
    if [ "$RET" -ne 0 ]; then
      exit 1
    fi
  fi
elif [ "$MODE" == "multi" ]; then
  CLUSTER_CNT="$2"
  for i in $(seq 1 $CLUSTER_CNT); do
    ansible-playbook -i localhost, -c local -e mode=multi -e cluster_no=$i --become --become-user=root playbooks/local.yml
    RET=$?
    if [ "$RET" -ne 0 ]; then
      exit 1
    else
      ansible-playbook -i inventory/mycluster/inventory.ini -e reset_confirmation=yes --become --become-user=root reset.yml
      RET=$?
      if [ "$RET" -ne 0 ]; then
        exit 1
      fi
    fi
  done
elif [ "$MODE" == "federation" ]; then
  ansible-playbook -i localhost, -c local -e mode=single playbooks/local.yml
  RET=$?
  if [ "$RET" -ne 0 ]; then
    exit 1
  else
    ansible-playbook -i inventory/mycluster/inventory.ini -e reset_confirmation=yes --become --become-user=root reset.yml
    RET=$?
    if [ "$RET" -ne 0 ]; then
      exit 1
    fi
  fi
  CLUSTER_CNT="$2"
  for i in $(seq 1 $CLUSTER_CNT); do
    ansible-playbook -i localhost, -c local -e mode=multi -e cluster_no=$i --become --become-user=root playbooks/local.yml
    RET=$?
    if [ "$RET" -ne 0 ]; then
      exit 1
    else
      ansible-playbook -i inventory/mycluster/inventory.ini -e reset_confirmation=yes --become --become-user=root reset.yml
      RET=$?
      if [ "$RET" -ne 0 ]; then
        exit 1
      fi
    fi
  done
fi
