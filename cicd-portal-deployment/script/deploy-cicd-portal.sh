#!/bin/bash
# Deploy the CI/CD portal next to K-PaaS (the K-PaaS cp-pipeline and
# cp-source-control deployments are not changed). SSO through new clients in Keycloak cp-realm.
#   CICD_SOURCE=scm    : K-PaaS SCM (repositories) + Jenkins (jenkins.<domain>) + Argo CD (argocd.<domain>)
#   CICD_SOURCE=gitlab : GitLab CE (gitlab.<domain>) + GitLab Runner + Argo CD
#
# Usage: ./deploy-cicd-portal.sh [step ...]
#   scm steps   : preflight keycloak jenkins argocd   (default) + jenkins-token (after the first login)
#   gitlab steps: preflight keycloak gitlab bootstrap templates runner argocd (default)
# Re-runnable; each step can be run on its own.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
# shellcheck source=lib.sh
source ./lib.sh
load_portal_vars
VALUES_DIR="$SCRIPT_DIR/../values"
STEPS=("$@")
if ((${#STEPS[@]} == 0)); then
  if [[ "$CICD_SOURCE" == scm ]]; then
    STEPS=(preflight keycloak jenkins argocd)
  else
    STEPS=(preflight keycloak gitlab bootstrap templates runner argocd)
  fi
fi
RUNNER_DESCRIPTION="cicd-k8s"

step_preflight() {
  info "Preflight"
  local failed=0 cmd
  for cmd in kubectl helm curl python3 base64; do
    command -v "$cmd" >/dev/null || { warn "$cmd is not installed"; failed=1; }
  done
  kubectl get storageclass "$K8S_STORAGECLASS" >/dev/null 2>&1 || { warn "StorageClass not found: $K8S_STORAGECLASS"; failed=1; }
  kubectl -n "$CP_PORTAL_NAMESPACE" get secret "$TLS_SECRET" >/dev/null 2>&1 || {
    warn "TLS secret $TLS_SECRET not found in $CP_PORTAL_NAMESPACE (deploy CP-Portal first)"; failed=1; }
  [[ -s "$CA_FILE" ]] || { warn "K-PaaS CA certificate not found: $CA_FILE (set CA_FILE)"; failed=1; }
  # no "grep -q" in pipes here: with pipefail its early exit makes kubectl fail with SIGPIPE
  [[ "$(kubectl -n keycloak get pods --no-headers 2>/dev/null)" == *Running* ]] || { warn "Keycloak is not running"; failed=1; }
  kubectl get ingressclass "$INGRESS_CLASS_NAME" >/dev/null 2>&1 || { warn "IngressClass not found: $INGRESS_CLASS_NAME"; failed=1; }
  if [[ "$CICD_SOURCE" == scm ]]; then
    command -v git >/dev/null || { warn "git is not installed (dnf install -y git)"; failed=1; }
    [[ "$(kubectl -n "$SCM_NAMESPACE" get pods --no-headers 2>/dev/null)" == *Running* ]] || {
      warn "K-PaaS source control is not running in $SCM_NAMESPACE (deploy cp-source-control-deployment first)"; failed=1; }
    if [[ -n "${SCM_ADMIN_PASSWORD:-}" ]]; then
      export SCM_ADMIN_PASSWORD
      local scm_err
      if scm_err=$($API scm-ping 2>&1 >/dev/null); then
        ok "SCM-Manager REST API reachable as $SCM_ADMIN_USER ($SCM_URL)"
      else
        warn "SCM-Manager REST API login failed ($SCM_URL/api/rest, user $SCM_ADMIN_USER): ${scm_err:-unknown error}"
        [[ "$scm_err" == *"HTTP 401"* ]] && \
          warn "  401: SCM_ADMIN_PASSWORD must be the git password set in https://scm.$HOST_DOMAIN > 내정보 관리 (not the Keycloak password)"
        [[ "$scm_err" == *CERTIFICATE* ]] && warn "  TLS: CA_FILE ($CA_FILE) does not verify scm-manager.$HOST_DOMAIN"
        failed=1
      fi
    else
      warn "SCM_ADMIN_PASSWORD not set - SCM login not checked (needed by onboard-vendor.sh / add-app.sh)"
    fi
    echo "       Node capacity (Jenkins requests 0.5 CPU / 1Gi, limit 3Gi; build pods up to 6Gi each):"
  else
    local tag=${GITLAB_IMAGE##*:} repo=${GITLAB_IMAGE%:*}
    if [[ "$repo" == gitlab/gitlab-ce ]]; then
      curl -fsS -o /dev/null "https://hub.docker.com/v2/repositories/gitlab/gitlab-ce/tags/$tag" 2>/dev/null || \
        warn "Image tag not found on Docker Hub (or no internet): $GITLAB_IMAGE"
    fi
    echo "       Node capacity (GitLab requests ${GITLAB_CPU_REQUEST} CPU / ${GITLAB_MEMORY_REQUEST}, limit ${GITLAB_MEMORY_LIMIT}):"
  fi
  kubectl top nodes 2>/dev/null | sed 's/^/       /' || warn "kubectl top nodes unavailable (metrics-server)"
  ((failed == 0)) || die "Preflight failed."
  ok "Preflight passed"
}

step_keycloak() {
  info "Keycloak clients in realm $KEYCLOAK_CP_REALM (existing clients are not changed)"
  ensure_namespace "$SECRETS_NAMESPACE" app.kubernetes.io/part-of=cicd-portal
  local secret source_client
  if [[ "$CICD_SOURCE" == scm ]]; then
    source_client=$KEYCLOAK_JENKINS_CLIENT_ID
    secret=$($API kc-client "$KEYCLOAK_JENKINS_CLIENT_ID" --groups-mapper \
      --redirect "https://$JENKINS_HOST/securityRealm/finishLogin" --redirect "https://$JENKINS_HOST/*" \
      --origin "https://$JENKINS_HOST")
    set_secret jenkins-oidc-secret "$secret"
  else
    source_client=$KEYCLOAK_GITLAB_CLIENT_ID
    secret=$($API kc-client "$KEYCLOAK_GITLAB_CLIENT_ID" \
      --redirect "https://$GITLAB_HOST/users/auth/openid_connect/callback" --origin "https://$GITLAB_HOST")
    set_secret gitlab-oidc-secret "$secret"
  fi
  secret=$($API kc-client "$KEYCLOAK_ARGOCD_CLIENT_ID" --groups-mapper \
    --redirect "https://$ARGOCD_HOST/auth/callback" --origin "https://$ARGOCD_HOST")
  set_secret argocd-oidc-secret "$secret"
  $API kc-group "$KEYCLOAK_ADMIN_GROUP" --members "$KEYCLOAK_ADMIN_USERNAME"
  ok "Keycloak clients: $source_client, $KEYCLOAK_ARGOCD_CLIENT_ID; admin group: $KEYCLOAK_ADMIN_GROUP"
}

step_gitlab() {
  info "GitLab CE ($GITLAB_IMAGE) in $GITLAB_NAMESPACE"
  ensure_namespace "$GITLAB_NAMESPACE" app.kubernetes.io/part-of=cicd-portal
  copy_tls_secret "$GITLAB_NAMESPACE"
  ensure_ca_secret "$GITLAB_NAMESPACE"
  [[ -n "$(get_secret gitlab-oidc-secret)" ]] || die "Keycloak client secret missing. Run: $0 keycloak"
  [[ -n "$(get_secret root-password)" ]] || set_secret root-password "$(random_string 24)"
  mkdir -p "$VALUES_DIR"
  render_file ../manifests/gitlab.yaml "$VALUES_DIR/gitlab.yaml" \
    NAMESPACE="$GITLAB_NAMESPACE" GITLAB_HOST="$GITLAB_HOST" GITLAB_IMAGE="$GITLAB_IMAGE" \
    STORAGECLASS="$K8S_STORAGECLASS" DATA_SIZE="$GITLAB_DATA_SIZE" CONFIG_SIZE="$GITLAB_CONFIG_SIZE" \
    LOGS_SIZE="$GITLAB_LOGS_SIZE" CPU_REQUEST="$GITLAB_CPU_REQUEST" MEMORY_REQUEST="$GITLAB_MEMORY_REQUEST" \
    MEMORY_LIMIT="$GITLAB_MEMORY_LIMIT" TLS_SECRET="$TLS_SECRET" INGRESS_CLASS_NAME="$INGRESS_CLASS_NAME" \
    SECRET_NAME="$SECRET_NAME" CA_SECRET_NAME="$CA_SECRET_NAME" KEYCLOAK_ISSUER="$KEYCLOAK_ISSUER" \
    OIDC_CLIENT_ID="$KEYCLOAK_GITLAB_CLIENT_ID"
  kubectl apply -f "$VALUES_DIR/gitlab.yaml"
  # Pick up config changes (the Omnibus config is read at container start)
  kubectl -n "$GITLAB_NAMESPACE" rollout restart deployment/gitlab >/dev/null
  info "Waiting for GitLab to become ready (first start takes 5-15 minutes)..."
  kubectl -n "$GITLAB_NAMESPACE" rollout status deployment/gitlab --timeout=1500s || \
    die "GitLab is not ready. Check: kubectl -n $GITLAB_NAMESPACE logs deploy/gitlab --tail=100"
  ok "GitLab: $GITLAB_URL"
}

step_bootstrap() {
  info "GitLab bootstrap (automation token, settings, instance CI variables)"
  local token pod
  token=$(get_secret automation-token)
  export GITLAB_TOKEN=$token
  if [[ -z "$token" ]] || ! $API gl-wait --timeout 30 >/dev/null 2>&1; then
    token="glpat-$(random_string 20)"
    pod=$(kubectl -n "$GITLAB_NAMESPACE" get pods -l app=gitlab -o jsonpath='{.items[0].metadata.name}')
    info "Creating the root automation token (gitlab-rails runner, ~1 minute)..."
    # The script (with the token) goes through stdin, not the command line
    kubectl -n "$GITLAB_NAMESPACE" exec -i "$pod" -- sh -c \
      'f=$(mktemp /tmp/cicd-XXXXXX.rb); cat >"$f"; chmod 644 "$f"; gitlab-rails runner "$f"; rc=$?; rm -f "$f"; exit $rc' <<RUBY | tail -1
u = User.find_by_username("root")
u.personal_access_tokens.where(name: "cicd-automation", revoked: false).each(&:revoke!)
t = u.personal_access_tokens.create!(name: "cicd-automation", scopes: ["api", "read_repository", "write_repository"],
                                    expires_at: 364.days.from_now)
t.set_token("$token")
t.save!
puts "token ok"
RUBY
    set_secret automation-token "$token"
    export GITLAB_TOKEN=$token
  fi
  info "GitLab $($API gl-wait --timeout 300)"
  $API gl-settings
  ok "Sign-up disabled (users sign in with K-PaaS SSO)"
  $API gl-instance-var \
    HARBOR_HOST="$HARBOR_HOST" \
    CICD_DOCKERHUB="$CICD_DOCKERHUB" \
    CICD_BASE_REGISTRY="$CICD_BASE_REGISTRY" \
    KANIKO_IMAGE="$KANIKO_IMAGE" \
    CICD_CA_FILE="/etc/cicd-ca/ca.crt" \
    GITOPS_HOST="$GITLAB_INTERNAL_HOST" \
    CICD_HOST_DOMAIN="$HOST_DOMAIN"
}

step_templates() {
  load_gitlab_token
  info "CI templates project $TEMPLATES_GROUP/$TEMPLATES_PROJECT"
  # internal: every signed-in user's pipeline can include the templates
  $API gl-group "$TEMPLATES_GROUP" --visibility internal >/dev/null
  $API gl-project "$TEMPLATES_GROUP" "$TEMPLATES_PROJECT" --visibility internal >/dev/null
  $API gl-push-dir "$TEMPLATES_GROUP/$TEMPLATES_PROJECT" ../ci-templates --message "Sync CI templates"
  $API gl-protect-tag "$TEMPLATES_GROUP/$TEMPLATES_PROJECT" 'v*'
}

step_runner() {
  load_gitlab_token
  info "GitLab Runner (chart $GITLAB_RUNNER_CHART_VERSION) in $RUNNER_NAMESPACE"
  ensure_namespace "$RUNNER_NAMESPACE" app.kubernetes.io/part-of=cicd-portal
  ensure_ca_secret "$RUNNER_NAMESPACE"
  local token
  token=$($API gl-runner "$RUNNER_DESCRIPTION")
  printf '%s' "$token" | kubectl -n "$RUNNER_NAMESPACE" create secret generic gitlab-runner-token \
    --from-file=runner-token=/dev/stdin --from-literal=runner-registration-token="" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  mkdir -p "$VALUES_DIR"
  render_file ../values_orig/gitlab-runner.yaml "$VALUES_DIR/gitlab-runner.yaml" \
    GITLAB_INTERNAL_URL="$GITLAB_INTERNAL_URL" RUNNER_CONCURRENT="$RUNNER_CONCURRENT" \
    RUNNER_NAMESPACE="$RUNNER_NAMESPACE" CICD_DOCKERHUB="$CICD_DOCKERHUB" \
    RUNNER_BUILD_MEMORY_LIMIT="$RUNNER_BUILD_MEMORY_LIMIT" CA_SECRET_NAME="$CA_SECRET_NAME"
  helm repo add gitlab https://charts.gitlab.io >/dev/null 2>&1 || true
  helm repo update gitlab >/dev/null
  helm upgrade --install gitlab-runner gitlab/gitlab-runner --version "$GITLAB_RUNNER_CHART_VERSION" \
    -n "$RUNNER_NAMESPACE" -f "$VALUES_DIR/gitlab-runner.yaml"
  # The registration secret changed: restart so the runner picks it up
  kubectl -n "$RUNNER_NAMESPACE" rollout restart deployment/gitlab-runner >/dev/null
  kubectl -n "$RUNNER_NAMESPACE" rollout status deployment/gitlab-runner --timeout=300s
  local n online=0
  for n in $(seq 1 12); do
    online=$($API gl-runners-online "$RUNNER_DESCRIPTION" 2>/dev/null || echo 0)
    ((online > 0)) && break
    sleep 10
  done
  ((online > 0)) && ok "Runner online: $RUNNER_DESCRIPTION" || warn "Runner not online yet: kubectl -n $RUNNER_NAMESPACE logs deploy/gitlab-runner"
}

step_jenkins() {
  info "Jenkins (chart ${JENKINS_CHART_VERSION:-latest}) in $JENKINS_NAMESPACE"
  ensure_namespace "$JENKINS_NAMESPACE" app.kubernetes.io/part-of=cicd-portal
  copy_tls_secret "$JENKINS_NAMESPACE"
  ensure_ca_secret "$JENKINS_NAMESPACE"
  [[ "$JENKINS_SSO" != true || -n "$(get_secret jenkins-oidc-secret)" ]] || die "Keycloak client secret missing. Run: $0 keycloak"
  [[ -n "$(get_secret jenkins-oidc-secret)" ]] || set_secret jenkins-oidc-secret none
  mkdir -p "$VALUES_DIR"
  local subst=(JENKINS_HOST="$JENKINS_HOST" ARGOCD_HOST="$ARGOCD_HOST" INGRESS_CLASS_NAME="$INGRESS_CLASS_NAME"
               TLS_SECRET="$TLS_SECRET" STORAGECLASS="$K8S_STORAGECLASS" JENKINS_DATA_SIZE="$JENKINS_DATA_SIZE"
               CA_SECRET_NAME="$CA_SECRET_NAME" SECRET_NAME="$SECRET_NAME" JENKINS_TOOL_IMAGE="$JENKINS_TOOL_IMAGE"
               OIDC_CLIENT_ID="$KEYCLOAK_JENKINS_CLIENT_ID" KEYCLOAK_ISSUER="$KEYCLOAK_ISSUER" ADMIN_GROUP="$KEYCLOAK_ADMIN_GROUP")
  render_file ../values_orig/jenkins.yaml "$VALUES_DIR/jenkins.yaml" "${subst[@]}"
  local values=(-f "$VALUES_DIR/jenkins.yaml")
  if [[ "$JENKINS_SSO" == true ]]; then
    render_file ../values_orig/jenkins-sso.yaml "$VALUES_DIR/jenkins-sso.yaml" "${subst[@]}"
    values+=(-f "$VALUES_DIR/jenkins-sso.yaml")
  else
    warn "JENKINS_SSO=false: local admin (kubectl -n $JENKINS_NAMESPACE get secret jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)"
  fi
  helm repo add jenkins https://charts.jenkins.io >/dev/null 2>&1 || true
  helm repo update jenkins >/dev/null
  helm upgrade --install jenkins jenkins/jenkins ${JENKINS_CHART_VERSION:+--version "$JENKINS_CHART_VERSION"} \
    -n "$JENKINS_NAMESPACE" "${values[@]}"
  # A crash-looping StatefulSet pod is not replaced by the upgrade (and keeps old JCasC
  # files in its emptyDir): recreate it so the new configuration is used.
  local restarts
  restarts=$(kubectl -n "$JENKINS_NAMESPACE" get pod jenkins-0 \
    -o jsonpath='{.status.containerStatuses[?(@.name=="jenkins")].restartCount}' 2>/dev/null || true)
  if [[ "${restarts:-0}" -gt 0 ]]; then
    info "jenkins-0 restarted $restarts time(s) before - recreating it with the new configuration"
    kubectl -n "$JENKINS_NAMESPACE" delete pod jenkins-0 --wait=true >/dev/null
  fi
  info "Waiting for Jenkins (plugin download on first start takes a few minutes)..."
  kubectl -n "$JENKINS_NAMESPACE" rollout status statefulset/jenkins --timeout=1200s || \
    die "Jenkins is not ready. Check: kubectl -n $JENKINS_NAMESPACE logs statefulset/jenkins -c jenkins --tail=100"
  ok "Jenkins: https://$JENKINS_HOST (chart $(helm list -n "$JENKINS_NAMESPACE" -f '^jenkins$' -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["chart"])'))"
  echo "       Next: sign in as a member of '$KEYCLOAK_ADMIN_GROUP', create an API token (user menu > Security),"
  echo "       then: JENKINS_USER=<user> JENKINS_API_TOKEN=<token> $0 jenkins-token"
}

step_jenkins-token() {
  [[ -n "${JENKINS_USER:-}" && -n "${JENKINS_API_TOKEN:-}" ]] || \
    die "Usage: JENKINS_USER=<cicd-admins member> JENKINS_API_TOKEN=<token> $0 jenkins-token"
  export JENKINS_USER JENKINS_API_TOKEN
  $API jenkins-ping >/dev/null || die "Jenkins API login failed for $JENKINS_USER ($JENKINS_URL)."
  set_secret jenkins-user "$JENKINS_USER"
  set_secret jenkins-api-token "$JENKINS_API_TOKEN"
  ok "Jenkins API token stored for $JENKINS_USER (used by onboard-vendor.sh / add-app.sh)"
}

step_argocd() {
  info "Argo CD (chart $ARGOCD_CHART_VERSION) in $ARGOCD_NAMESPACE"
  ensure_namespace "$ARGOCD_NAMESPACE" app.kubernetes.io/part-of=cicd-portal
  copy_tls_secret "$ARGOCD_NAMESPACE"
  local oidc_secret ca_pem secret_values
  oidc_secret=$(get_secret argocd-oidc-secret)
  [[ -n "$oidc_secret" ]] || die "Keycloak client secret missing. Run: $0 keycloak"
  ca_pem=$(sed 's/^/        /' "$CA_FILE")
  mkdir -p "$VALUES_DIR"
  render_file ../values_orig/argocd.yaml "$VALUES_DIR/argocd.yaml" \
    ARGOCD_HOST="$ARGOCD_HOST" KEYCLOAK_ISSUER="$KEYCLOAK_ISSUER" OIDC_CLIENT_ID="$KEYCLOAK_ARGOCD_CLIENT_ID" \
    CA_PEM="$ca_pem" ADMIN_GROUP="$KEYCLOAK_ADMIN_GROUP" INGRESS_CLASS_NAME="$INGRESS_CLASS_NAME" \
    TLS_SECRET="$TLS_SECRET"
  # The client secret goes through a private temp file, not the command line
  secret_values=$(mktemp)
  chmod 600 "$secret_values"
  printf 'configs:\n  secret:\n    extra:\n      oidc.keycloak.clientSecret: "%s"\n' "$oidc_secret" >"$secret_values"
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  helm repo update argo >/dev/null
  helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_CHART_VERSION" \
    -n "$ARGOCD_NAMESPACE" -f "$VALUES_DIR/argocd.yaml" -f "$secret_values" || { rm -f "$secret_values"; exit 1; }
  rm -f "$secret_values"
  # Wait for every component (server, repo-server, controller, redis), not only the UI
  local res
  for res in $(kubectl -n "$ARGOCD_NAMESPACE" get deployment,statefulset -o name); do
    kubectl -n "$ARGOCD_NAMESPACE" rollout status "$res" --timeout=600s
  done
  ok "Argo CD: https://$ARGOCD_HOST"
}

for step in "${STEPS[@]}"; do
  case "$CICD_SOURCE:$step" in
    *:preflight|*:keycloak|*:argocd|scm:jenkins|scm:jenkins-token|gitlab:gitlab|gitlab:bootstrap|gitlab:templates|gitlab:runner)
      "step_$step" ;;
    scm:*) die "Unknown step for CICD_SOURCE=scm: $step (preflight keycloak jenkins argocd jenkins-token)" ;;
    *) die "Unknown step for CICD_SOURCE=gitlab: $step (preflight keycloak gitlab bootstrap templates runner argocd)" ;;
  esac
done

echo
echo "-----------------------------------------------------------------------------"
if [[ "$CICD_SOURCE" == scm ]]; then
  echo "SCM    : https://scm.$HOST_DOMAIN   (K-PaaS source control: repositories, accounts, 참여자 권한)"
  echo "Jenkins: https://$JENKINS_HOST   (K-PaaS SSO; admins: Keycloak group '$KEYCLOAK_ADMIN_GROUP')"
else
  echo "GitLab : $GITLAB_URL   (K-PaaS SSO; break-glass: root / kubectl -n $GITLAB_NAMESPACE get secret $SECRET_NAME -o jsonpath='{.data.root-password}' | base64 -d)"
fi
echo "Argo CD: https://$ARGOCD_HOST   (K-PaaS SSO, admin group '$KEYCLOAK_ADMIN_GROUP'; break-glass: admin / kubectl -n $ARGOCD_NAMESPACE get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
echo "Next   : ./onboard-vendor.sh <vendor> [users]  ->  ./add-app.sh <vendor> <app> <java-gradle|java-maven|php|node|vue>"
[[ "$CICD_SOURCE" == scm ]] && echo "         (SCM: create the repositories and accounts in scm.$HOST_DOMAIN first - see README)"
echo "Check  : ./check-cicd-portal.sh"
echo "-----------------------------------------------------------------------------"
