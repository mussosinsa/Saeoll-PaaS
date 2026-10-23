#!/bin/bash
# Read-only checks for the CI/CD portal (GitLab CE, GitLab Runner, Argo CD, Keycloak SSO).
#   ./check-cicd-portal.sh
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || exit 1
# shellcheck source=lib.sh
source ./lib.sh
load_portal_vars
FAILED=0

section() { printf '\n===== %s =====\n' "$*"; }
pass() { echo "[OK]   $*"; }
fail() { echo "[FAIL] $*"; FAILED=1; }
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 --cacert "$CA_FILE" "$@"; }

section "1. Pods"
for ns in "$GITLAB_NAMESPACE" "$RUNNER_NAMESPACE" "$ARGOCD_NAMESPACE"; do
  pods=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | grep -v '^runner-')
  if [[ -z "$pods" ]]; then
    fail "no pods in $ns"
    continue
  fi
  bad=$(echo "$pods" | awk '{split($2,r,"/"); if ($3!="Completed" && ($3!="Running" || r[1]!=r[2] || $4+0>3)) print}')
  [[ -z "$bad" ]] && pass "$ns pods are Running/Ready" || { fail "$ns has unhealthy pods:"; echo "$bad" | sed 's/^/       /'; }
done

section "2. Endpoints"
code=$(http_code "$GITLAB_URL/users/sign_in")
[[ "$code" == 200 ]] && pass "GitLab $GITLAB_URL -> 200" || fail "GitLab $GITLAB_URL/users/sign_in -> $code"
code=$(http_code "https://$ARGOCD_HOST/healthz")
[[ "$code" == 200 ]] && pass "Argo CD https://$ARGOCD_HOST -> 200" || fail "Argo CD https://$ARGOCD_HOST/healthz -> $code"
code=$(http_code "$KEYCLOAK_ISSUER/.well-known/openid-configuration")
[[ "$code" == 200 ]] && pass "Keycloak issuer $KEYCLOAK_ISSUER" || fail "Keycloak issuer -> $code"

section "3. Keycloak clients (realm $KEYCLOAK_CP_REALM)"
for client in "$KEYCLOAK_GITLAB_CLIENT_ID" "$KEYCLOAK_ARGOCD_CLIENT_ID"; do
  $API kc-exists "$client" 2>/dev/null && pass "client $client" || fail "client $client missing (./deploy-cicd-portal.sh keycloak)"
done

section "4. GitLab API, runner, templates"
GITLAB_TOKEN=$(get_secret automation-token)
export GITLAB_TOKEN
if [[ -z "$GITLAB_TOKEN" ]]; then
  fail "automation token missing (./deploy-cicd-portal.sh bootstrap)"
else
  version=$($API gl-get /version 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null)
  [[ -n "$version" ]] && pass "GitLab API $version (automation token valid)" || fail "GitLab API not reachable or token invalid"
  online=$($API gl-runners-online cicd-k8s 2>/dev/null || echo 0)
  ((online > 0)) && pass "runner cicd-k8s online ($online)" || fail "runner cicd-k8s not online (kubectl -n $RUNNER_NAMESPACE logs deploy/gitlab-runner)"
  $API gl-get "/projects/$TEMPLATES_GROUP%2F$TEMPLATES_PROJECT" >/dev/null 2>&1 && \
    pass "templates project $TEMPLATES_GROUP/$TEMPLATES_PROJECT" || fail "templates project missing (./deploy-cicd-portal.sh templates)"
fi

section "5. Argo CD applications"
apps=$(kubectl -n "$ARGOCD_NAMESPACE" get applications.argoproj.io --no-headers \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>/dev/null)
if [[ -z "$apps" ]]; then
  echo "       (no applications yet - ./onboard-vendor.sh, ./add-app.sh)"
else
  echo "$apps" | sed 's/^/       /'
fi

section "Summary"
echo "GitLab : $GITLAB_URL"
echo "Argo CD: https://$ARGOCD_HOST"
((FAILED)) && { echo "[RESULT] FAIL"; exit 1; }
echo "[RESULT] OK"
