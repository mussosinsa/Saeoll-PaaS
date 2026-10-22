#!/bin/bash
# Deploy the K-PaaS container platform source control (SCM-Server, API, UI)
# on a cluster where CP-Portal is already deployed.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || exit 1
UPSTREAM_DIR="$SCRIPT_DIR/../upstream"
SC_VARS="$UPSTREAM_DIR/script/cp-source-control-vars.sh"
PORTAL_VARS=${PORTAL_VARS:-"$SCRIPT_DIR/../../cp-portal-deployment/script/cp-portal-vars.sh"}
CP_PORTAL_NAMESPACE="cp-portal"

# Set NAME="value" in the upstream vars file, only if the variable exists there.
set_var() {
  local name=$1 value=$2 escaped
  grep -q "^${name}=" "$SC_VARS" || return 0
  escaped=$(printf '%s' "$value" | sed -e 's/[\\|&]/\\&/g')
  sed -i "s|^${name}=\"[^\"]*\"|${name}=\"${escaped}\"|" "$SC_VARS"
}

# Reuse the values CP-Portal was deployed with so source control talks to the
# same Keycloak client, MariaDB and Harbor credentials.
load_portal_vars() {
  [[ -r "$PORTAL_VARS" ]] || {
    echo "[ERROR] $PORTAL_VARS not found. Set PORTAL_VARS or edit $SC_VARS directly." >&2
    return 1
  }
  echo "[INFO] Loading CP-Portal settings from $PORTAL_VARS"
  eval "$(
    source "$PORTAL_VARS" >/dev/null 2>&1
    printf 'P_HOST_DOMAIN=%q\n' "$HOST_DOMAIN"
    printf 'P_K8S_STORAGECLASS=%q\n' "$K8S_STORAGECLASS"
    printf 'P_KEYCLOAK_ADMIN_ID=%q\n' "$KEYCLOAK_ADMIN_USERNAME"
    printf 'P_KEYCLOAK_ADMIN_PASSWORD=%q\n' "$KEYCLOAK_ADMIN_PASSWORD"
    printf 'P_KEYCLOAK_CP_REALM=%q\n' "$KEYCLOAK_CP_REALM"
    printf 'P_KEYCLOAK_CP_CLIENT_ID=%q\n' "$KEYCLOAK_CP_CLIENT_ID"
    printf 'P_KEYCLOAK_CP_CLIENT_SECRET=%q\n' "$KEYCLOAK_CP_CLIENT_SECRET"
    printf 'P_DATABASE_URL=%q\n' "$DATABASE_URL"
    printf 'P_DATABASE_USER_ID=%q\n' "$DATABASE_USER_ID"
    printf 'P_DATABASE_USER_PASSWORD=%q\n' "$DATABASE_USER_PASSWORD"
    printf 'P_REPOSITORY_USERNAME=%q\n' "$REPOSITORY_USERNAME"
    printf 'P_REPOSITORY_PASSWORD=%q\n' "$REPOSITORY_PASSWORD"
  )"
  [[ -n "$P_HOST_DOMAIN" && "$P_HOST_DOMAIN" != *'{'* ]] || {
    echo "[ERROR] HOST_DOMAIN is not configured in $PORTAL_VARS." >&2
    return 1
  }
}

apply_vars() {
  set_var HOST_DOMAIN "$P_HOST_DOMAIN"
  set_var K8S_STORAGECLASS "$P_K8S_STORAGECLASS"
  [[ -n "${IS_MULTI_CLUSTER:-}" ]] && set_var IS_MULTI_CLUSTER "$IS_MULTI_CLUSTER"
  set_var KEYCLOAK_ADMIN_ID "$P_KEYCLOAK_ADMIN_ID"
  set_var KEYCLOAK_ADMIN_USERNAME "$P_KEYCLOAK_ADMIN_ID"
  set_var KEYCLOAK_ADMIN_PASSWORD "$P_KEYCLOAK_ADMIN_PASSWORD"
  set_var KEYCLOAK_CP_REALM "$P_KEYCLOAK_CP_REALM"
  set_var KEYCLOAK_CP_CLIENT_ID "$P_KEYCLOAK_CP_CLIENT_ID"
  set_var KEYCLOAK_CP_CLIENT_SECRET "$P_KEYCLOAK_CP_CLIENT_SECRET"
  set_var DATABASE_URL "$P_DATABASE_URL"
  set_var DATABASE_USER_ID "$P_DATABASE_USER_ID"
  set_var DATABASE_USER_PASSWORD "$P_DATABASE_USER_PASSWORD"
  set_var REPOSITORY_USERNAME "$P_REPOSITORY_USERNAME"
  set_var REPOSITORY_PASSWORD "$P_REPOSITORY_PASSWORD"
  echo "[INFO] $SC_VARS"
  grep -E '^(HOST_DOMAIN|K8S_STORAGECLASS|IS_MULTI_CLUSTER)=' "$SC_VARS"
}

preflight() {
  local failed=0 tls_secret="${P_HOST_DOMAIN}-tls"
  for cmd in kubectl helm; do
    command -v "$cmd" >/dev/null || { echo "[ERROR] $cmd is not installed." >&2; failed=1; }
  done
  kubectl get storageclass "$P_K8S_STORAGECLASS" >/dev/null 2>&1 || {
    echo "[ERROR] StorageClass not found: $P_K8S_STORAGECLASS" >&2; failed=1; }
  kubectl -n "$CP_PORTAL_NAMESPACE" get secret "$tls_secret" >/dev/null 2>&1 || {
    echo "[ERROR] TLS secret $tls_secret not found in $CP_PORTAL_NAMESPACE. Deploy CP-Portal first." >&2; failed=1; }
  kubectl -n mariadb get pods --no-headers 2>/dev/null | grep -q Running || {
    echo "[ERROR] MariaDB (namespace mariadb) is not running. Deploy CP-Portal first." >&2; failed=1; }
  kubectl -n keycloak get pods --no-headers 2>/dev/null | grep -q Running || {
    echo "[ERROR] Keycloak (namespace keycloak) is not running. Deploy CP-Portal first." >&2; failed=1; }
  ((failed == 0))
}

### EXECUTION ########################################
if [[ ! -f "$UPSTREAM_DIR/script/deploy-cp-source-control.sh" ]]; then
  ./fetch-cp-source-control.sh "${SC_TARBALL:-}" || exit 1
fi
[[ -r "$SC_VARS" ]] || { echo "[ERROR] $SC_VARS not found." >&2; exit 1; }

load_portal_vars || exit 1
apply_vars
preflight || exit 1

# Refresh generated values on re-run ("cp -r" into an existing directory
# would nest values_orig inside it)
rm -rf "$UPSTREAM_DIR/values"

cd "$UPSTREAM_DIR/script" || exit 1
./deploy-cp-source-control.sh || exit 1

NAMESPACE=$(source ./cp-source-control-vars.sh >/dev/null 2>&1; echo "${NAMESPACE:-cp-source-control}")
echo ""
echo "[INFO] Waiting for source control pods to become Ready (up to 10 minutes)..."
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod --all --timeout=600s || \
  echo "[WARN] Some pods are not Ready yet. Check: kubectl -n $NAMESPACE get pods" >&2
echo "[INFO] Source control URL: https://scm.${P_HOST_DOMAIN}"
kubectl get all -n "$NAMESPACE"
