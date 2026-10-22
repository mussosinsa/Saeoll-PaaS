#!/bin/bash
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
UPSTREAM_SCRIPT="$SCRIPT_DIR/../upstream/script"

[[ -f "$UPSTREAM_SCRIPT/uninstall-cp-source-control.sh" ]] || {
  echo "[ERROR] $UPSTREAM_SCRIPT/uninstall-cp-source-control.sh not found. Run fetch-cp-source-control.sh first." >&2
  exit 1
}
cd "$UPSTREAM_SCRIPT" || exit 1
./uninstall-cp-source-control.sh
