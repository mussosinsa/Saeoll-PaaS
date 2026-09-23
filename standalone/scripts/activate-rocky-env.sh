#!/bin/bash

# Shared runtime bootstrap for the standalone commands.
if [[ ! -r /etc/os-release ]]; then
  echo "ERROR: /etc/os-release is missing; Rocky Linux 9.7 is required." >&2
  return 1 2>/dev/null || exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "rocky" || "${VERSION_ID:-}" != "9.7" ]]; then
  echo "ERROR: Rocky Linux 9.7 is required (detected ${PRETTY_NAME:-unknown})." >&2
  return 1 2>/dev/null || exit 1
fi

KPAAS_VENV="${KPAAS_VENV:-$HOME/kpaas-venv}"
if [[ ! -r "$KPAAS_VENV/bin/activate" ]]; then
  echo "ERROR: Python environment not found at $KPAAS_VENV; run deploy-cp-cluster.sh first." >&2
  return 1 2>/dev/null || exit 1
fi

# shellcheck disable=SC1090
source "$KPAAS_VENV/bin/activate"
