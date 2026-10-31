#!/bin/bash
# Read-only checks for the CI/CD portal: Keycloak SSO, Argo CD and every source in CICD_SOURCES
# (scm: K-PaaS SCM + Jenkins, gitlab: GitLab CE + Runner).
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

NAMESPACES=()
CLIENTS=()
if has_source scm; then
  NAMESPACES+=("$SCM_NAMESPACE" "$JENKINS_NAMESPACE")
  CLIENTS+=("$KEYCLOAK_JENKINS_CLIENT_ID")
fi
if has_source gitlab; then
  NAMESPACES+=("$GITLAB_NAMESPACE" "$RUNNER_NAMESPACE")
  CLIENTS+=("$KEYCLOAK_GITLAB_CLIENT_ID")
fi
NAMESPACES+=("$ARGOCD_NAMESPACE")
CLIENTS+=("$KEYCLOAK_ARGOCD_CLIENT_ID")
CONSOLE=0
if kubectl -n "$CONSOLE_NAMESPACE" get deployment cicd-console >/dev/null 2>&1; then   # optional web console
  CONSOLE=1
  NAMESPACES+=("$CONSOLE_NAMESPACE")
  CLIENTS+=("$KEYCLOAK_CONSOLE_CLIENT_ID")
fi

section "1. Pods (sources: $CICD_SOURCES)"
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
if has_source scm; then
  code=$(http_code "https://scm.$HOST_DOMAIN/")
  [[ "$code" =~ ^(200|30[1278])$ ]] && pass "SCM UI https://scm.$HOST_DOMAIN -> $code" || fail "SCM UI https://scm.$HOST_DOMAIN -> $code"
  code=$(http_code "$JENKINS_URL/login")
  [[ "$code" =~ ^(200|30[1278]|403)$ ]] && pass "Jenkins $JENKINS_URL -> $code" || fail "Jenkins $JENKINS_URL/login -> $code"
fi
if has_source gitlab; then
  code=$(http_code "$GITLAB_URL/users/sign_in")
  [[ "$code" == 200 ]] && pass "GitLab $GITLAB_URL -> 200" || fail "GitLab $GITLAB_URL/users/sign_in -> $code"
fi
code=$(http_code "https://$ARGOCD_HOST/healthz")
[[ "$code" == 200 ]] && pass "Argo CD https://$ARGOCD_HOST -> 200" || fail "Argo CD https://$ARGOCD_HOST/healthz -> $code"
if ((CONSOLE)); then
  code=$(http_code "https://$CONSOLE_HOST/healthz")
  [[ "$code" == 200 ]] && pass "Console https://$CONSOLE_HOST -> 200" || fail "Console https://$CONSOLE_HOST/healthz -> $code"
fi
code=$(http_code "$KEYCLOAK_ISSUER/.well-known/openid-configuration")
[[ "$code" == 200 ]] && pass "Keycloak issuer $KEYCLOAK_ISSUER" || fail "Keycloak issuer -> $code"

section "3. Keycloak clients (realm $KEYCLOAK_CP_REALM)"
for client in "${CLIENTS[@]}"; do
  $API kc-exists "$client" 2>/dev/null && pass "client $client" || fail "client $client missing (./deploy-cicd-portal.sh keycloak)"
done

if has_source scm; then
  section "4a. SCM and Jenkins API"
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
fi

if has_source gitlab; then
  section "4b. GitLab API, runner, templates"
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

if security_installed; then
  section "4c. Security scan"
  for ns in "$JENKINS_NAMESPACE" "$RUNNER_NAMESPACE"; do
    [[ "$ns" == "$JENKINS_NAMESPACE" ]] && ! has_source scm && continue
    [[ "$ns" == "$RUNNER_NAMESPACE" ]] && ! has_source gitlab && continue
    for obj in configmap/cicd-security-policy configmap/cicd-security-rules secret/cicd-security-pull; do
      kubectl -n "$ns" get "$obj" >/dev/null 2>&1 && pass "$ns $obj" || fail "$ns $obj missing (./deploy-cicd-portal.sh security)"
    done
  done
  modes=$(kubectl -n "$JENKINS_NAMESPACE" get configmap cicd-security-policy -o 'jsonpath={.data.policy\.json}' 2>/dev/null || \
          kubectl -n "$RUNNER_NAMESPACE" get configmap cicd-security-policy -o 'jsonpath={.data.policy\.json}' 2>/dev/null)
  echo "       gate modes: $(printf '%s' "$modes" | python3 -c 'import json,sys; g=json.load(sys.stdin).get("gates",{}); print(", ".join(k + "=" + str(v.get("mode")) for k, v in g.items()))' 2>/dev/null)"
  if [[ "$SECURITY_PRESIDIO" == true ]]; then
    [[ "$(kubectl -n "$SECURITY_NAMESPACE" get pods -l app=presidio-analyzer --no-headers 2>/dev/null)" == *Running* ]] && \
      pass "Presidio analyzer running" || fail "Presidio analyzer not running in $SECURITY_NAMESPACE"
  fi
fi

section "5. Vendors and Argo CD applications"
vendors=$(kubectl -n "$ARGOCD_NAMESPACE" get appprojects.argoproj.io --no-headers \
  -o custom-columns=NAME:.metadata.name,SOURCE:.metadata.labels.cicd\\.k-paas\\.org/source 2>/dev/null | grep -v '^default ' || true)
if [[ -z "$vendors" ]]; then
  echo "       (no vendors yet - ./onboard-vendor.sh --source <scm|gitlab> <vendor>)"
else
  echo "       VENDOR / SOURCE"
  echo "$vendors" | sed 's/^/       /'
  while read -r name src; do
    if [[ "$src" == "<none>" ]]; then
      echo "       ($name: no source label - re-run ./onboard-vendor.sh $name to record it)"
    elif ! has_source "$src"; then
      fail "vendor $name uses '$src', which is not in CICD_SOURCES ($CICD_SOURCES)"
    fi
  done <<<"$vendors"
fi
apps=$(kubectl -n "$ARGOCD_NAMESPACE" get applications.argoproj.io --no-headers \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>/dev/null)
if [[ -n "$apps" ]]; then
  echo
  echo "$apps" | sed 's/^/       /'
fi

section "Summary"
if has_source scm; then
  echo "SCM    : https://scm.$HOST_DOMAIN"
  echo "Jenkins: $JENKINS_URL"
fi
has_source gitlab && echo "GitLab : $GITLAB_URL"
echo "Argo CD: https://$ARGOCD_HOST"
((CONSOLE)) && echo "Console: https://$CONSOLE_HOST"
((FAILED)) && { echo "[RESULT] FAIL"; exit 1; }
echo "[RESULT] OK"
