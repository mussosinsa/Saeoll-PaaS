#!/bin/bash
# Read-only checks for the deployed source control (SCM-Manager 1.x).
#   ./check-cp-source-control.sh
#   SCM_ADMIN_PASSWORD='...' ./check-cp-source-control.sh            # + admin API login
#   SCM_ADMIN_PASSWORD='...' SCM_TEST_REPO=test ./check-cp-source-control.sh  # + git ls-remote
#   SCM_CHECK_USER=saeoll,jenkins-vendor-a ./check-cp-source-control.sh     # + user registration
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || exit 1
SC_VARS="$SCRIPT_DIR/../upstream/script/cp-source-control-vars.sh"
PORTAL_VARS=${PORTAL_VARS:-"$SCRIPT_DIR/../../cp-portal-deployment/script/cp-portal-vars.sh"}
SCM_ADMIN_ID=${SCM_ADMIN_ID:-scmadmin}          # SCM-Manager admin used by K-PaaS
FAILED=0

section() { printf '\n===== %s =====\n' "$*"; }
ok() { echo "[OK]   $*"; }
fail() { echo "[FAIL] $*"; FAILED=1; }
warn() { echo "[WARN] $*"; }

# HOST_DOMAIN/NAMESPACE from the package vars, falling back to CP-Portal vars
read_var() {
  local file=$1 name=$2
  [[ -r "$file" ]] || return 0
  (source "$file" >/dev/null 2>&1; printf '%s' "${!name}")
}
HOST_DOMAIN=${HOST_DOMAIN:-$(read_var "$SC_VARS" HOST_DOMAIN)}
[[ -z "$HOST_DOMAIN" || "$HOST_DOMAIN" == *'{'* ]] && HOST_DOMAIN=$(read_var "$PORTAL_VARS" HOST_DOMAIN)
[[ -n "$HOST_DOMAIN" && "$HOST_DOMAIN" != *'{'* ]] || {
  echo "[ERROR] HOST_DOMAIN not found. Run as: HOST_DOMAIN=<domain> $0" >&2; exit 1; }
NAMESPACE=$(read_var "$SC_VARS" NAMESPACE)
NAMESPACE=${NAMESPACE:-cp-source-control}

SCM_URL="https://scm.${HOST_DOMAIN}"
MANAGER_URL="https://scm-manager.${HOST_DOMAIN}/scm"

# http_code URL [extra curl args...]
http_code() {
  local url=$1; shift
  curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "$@" "$url"
}

# 1. Pods ---------------------------------------------------------------------
section "1. Pod status ($NAMESPACE)"
pods=$(kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null)
if [[ -z "$pods" ]]; then
  fail "no pods in namespace $NAMESPACE"
else
  bad=$(echo "$pods" | awk '{split($2,r,"/"); if ($3!="Completed" && ($3!="Running" || r[1]!=r[2] || $4+0>3)) print}')
  if [[ -n "$bad" ]]; then
    fail "pods that are not healthy (not Ready or restarting):"
    echo "$bad" | sed 's/^/       /'
  else
    ok "pods are Running/Ready"
  fi
  for app in api manager ui; do
    echo "$pods" | grep -q "cp-source-control-$app-" || fail "cp-source-control-$app pod not found"
  done
fi

# 2. Ingress ------------------------------------------------------------------
section "2. Ingress hosts"
hosts=$(kubectl -n "$NAMESPACE" get ingress -o jsonpath='{range .items[*]}{.spec.rules[*].host}{"\n"}{end}' 2>/dev/null)
for host in "scm.${HOST_DOMAIN}" "scm-manager.${HOST_DOMAIN}"; do
  if grep -qx "$host" <<<"$hosts"; then ok "ingress host $host"; else fail "ingress host $host not found"; fi
done

# 3. HTTP ---------------------------------------------------------------------
section "3. HTTP endpoints"
code=$(http_code "$SCM_URL/")
if [[ "$code" =~ ^(200|30[1278])$ ]]; then ok "UI $SCM_URL/ -> $code"; else fail "UI $SCM_URL/ -> $code (expected 200 or redirect)"; fi

code=$(http_code "$MANAGER_URL/")
if [[ "$code" == 200 ]]; then ok "SCM-Manager $MANAGER_URL/ -> 200"; else fail "SCM-Manager $MANAGER_URL/ -> $code (expected 200)"; fi

# SCM-Manager 1.x REST API is /scm/api/rest/*.json (2.x /api/v2 does not exist)
code=$(http_code "$MANAGER_URL/api/rest/repositories.json")
if [[ "$code" == 401 ]]; then
  ok "SCM-Manager API $MANAGER_URL/api/rest/repositories.json -> 401 (auth required)"
else
  fail "SCM-Manager API $MANAGER_URL/api/rest/repositories.json -> $code (expected 401 without auth)"
fi

# 4. Admin login / git (optional) ---------------------------------------------
section "4. Admin login and git access"
if [[ -z "${SCM_ADMIN_PASSWORD:-}" ]]; then
  warn "skipped: set SCM_ADMIN_PASSWORD to check admin login (and SCM_TEST_REPO for git)"
else
  # Pass credentials through a config on stdin so they do not show up in ps
  cred=$(printf '%s:%s' "$SCM_ADMIN_ID" "$SCM_ADMIN_PASSWORD" | sed -e 's/[\\"]/\\&/g')
  code=$(printf 'user = "%s"\n' "$cred" | \
    http_code "$MANAGER_URL/api/rest/repositories.json" -K -)
  if [[ "$code" == 200 ]]; then ok "admin ($SCM_ADMIN_ID) API login -> 200"; else fail "admin ($SCM_ADMIN_ID) API login -> $code (expected 200)"; fi

  if [[ -n "${SCM_TEST_REPO:-}" ]]; then
    askpass=$(mktemp)
    trap 'rm -f "$askpass"' EXIT
    printf '#!/bin/sh\ncase "$1" in Username*) echo "$SCM_ADMIN_ID";; *) echo "$SCM_ADMIN_PASSWORD";; esac\n' > "$askpass"
    chmod 700 "$askpass"
    if SCM_ADMIN_ID=$SCM_ADMIN_ID SCM_ADMIN_PASSWORD=$SCM_ADMIN_PASSWORD GIT_ASKPASS=$askpass GIT_TERMINAL_PROMPT=0 \
       git -c http.sslVerify=false ls-remote "$MANAGER_URL/git/$SCM_TEST_REPO" >/dev/null 2>&1; then
      ok "git ls-remote $MANAGER_URL/git/$SCM_TEST_REPO"
    else
      fail "git ls-remote $MANAGER_URL/git/$SCM_TEST_REPO failed (does the repository exist?)"
    fi
  fi
fi

# 5. User registration (optional) -----------------------------------------------
# Portal users (cp.cp_users) are registered in source control only after their
# first login to https://scm.<domain> (cp_scm.SC_INSTANCE_USER + SCM-Manager user).
if [[ -n "${SCM_CHECK_USER:-}" ]]; then
  section "5. User registration ($SCM_CHECK_USER)"
  DB_PASSWORD=$(read_var "$PORTAL_VARS" DATABASE_USER_PASSWORD)
  db_pod=$(kubectl -n mariadb get pods -l app.kubernetes.io/name=mariadb -o name 2>/dev/null | head -n 1)
  sql() {
    kubectl -n mariadb exec "${db_pod:-mariadb-0}" -c mariadb -- env MYSQL_PWD="$DB_PASSWORD" \
      sh -c 'c=$(command -v mariadb || command -v mysql); "$c" -uroot -N -e "$0"' "$1" 2>/dev/null
  }
  scm_users=""
  if [[ -n "${SCM_ADMIN_PASSWORD:-}" ]]; then
    cred=$(printf '%s:%s' "$SCM_ADMIN_ID" "$SCM_ADMIN_PASSWORD" | sed -e 's/[\\"]/\\&/g')
    scm_users=$(printf 'user = "%s"\n' "$cred" | \
      curl -sk --max-time 15 -K - "$MANAGER_URL/api/rest/users.json" | \
      python3 -c 'import json,sys; print("\n".join(u["name"] for u in json.load(sys.stdin)))' 2>/dev/null)
  fi
  IFS=',' read -ra users <<<"$SCM_CHECK_USER"
  for user in "${users[@]}"; do
    user=$(echo "$user" | tr -d '[:space:]')
    [[ "$user" =~ ^[A-Za-z0-9._@-]+$ ]] || { fail "invalid user id: $user"; continue; }
    portal=$(sql "SELECT COUNT(*) FROM cp.cp_users WHERE user_id='$user'")
    scm_db=$(sql "SELECT COUNT(*) FROM cp_scm.SC_INSTANCE_USER WHERE USER_ID='$user'")
    repos=$(sql "SELECT GROUP_CONCAT(CONCAT(r.REPO_NAME,':',p.PERMISSION)) FROM cp_scm.REPO_PERMITION p JOIN cp_scm.SC_REPOSITORY r ON r.REPO_NO=p.REPO_NO WHERE p.USER_ID='$user'")
    if [[ -z "$portal" || -z "$scm_db" ]]; then
      fail "$user: cannot query MariaDB (check DATABASE_USER_PASSWORD in $PORTAL_VARS)"
      continue
    fi
    ((portal > 0)) && ok "$user: portal user (cp.cp_users)" || \
      warn "$user: not in cp.cp_users (never logged in to the portal)"
    if ((scm_db > 0)); then
      ok "$user: source control user (cp_scm.SC_INSTANCE_USER)"
    else
      fail "$user: not registered in source control - log in once at $SCM_URL"
    fi
    if [[ -n "$scm_users" ]]; then
      grep -qx "$user" <<<"$scm_users" && ok "$user: SCM-Manager account exists" || \
        fail "$user: no SCM-Manager account - log in once at $SCM_URL"
    fi
    if [[ -n "$repos" && "$repos" != NULL ]]; then
      ok "$user: repository permissions: $repos"
    else
      warn "$user: no repository permissions (add as contributor in the repository)"
    fi
  done
  warn "git push/pull needs the password set in $SCM_URL > 내정보 관리 (not the Keycloak password)"
fi

section "Summary"
echo "UI        : $SCM_URL"
echo "Clone URL : $MANAGER_URL/git/<repository>"
echo "REST API  : $MANAGER_URL/api/rest/repositories.json"
if ((FAILED)); then
  echo "[RESULT] FAIL"
  exit 1
fi
echo "[RESULT] OK"
