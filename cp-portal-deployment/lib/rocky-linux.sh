#!/usr/bin/env bash

# Common host helpers for CP-Portal deployment on Rocky Linux 9.7.
CP_PORTAL_CA_TRUST_DIR="/etc/pki/ca-trust/source/anchors"

require_rocky_linux_9_7() {
  if [[ ! -r /etc/os-release ]]; then
    echo "[ERROR] /etc/os-release is missing; Rocky Linux 9.7 is required." >&2
    return 1
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "${ID:-}" != "rocky" || "${VERSION_ID:-}" != "9.7" ]]; then
    echo "[ERROR] Rocky Linux 9.7 is required (detected ${PRETTY_NAME:-unknown})." >&2
    return 1
  fi
}

install_host_ca() {
  local certificate=$1
  local name=${2:-$(basename "$certificate")}

  sudo install -D -m 0644 "$certificate" "$CP_PORTAL_CA_TRUST_DIR/$name"
  sudo update-ca-trust extract
}

remove_host_ca() {
  local name=$1

  sudo rm -f "$CP_PORTAL_CA_TRUST_DIR/$name"
  sudo update-ca-trust extract
}
