# Common helpers for the CI/CD portal scripts. Source from cicd-portal-deployment/script.
# shellcheck shell=bash
LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=cicd-vars.sh
source "$LIB_DIR/cicd-vars.sh"
PORTAL_DIR=${PORTAL_DIR:-"$LIB_DIR/../../cp-portal-deployment"}
PORTAL_VARS=${PORTAL_VARS:-"$PORTAL_DIR/script/cp-portal-vars.sh"}
CA_FILE=${CA_FILE:-"$PORTAL_DIR/certs/ca.crt"}
API="python3 $LIB_DIR/cicd_api.py"

info() { echo "[INFO] $*"; }
ok() { echo "[OK]   $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

# Reuse the values CP-Portal was deployed with (domain, Keycloak admin, Harbor).
load_portal_vars() {
  [[ -r "$PORTAL_VARS" ]] || die "$PORTAL_VARS not found (set PORTAL_VARS)."
  local own_domain=$HOST_DOMAIN own_sc=$K8S_STORAGECLASS
  eval "$(
    source "$PORTAL_VARS" >/dev/null 2>&1
    printf 'P_HOST_DOMAIN=%q\n' "$HOST_DOMAIN"
    printf 'P_K8S_STORAGECLASS=%q\n' "$K8S_STORAGECLASS"
    printf 'P_KEYCLOAK_URL=%q\n' "$KEYCLOAK_URL"
    printf 'P_REPOSITORY_URL=%q\n' "$REPOSITORY_URL"
    printf 'KEYCLOAK_ADMIN_USERNAME=%q\n' "$KEYCLOAK_ADMIN_USERNAME"
    printf 'KEYCLOAK_ADMIN_PASSWORD=%q\n' "$KEYCLOAK_ADMIN_PASSWORD"
    printf 'KEYCLOAK_CP_REALM=%q\n' "$KEYCLOAK_CP_REALM"
    printf 'REPOSITORY_USERNAME=%q\n' "$REPOSITORY_USERNAME"
    printf 'REPOSITORY_PASSWORD=%q\n' "$REPOSITORY_PASSWORD"
  )"
  HOST_DOMAIN=$own_domain
  [[ -z "$HOST_DOMAIN" || "$HOST_DOMAIN" == *'{'* ]] && HOST_DOMAIN=$P_HOST_DOMAIN
  [[ -n "$HOST_DOMAIN" && "$HOST_DOMAIN" != *'{'* ]] || die "HOST_DOMAIN is not configured in $PORTAL_VARS."
  K8S_STORAGECLASS=${own_sc:-$P_K8S_STORAGECLASS}

  TLS_SECRET="${HOST_DOMAIN}-tls"
  GITLAB_HOST="gitlab.${HOST_DOMAIN}"
  # CICD_GITLAB_URL: API address used by these scripts if gitlab.<domain> does not resolve here
  GITLAB_URL=${CICD_GITLAB_URL:-"https://${GITLAB_HOST}"}
  GITLAB_INTERNAL_HOST="gitlab.${GITLAB_NAMESPACE}.svc.cluster.local"
  GITLAB_INTERNAL_URL="http://${GITLAB_INTERNAL_HOST}"
  ARGOCD_HOST="argocd.${HOST_DOMAIN}"
  KEYCLOAK_URL=${P_KEYCLOAK_URL:-"https://keycloak.${HOST_DOMAIN}"}
  KEYCLOAK_URL=${KEYCLOAK_URL//\{host domain\}/$HOST_DOMAIN}
  KEYCLOAK_ISSUER="${KEYCLOAK_URL}/realms/${KEYCLOAK_CP_REALM}"
  HARBOR_URL=${P_REPOSITORY_URL:-"https://harbor.${HOST_DOMAIN}"}
  HARBOR_URL=${HARBOR_URL//\{host domain\}/$HOST_DOMAIN}
  HARBOR_HOST=$(echo "$HARBOR_URL" | awk -F[/:] '{print $4}')

  # Environment for cicd_api.py
  export CA_FILE KEYCLOAK_URL KEYCLOAK_ADMIN_USERNAME KEYCLOAK_ADMIN_PASSWORD
  export KC_REALM=$KEYCLOAK_CP_REALM HARBOR_URL REPOSITORY_USERNAME REPOSITORY_PASSWORD GITLAB_URL
}

require_cmds() {
  local cmd
  for cmd in "$@"; do command -v "$cmd" >/dev/null || die "$cmd is not installed."; done
}

ensure_namespace() { # name [label=value ...]
  local ns=$1; shift
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  (($#)) && kubectl label namespace "$ns" --overwrite "$@" >/dev/null
  return 0
}

# Copy the wildcard *.HOST_DOMAIN TLS secret generated for CP-Portal.
copy_tls_secret() { # namespace
  kubectl -n "$CP_PORTAL_NAMESPACE" get secret "$TLS_SECRET" -o json | python3 -c '
import json, sys
s = json.load(sys.stdin)
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": s["type"],
                  "metadata": {"name": s["metadata"]["name"], "namespace": sys.argv[1]},
                  "data": s["data"]}))' "$1" | kubectl apply -f - >/dev/null
}

ensure_ca_secret() { # namespace
  kubectl -n "$1" create secret generic "$CA_SECRET_NAME" --from-file=ca.crt="$CA_FILE" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# Generated credentials live in one secret: get_secret key / set_secret key value
get_secret() {
  kubectl -n "$GITLAB_NAMESPACE" get secret "$SECRET_NAME" -o "jsonpath={.data.$1}" 2>/dev/null | base64 -d 2>/dev/null
}
set_secret() { # values go through stdin, not the command line
  if kubectl -n "$GITLAB_NAMESPACE" get secret "$SECRET_NAME" >/dev/null 2>&1; then
    printf '{"data":{"%s":"%s"}}' "$1" "$(printf '%s' "$2" | base64 -w0)" | \
      kubectl -n "$GITLAB_NAMESPACE" patch secret "$SECRET_NAME" --type merge --patch-file /dev/stdin >/dev/null
  else
    printf '%s' "$2" | kubectl -n "$GITLAB_NAMESPACE" create secret generic "$SECRET_NAME" \
      --from-file="$1=/dev/stdin" >/dev/null
  fi
}
random_string() { # length
  python3 -c 'import secrets,string,sys; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(int(sys.argv[1]))))' "$1"
}

# GitLab automation token (root personal access token created at bootstrap)
load_gitlab_token() {
  GITLAB_TOKEN=$(get_secret automation-token)
  [[ -n "$GITLAB_TOKEN" ]] || die "GitLab automation token not found. Run ./deploy-cicd-portal.sh first."
  export GITLAB_TOKEN
}

# Replace {KEY} placeholders: render_file src dst KEY=value ...
render_file() {
  local src=$1 dst=$2; shift 2
  python3 - "$src" "$dst" "$@" <<'PY'
import sys
src, dst, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]
text = open(src).read()
for p in pairs:
    k, v = p.split("=", 1)
    text = text.replace("{" + k + "}", v)
open(dst, "w").write(text)
PY
}
