#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLUSTER_ENV=${1:-}
VARS_FILE=${CP_PORTAL_VARS_FILE:-"$SCRIPT_DIR/cp-portal-vars.sh"}

usage() {
  cat <<EOF
Usage: $(basename "$0") /path/to/cluster.env [host-domain]

host-domain (or env CP_HOST_DOMAIN): the DNS domain of the platform, e.g. kpaas.example.co.kr
  (portal.<domain>, harbor.<domain>, ...). A wildcard record *.<domain> must point to the Ingress IP.
  Without it the domain is <first METALLB_POOL address>.nip.io: the internal IP shows in every address and
  name lookups go to the public nip.io service - for tests only.
The Ingress IP (INGRESS_LB_IP) is the first address of METALLB_POOL; override with env INGRESS_LB_IP.
Set CP_PORTAL_IAAS_TYPE (1-5) to override the chart's IaaS type (default: 1).
Set CP_PORTAL_VARS_FILE to update a copy instead of cp-portal-vars.sh.
EOF
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

is_ipv4() {
  python3 -c 'import ipaddress, sys; ipaddress.IPv4Address(sys.argv[1])' "$1" \
    >/dev/null 2>&1
}

[[ -n "$CLUSTER_ENV" ]] || { usage >&2; exit 2; }
[[ -r "$CLUSTER_ENV" ]] || die "Cannot read cluster environment: $CLUSTER_ENV"
[[ -f "$VARS_FILE" ]] || die "CP-Portal variables file not found: $VARS_FILE"

# cluster.env is an administrator-owned shell configuration file. Source it in a
# subshell and emit only the values this script consumes.
mapfile -d '' -t cluster_values < <(
  bash -c '
    set -a
    # shellcheck disable=SC1090
    source "$1"
    printf "%s\0" \
      "${CONTROL_PLANE_VIP:-}" \
      "${HAPROXY_PORT:-}" \
      "${DEFAULT_STORAGE_CLASS:-}" \
      "${METALLB_POOL:-}" \
      "${ENABLE_METALLB:-}" \
      "${ENABLE_NFS:-}" \
      "${NFS_STORAGE_CLASS:-}"
  ' _ "$CLUSTER_ENV"
)

CONTROL_PLANE_VIP=${cluster_values[0]:-}
HAPROXY_PORT=${cluster_values[1]:-}
DEFAULT_STORAGE_CLASS=${cluster_values[2]:-}
METALLB_POOL=${cluster_values[3]:-}
ENABLE_METALLB=${cluster_values[4]:-}
ENABLE_NFS=${cluster_values[5]:-}
NFS_STORAGE_CLASS=${cluster_values[6]:-}

is_ipv4 "$CONTROL_PLANE_VIP" || \
  die "CONTROL_PLANE_VIP must be an IPv4 address: $CONTROL_PLANE_VIP"
[[ "$HAPROXY_PORT" =~ ^[0-9]+$ ]] && ((HAPROXY_PORT >= 1 && HAPROXY_PORT <= 65535)) || \
  die "HAPROXY_PORT must be between 1 and 65535: $HAPROXY_PORT"
[[ -n "$DEFAULT_STORAGE_CLASS" && "$DEFAULT_STORAGE_CLASS" != "none" ]] || \
  die "DEFAULT_STORAGE_CLASS must name a provisioned StorageClass"
[[ "$DEFAULT_STORAGE_CLASS" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || \
  die "DEFAULT_STORAGE_CLASS is not a valid Kubernetes name: $DEFAULT_STORAGE_CLASS"

if [[ "$DEFAULT_STORAGE_CLASS" == "$NFS_STORAGE_CLASS" && "$ENABLE_NFS" != "true" ]]; then
  die "DEFAULT_STORAGE_CLASS is NFS, but ENABLE_NFS is not true"
fi

HOST_DOMAIN=${2:-${CP_HOST_DOMAIN:-}}
INGRESS_LB_IP=${INGRESS_LB_IP:-}
if [[ -z "$INGRESS_LB_IP" && "$ENABLE_METALLB" == "true" ]]; then
  INGRESS_LB_IP=${METALLB_POOL%%-*}
  INGRESS_LB_IP=${INGRESS_LB_IP%%/*}
fi
if [[ -n "$INGRESS_LB_IP" ]]; then
  is_ipv4 "$INGRESS_LB_IP" || die "Cannot derive an ingress IP from METALLB_POOL: $METALLB_POOL (set INGRESS_LB_IP)"
fi
if [[ -z "$HOST_DOMAIN" ]]; then
  [[ -n "$INGRESS_LB_IP" ]] || \
    die "ENABLE_METALLB is not true; pass a host domain as the second argument and set INGRESS_LB_IP"
  HOST_DOMAIN="${INGRESS_LB_IP}.nip.io"
  echo "[WARN] No host domain given: using $HOST_DOMAIN (the internal IP is visible in every address)." >&2
  echo "[WARN] For production pass a DNS domain: $(basename "$0") $CLUSTER_ENV kpaas.example.co.kr" >&2
fi
HOST_DOMAIN=${HOST_DOMAIN,,}
[[ "$HOST_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || \
  die "Host domain contains unsupported characters: $HOST_DOMAIN"

HOST_CLUSTER_IAAS_TYPE=${CP_PORTAL_IAAS_TYPE:-1}
[[ "$HOST_CLUSTER_IAAS_TYPE" =~ ^[1-5]$ ]] || \
  die "CP_PORTAL_IAAS_TYPE must be one of 1, 2, 3, 4, or 5"

K8S_CLUSTER_API_SERVER="https://${CONTROL_PLANE_VIP}:${HAPROXY_PORT}"
BACKUP_FILE="${VARS_FILE}.bak.$(date +%Y%m%d%H%M%S)"
cp -p "$VARS_FILE" "$BACKUP_FILE"

CONTROL_PLANE_VIP="$CONTROL_PLANE_VIP" \
K8S_CLUSTER_API_SERVER="$K8S_CLUSTER_API_SERVER" \
DEFAULT_STORAGE_CLASS="$DEFAULT_STORAGE_CLASS" \
HOST_CLUSTER_IAAS_TYPE="$HOST_CLUSTER_IAAS_TYPE" \
HOST_DOMAIN="$HOST_DOMAIN" \
INGRESS_LB_IP="$INGRESS_LB_IP" \
VARS_FILE="$VARS_FILE" \
python3 <<'PY'
import os
import re
from pathlib import Path

path = Path(os.environ["VARS_FILE"])
text = path.read_text(encoding="utf-8")
updates = {
    "K8S_MASTER_NODE_IP": os.environ["CONTROL_PLANE_VIP"],
    "K8S_CLUSTER_API_SERVER": os.environ["K8S_CLUSTER_API_SERVER"],
    "K8S_STORAGECLASS": os.environ["DEFAULT_STORAGE_CLASS"],
    "HOST_CLUSTER_IAAS_TYPE": os.environ["HOST_CLUSTER_IAAS_TYPE"],
    "HOST_DOMAIN": os.environ["HOST_DOMAIN"],
}
optional = {"INGRESS_LB_IP": os.environ["INGRESS_LB_IP"]}

for name, value in updates.items():
    pattern = rf"(?m)^{name}=.*$"
    replacement = f'{name}="{value}"'
    text, count = re.subn(pattern, replacement, text, count=1)
    if count != 1:
        raise SystemExit(f"[ERROR] Variable not found in {path}: {name}")
for name, value in optional.items():
    text, count = re.subn(rf"(?m)^{name}=.*$", f'{name}="{value}"', text, count=1)
    if count != 1:   # vars file from before INGRESS_LB_IP: add it after HOST_DOMAIN
        text = re.sub(r'(?m)^(HOST_DOMAIN=.*)$', lambda m: m.group(1) + f'\n{name}="{value}"', text, count=1)

path.write_text(text, encoding="utf-8")
PY

echo "[OK] Updated: $VARS_FILE"
echo "[OK] Backup:  $BACKUP_FILE"
echo "  K8S_MASTER_NODE_IP=$CONTROL_PLANE_VIP"
echo "  K8S_CLUSTER_API_SERVER=$K8S_CLUSTER_API_SERVER"
echo "  K8S_STORAGECLASS=$DEFAULT_STORAGE_CLASS"
echo "  HOST_CLUSTER_IAAS_TYPE=$HOST_CLUSTER_IAAS_TYPE"
echo "  HOST_DOMAIN=$HOST_DOMAIN"
echo "  INGRESS_LB_IP=${INGRESS_LB_IP:-<not set>}"
if [[ "$HOST_DOMAIN" != *.nip.io ]]; then
  echo "[INFO] DNS: *.$HOST_DOMAIN must resolve to ${INGRESS_LB_IP:-the Ingress IP} on the admin node, every Kubernetes node"
  echo "       and the users' PCs. deploy-cp-portal.sh checks it before installing."
fi

if command -v kubectl >/dev/null 2>&1; then
  current_server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
  if [[ -n "$current_server" && "$current_server" != "$K8S_CLUSTER_API_SERVER" ]]; then
    echo "[WARN] Current kubeconfig server is $current_server (cluster.env: $K8S_CLUSTER_API_SERVER)" >&2
  fi
  if ! kubectl get storageclass "$DEFAULT_STORAGE_CLASS" >/dev/null 2>&1; then
    echo "[WARN] StorageClass not found in the current cluster: $DEFAULT_STORAGE_CLASS" >&2
  fi
fi
