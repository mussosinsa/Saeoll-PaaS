#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

# shellcheck source=cp-portal-vars.sh
source ./cp-portal-vars.sh
# shellcheck source=../lib/rocky-linux.sh
source ../lib/rocky-linux.sh
require_rocky_linux_9_7

[[ "$HOST_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || {
  echo "[ERROR] HOST_DOMAIN is not configured: '$HOST_DOMAIN'" >&2
  echo "[ERROR] Run configure-from-cluster-env.sh or edit cp-portal-vars.sh first." >&2
  exit 1
}

CHART_FILE="../charts/${CHART_NAME[7]}-${CHART_VERSION[${CHART_NAME[7]}]}.tgz"
CA_FILE=../certs/ca.crt
DAEMONSET="${CHART_NAME[7]}-daemonset"
TMP_VALUES=$(mktemp)
trap 'rm -f "$TMP_VALUES"' EXIT

[[ -f "$CHART_FILE" ]] || { echo "[ERROR] Chart not found: $CHART_FILE" >&2; exit 1; }
[[ -s "$CA_FILE" ]] || { echo "[ERROR] CA certificate not found: $CA_FILE" >&2; exit 1; }

sed -e "s/{CP_CERT_SETUP_NAME}/${CHART_NAME[7]}/g" \
    -e "s/{CP_CERT_SETUP_NAMESPACE}/${CP_CERT_SETUP_NAMESPACE}/g" \
    -e "s/{HOST_DOMAIN}/${HOST_DOMAIN}/g" \
    ../values_orig/cp-cert-setup.yaml > "$TMP_VALUES"

helm upgrade --install "${CHART_NAME[7]}" "$CHART_FILE" \
  --namespace "$CP_CERT_SETUP_NAMESPACE" \
  --values "$TMP_VALUES" \
  --set-string data.target.cert="$(cat "$CA_FILE")"

if ! kubectl -n "$CP_CERT_SETUP_NAMESPACE" rollout status \
  "daemonset/$DAEMONSET" --timeout=5m; then
  kubectl -n "$CP_CERT_SETUP_NAMESPACE" get pods \
    -l "$CP_CERT_SETUP_SELECTOR" -o wide >&2 || true
  kubectl -n "$CP_CERT_SETUP_NAMESPACE" describe pods \
    -l "$CP_CERT_SETUP_SELECTOR" >&2 || true
  kubectl -n "$CP_CERT_SETUP_NAMESPACE" logs \
    -l "$CP_CERT_SETUP_SELECTOR" -c setup --prefix --tail=100 >&2 || true
  kubectl -n "$CP_CERT_SETUP_NAMESPACE" logs \
    -l "$CP_CERT_SETUP_SELECTOR" -c setup --previous --prefix --tail=100 >&2 || true
  exit 1
fi

install_host_ca "$CA_FILE" "${HOST_DOMAIN}-ca.crt"

for deployment in cp-portal-ui-deployment cp-portal-migration-ui-deployment; do
  if kubectl -n "${NAMESPACE[4]}" get "deployment/$deployment" >/dev/null 2>&1; then
    kubectl -n "${NAMESPACE[4]}" rollout restart "deployment/$deployment"
  fi
done

echo "[OK] The Harbor CA was installed on all Kubernetes nodes."
echo "[INFO] After image pulls succeed, remove the temporary release with:"
echo "  helm uninstall ${CHART_NAME[7]} -n $CP_CERT_SETUP_NAMESPACE"
