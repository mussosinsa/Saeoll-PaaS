#!/bin/bash
# Read-only checks for the CI/CD portal (Keycloak SSO, Argo CD and
# CICD_SOURCE=scm: K-PaaS SCM + Jenkins / CICD_SOURCE=gitlab: GitLab CE + Runner).
#   ./check-cicd-portal.sh                 (SCM_ADMIN_PASSWORD=... also checks the SCM login)
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
if [[ "$CICD_SOURCE" == scm ]]; then
  NAMESPACES=("$SCM_NAMESPACE" "$JENKINS_NAMESPACE" "$ARGOCD_NAMESPACE")
  SOURCE_CLIENT=$KEYCLOAK_JENKINS_CLIENT_ID
else
  NAMESPACES=("$GITLAB_NAMESPACE" "$RUNNER_NAMESPACE" "$ARGOCD_NAMESPACE")
  SOURCE_CLIENT=$KEYCLOAK_GITLAB_CLIENT_ID
fi
for ns in "${NAMESPACES[@]}"; do
  # skip CI job pods: GitLab runner-*, Jenkins kubernetes agents (label jenkins/label)
  pods=$(kubectl -n "$ns" get pods -l '!jenkins/label' --no-headers 2>/dev/null | grep -v '^runner-' || true)
  if [[ -z "$pods" ]]; then
    fail "no pods in $ns"
    continue
  fi
  bad=$(echo "$pods" | awk '{split($2,r,"/"); if ($3!="Completed" && ($3!="Running" || r[1]!=r[2] || $4+0>3)) print}')
  [[ -z "$bad" ]] && pass "$ns pods are Running/Ready" || { fail "$ns has unhealthy pods:"; echo "$bad" | sed 's/^/       /'; }
done

section "2. Endpoints"
if [[ "$CICD_SOURCE" == scm ]]; then
  code=$(http_code "https://scm.$HOST_DOMAIN/")
  [[ "$code" =~ ^(200|30[1278])$ ]] && pass "SCM UI https://scm.$HOST_DOMAIN -> $code" || fail "SCM UI https://scm.$HOST_DOMAIN -> $code"
  code=$(http_code "$JENKINS_URL/login")
  [[ "$code" =~ ^(200|30[1278]|403)$ ]] && pass "Jenkins $JENKINS_URL -> $code" || fail "Jenkins $JENKINS_URL/login -> $code"
else
  code=$(http_code "$GITLAB_URL/users/sign_in")
  [[ "$code" == 200 ]] && pass "GitLab $GITLAB_URL -> 200" || fail "GitLab $GITLAB_URL/users/sign_in -> $code"
fi
code=$(http_code "https://$ARGOCD_HOST/healthz")
[[ "$code" == 200 ]] && pass "Argo CD https://$ARGOCD_HOST -> 200" || fail "Argo CD https://$ARGOCD_HOST/healthz -> $code"
code=$(http_code "$KEYCLOAK_ISSUER/.well-known/openid-configuration")
[[ "$code" == 200 ]] && pass "Keycloak issuer $KEYCLOAK_ISSUER" || fail "Keycloak issuer -> $code"

section "3. Keycloak clients (realm $KEYCLOAK_CP_REALM)"
for client in "$SOURCE_CLIENT" "$KEYCLOAK_ARGOCD_CLIENT_ID"; do
  $API kc-exists "$client" 2>/dev/null && pass "client $client" || fail "client $client missing (./deploy-cicd-portal.sh keycloak)"
done

if [[ "$CICD_SOURCE" == scm ]]; then
section "4. SCM and Jenkins API"
if [[ -n "${SCM_ADMIN_PASSWORD:-}" ]]; then
  export SCM_ADMIN_PASSWORD
  n=$($API scm-ping 2>/dev/null) && pass "SCM-Manager REST API as $SCM_ADMIN_USER ($n repositories)" || fail "SCM-Manager REST API login failed ($SCM_URL)"
else
  echo "       (set SCM_ADMIN_PASSWORD to check the SCM-Manager login)"
fi
JENKINS_USER=${JENKINS_USER:-$(get_secret jenkins-user)}
JENKINS_API_TOKEN=${JENKINS_API_TOKEN:-$(get_secret jenkins-api-token)}
export JENKINS_USER JENKINS_API_TOKEN
if [[ -z "$JENKINS_API_TOKEN" ]]; then
  fail "Jenkins API token missing (JENKINS_USER=.. JENKINS_API_TOKEN=.. ./deploy-cicd-portal.sh jenkins-token)"
else
  $API jenkins-ping >/dev/null 2>&1 && pass "Jenkins API as $JENKINS_USER" || fail "Jenkins API login failed for $JENKINS_USER"
fi
else
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
if [[ "$CICD_SOURCE" == scm ]]; then
  echo "SCM    : https://scm.$HOST_DOMAIN"
  echo "Jenkins: $JENKINS_URL"
else
  echo "GitLab : $GITLAB_URL"
fi
echo "Argo CD: https://$ARGOCD_HOST"
((FAILED)) && { echo "[RESULT] FAIL"; exit 1; }
echo "[RESULT] OK"
