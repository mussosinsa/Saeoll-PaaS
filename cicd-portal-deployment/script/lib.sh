# Common helpers for the CI/CD portal scripts (sources: scm and/or gitlab). Source from cicd-portal-deployment/script.
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
    printf 'P_DATABASE_URL=%q\n' "${DATABASE_URL:-}"
    printf 'DATABASE_USER_PASSWORD=%q\n' "${DATABASE_USER_PASSWORD:-}"
  )"
  HOST_DOMAIN=$own_domain
  [[ -z "$HOST_DOMAIN" || "$HOST_DOMAIN" == *'{'* ]] && HOST_DOMAIN=$P_HOST_DOMAIN
  [[ -n "$HOST_DOMAIN" && "$HOST_DOMAIN" != *'{'* ]] || die "HOST_DOMAIN is not configured in $PORTAL_VARS."
  K8S_STORAGECLASS=${own_sc:-$P_K8S_STORAGECLASS}

  TLS_SECRET="${HOST_DOMAIN}-tls"
  GITLAB_HOST="gitlab.${HOST_DOMAIN}"
  # CICD_GITLAB_URL: API address used by these scripts if gitlab.<domain> does not resolve here
  GITLAB_URL=${CICD_GITLAB_URL:-"https://${GITLAB_HOST}"}
  GITLAB_GIT_URL=${CICD_GITLAB_GIT_URL:-$GITLAB_URL}   # git over HTTPS (same host; overridable for tests)
  GITLAB_INTERNAL_HOST="gitlab.${GITLAB_NAMESPACE}.svc.cluster.local"
  GITLAB_INTERNAL_URL="http://${GITLAB_INTERNAL_HOST}"
  ARGOCD_HOST="argocd.${HOST_DOMAIN}"
  CONSOLE_HOST="${CONSOLE_HOST_PREFIX:-cicd}.${HOST_DOMAIN}"
  KEYCLOAK_URL=${P_KEYCLOAK_URL:-"https://keycloak.${HOST_DOMAIN}"}
  KEYCLOAK_URL=${KEYCLOAK_URL//\{host domain\}/$HOST_DOMAIN}
  KEYCLOAK_ISSUER="${KEYCLOAK_URL}/realms/${KEYCLOAK_CP_REALM}"
  HARBOR_URL=${P_REPOSITORY_URL:-"https://harbor.${HOST_DOMAIN}"}
  HARBOR_URL=${HARBOR_URL//\{host domain\}/$HOST_DOMAIN}
  HARBOR_HOST=$(echo "$HARBOR_URL" | awk -F[/:] '{print $4}')

  JENKINS_HOST="jenkins.${HOST_DOMAIN}"
  JENKINS_URL=${CICD_JENKINS_URL:-"https://${JENKINS_HOST}"}
  # SCM-Manager 1.x of K-PaaS source control: REST/git from this host, git from pods
  SCM_URL=${CICD_SCM_URL:-"https://scm-manager.${HOST_DOMAIN}/scm"}
  SCM_GIT_URL=${CICD_SCM_GIT_URL:-"$SCM_URL/git"}
  SCM_INTERNAL_GIT_URL="$SCM_INTERNAL_URL/git"
  # K-PaaS MariaDB (add-db.sh shared mode)
  PLATFORM_DB_URL=${P_DATABASE_URL:-"mariadb.mariadb.svc.cluster.local:3306"}

  local src
  for src in $CICD_SOURCES; do
    [[ "$src" == scm || "$src" == gitlab ]] || die "CICD_SOURCES entries must be scm or gitlab (got '$src')."
  done
  [[ -n "${CICD_SOURCES// /}" ]] || die "CICD_SOURCES is empty."

  # Environment for cicd_api.py
  export CA_FILE KEYCLOAK_URL KEYCLOAK_ADMIN_USERNAME KEYCLOAK_ADMIN_PASSWORD
  export KC_REALM=$KEYCLOAK_CP_REALM HARBOR_URL REPOSITORY_USERNAME REPOSITORY_PASSWORD GITLAB_URL
  export JENKINS_URL SCM_URL SCM_ADMIN_USER
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

has_source() { [[ " $CICD_SOURCES " == *" $1 "* ]]; }

# Generated credentials: secret $SECRET_NAME in the namespace of the component that uses
# them (pods read gitlab-*/jenkins-* keys from their own namespace).
secret_namespace() { # key
  case "$1" in
    gitlab-*|root-password|automation-token) echo "$GITLAB_NAMESPACE" ;;
    jenkins-*|kc-jenkins-*) echo "$JENKINS_NAMESPACE" ;;
    *) echo "$ARGOCD_NAMESPACE" ;;
  esac
}
# get_secret key - also reads the namespaces used by earlier versions (single-source installs)
get_secret() {
  local ns value
  for ns in "$(secret_namespace "$1")" "$JENKINS_NAMESPACE" "$GITLAB_NAMESPACE"; do
    value=$(kubectl -n "$ns" get secret "$SECRET_NAME" -o "jsonpath={.data.$1}" 2>/dev/null | base64 -d 2>/dev/null)
    [[ -n "$value" ]] && { printf '%s' "$value"; return 0; }
  done
  return 0
}
set_secret() { # key value - values go through stdin, not the command line
  local ns
  ns=$(secret_namespace "$1")
  ensure_namespace "$ns" app.kubernetes.io/part-of=cicd-portal
  if kubectl -n "$ns" get secret "$SECRET_NAME" >/dev/null 2>&1; then
    printf '{"data":{"%s":"%s"}}' "$1" "$(printf '%s' "$2" | base64 -w0)" | \
      kubectl -n "$ns" patch secret "$SECRET_NAME" --type merge --patch-file /dev/stdin >/dev/null
  else
    printf '%s' "$2" | kubectl -n "$ns" create secret generic "$SECRET_NAME" \
      --from-file="$1=/dev/stdin" >/dev/null
  fi
}

# SCM account Jenkins/Argo CD use for a vendor: recorded on the Argo CD project at onboarding
# (default jenkins-<vendor>; an existing user can be chosen with SCM_CI_USER).
vendor_ci_user() { # vendor
  local user
  user=$(kubectl -n "$ARGOCD_NAMESPACE" get appproject "$1" \
    -o jsonpath='{.metadata.annotations.cicd\.k-paas\.org/scm-ci-user}' 2>/dev/null || true)
  echo "${user:-jenkins-$1}"
}

# Source (scm|gitlab) recorded on the vendor's Argo CD project; empty if not onboarded.
# Projects created before the label existed are recognised by their gitops repository URL.
vendor_source() { # vendor
  local label repos
  label=$(kubectl -n "$ARGOCD_NAMESPACE" get appproject "$1" \
    -o jsonpath='{.metadata.labels.cicd\.k-paas\.org/source}' 2>/dev/null || true)
  if [[ -n "$label" ]]; then echo "$label"; return 0; fi
  repos=$(kubectl -n "$ARGOCD_NAMESPACE" get appproject "$1" -o jsonpath='{.spec.sourceRepos[*]}' 2>/dev/null || true)
  case "$repos" in
    *"$SCM_INTERNAL_GIT_URL"*) echo scm ;;
    *"$GITLAB_INTERNAL_URL"*) echo gitlab ;;
  esac
  return 0
}
# Namespace layout recorded on the vendor's Argo CD project (onboard-vendor.sh --namespace):
#   split  (default) : <vendor>-dev and <vendor>-prod
#   single           : <vendor> for both environments; resources are named <app>-dev / <app>-prod
vendor_ns_mode() { # vendor
  local mode
  mode=$(kubectl -n "$ARGOCD_NAMESPACE" get appproject "$1" \
    -o jsonpath='{.metadata.labels.cicd\.k-paas\.org/ns-mode}' 2>/dev/null || true)
  echo "${mode:-split}"
}
env_namespace() { # vendor env mode
  if [[ "$3" == single ]]; then echo "$1"; else echo "$1-$2"; fi
}
# kustomize lines that make an overlay share the vendor namespace (single mode): name suffix and an
# env label that is also added to the selectors, so dev and prod objects never select each other
env_layout() { # env mode
  [[ "$2" == single ]] || return 0
  printf 'nameSuffix: -%s\nlabels:\n  - pairs:\n      cicd.k-paas.org/env: %s\n    includeSelectors: true\n' "$1" "$1"
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

# Jenkins API token of a cicd-admins user (stored by: ./deploy-cicd-portal.sh jenkins-token)
load_jenkins_token() {
  JENKINS_USER=${JENKINS_USER:-$(get_secret jenkins-user)}
  JENKINS_API_TOKEN=${JENKINS_API_TOKEN:-$(get_secret jenkins-api-token)}
  [[ -n "$JENKINS_USER" && -n "$JENKINS_API_TOKEN" ]] || \
    die "Jenkins API token not found. Run: JENKINS_USER=<admin> JENKINS_API_TOKEN=<token> ./deploy-cicd-portal.sh jenkins-token"
  export JENKINS_USER JENKINS_API_TOKEN
}

# SCM admin (git password set in scm.<domain> > 내정보 관리)
require_scm_admin() {
  [[ -n "${SCM_ADMIN_PASSWORD:-}" ]] || die "Set SCM_ADMIN_PASSWORD (git password of SCM user $SCM_ADMIN_USER)."
  export SCM_ADMIN_PASSWORD
}

# Copy a template tree with {KEY} placeholders; existing files are kept.
# render_tree src dst [--exclude name]... KEY=value ...
render_tree() {
  local src=$1 dst=$2; shift 2
  python3 - "$src" "$dst" "$@" <<'PY'
import os, sys
src, dst, rest = sys.argv[1], sys.argv[2], sys.argv[3:]
exclude, subs = set(), {}
while rest:
    item = rest.pop(0)
    if item == "--exclude":
        exclude.add(rest.pop(0))
    else:
        k, v = item.split("=", 1)
        subs[k] = v
added = 0
for root, _, files in os.walk(src):
    for name in files:
        if name in exclude:
            continue
        path = os.path.join(root, name)
        out = os.path.join(dst, os.path.relpath(path, src))
        if os.path.exists(out):
            continue
        text = open(path, encoding="utf-8").read()
        for k, v in subs.items():
            text = text.replace("{" + k + "}", v)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "w", encoding="utf-8") as fh:
            fh.write(text)
        added += 1
print(added)
PY
}

# Clone an SCM repository as the SCM admin into a temp dir; prints the dir.
# Empty repositories are allowed (first push creates the branch).
scm_clone() { # repo
  local dir askpass
  dir=$(mktemp -d)
  askpass="$dir.askpass"
  printf '#!/bin/sh\ncase "$1" in Username*) echo "$SCM_ADMIN_USER";; *) echo "$SCM_ADMIN_PASSWORD";; esac\n' >"$askpass"
  chmod 700 "$askpass"
  GIT_ASKPASS=$askpass GIT_TERMINAL_PROMPT=0 GIT_SSL_CAINFO=$CA_FILE \
    git clone -q --no-checkout "$SCM_GIT_URL/$1" "$dir/repo" 2>/dev/null || {
      echo "[ERROR] Cannot clone $SCM_GIT_URL/$1 as $SCM_ADMIN_USER" >&2; rm -rf "$dir" "$askpass"; return 1; }
  git -C "$dir/repo" config user.name "cicd-portal"
  git -C "$dir/repo" config user.email "cicd-portal@${HOST_DOMAIN}"
  git -C "$dir/repo" config core.askPass "$askpass"
  git -C "$dir/repo" config http.sslCAInfo "$CA_FILE"
  # SCM-Manager 1.x repositories keep HEAD -> master; the portal uses main. A repository that
  # only has master (or another branch) continues from it, so its history is kept on main.
  local base
  for base in origin/main origin/master $(git -C "$dir/repo" for-each-ref --format='%(refname:short)' refs/remotes/origin); do
    [[ "$base" == origin/HEAD ]] && continue
    if git -C "$dir/repo" rev-parse -q --verify "$base" >/dev/null; then
      git -C "$dir/repo" checkout -q -B main "$base"
      [[ "$base" != origin/main ]] && echo "[INFO] SCM $1 has no main branch - main is created from $base" >&2
      break
    fi
  done
  echo "$dir/repo"
}
scm_cleanup() { # dir from scm_clone
  rm -rf "$(dirname "$1")" "$(dirname "$1").askpass"
}
# Commit everything in the clone and push to branch (if there are changes)
scm_commit_push() { # dir branch message
  local dir=$1 branch=$2 message=$3
  git -C "$dir" add -A
  if git -C "$dir" diff --cached --quiet 2>/dev/null && git -C "$dir" rev-parse -q --verify HEAD >/dev/null; then
    return 1
  fi
  git -C "$dir" commit -q -m "$message"
  GIT_TERMINAL_PROMPT=0 git -C "$dir" push -q origin "HEAD:refs/heads/$branch"
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
