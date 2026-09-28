#!/bin/bash
# Install metrics-server on an existing cluster without re-running the whole
# CP-Portal deployment. Override the image with METRICS_SERVER_IMAGE if the
# nodes cannot pull from registry.k-paas.org, e.g.
#   METRICS_SERVER_IMAGE=registry.k8s.io/metrics-server/metrics-server:v0.8.0
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
eval "$(sed -n '/^metrics_api_available()/,/^# -----/p' "$SCRIPT_DIR/deploy-cp-portal.sh")"
ensure_metrics_server || exit 1
kubectl top nodes
