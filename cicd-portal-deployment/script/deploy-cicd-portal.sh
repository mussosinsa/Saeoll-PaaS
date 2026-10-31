#!/bin/bash
# Deploy the CI/CD portal next to K-PaaS (the K-PaaS cp-pipeline and
# cp-source-control deployments are not changed). SSO through new clients in Keycloak cp-realm.
# Installs the sources in CICD_SOURCES (default "scm gitlab") plus the shared Argo CD:
#   scm    : K-PaaS SCM (repositories) + Jenkins (jenkins.<domain>)
#   gitlab : GitLab CE (gitlab.<domain>) + GitLab Runner
# Each vendor then uses one of them: ./onboard-vendor.sh --source scm|gitlab <vendor> ...
#
# Usage: [CICD_SOURCES="scm gitlab"] ./deploy-cicd-portal.sh [step ...]
#   steps: preflight keycloak [jenkins] [gitlab bootstrap templates runner] argocd   (default: all installed)
#          jenkins-token (scm, once after the first Jenkins login)
#          console-image console   (optional web console https://cicd.<domain>: image build with podman
#                                   + push to Harbor, then deploy; env SCM_ADMIN_PASSWORD for scm vendors)
#          security-image security (optional security scan in the pipelines + console 품질 관리: scanner image,
#                                   policy/rules ConfigMaps, Harbor scan on push; SECURITY_PRESIDIO=true adds
#                                   Presidio, DEFECTDOJO_URL + DEFECTDOJO_TOKEN send the reports to DefectDojo)
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
  STEPS=(preflight keycloak)
  has_source scm && STEPS+=(jenkins)
  has_source gitlab && STEPS+=(gitlab bootstrap templates runner)
  STEPS+=(argocd)
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
  info "Sources: $CICD_SOURCES (+ Argo CD)"
  command -v git >/dev/null || { warn "git is not installed (dnf install -y git)"; failed=1; }
  if has_source scm; then
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
  fi
  if has_source gitlab; then
    local tag=${GITLAB_IMAGE##*:} repo=${GITLAB_IMAGE%:*}
    if [[ "$repo" == gitlab/gitlab-ce ]]; then
      curl -fsS -o /dev/null "https://hub.docker.com/v2/repositories/gitlab/gitlab-ce/tags/$tag" 2>/dev/null || \
        warn "Image tag not found on Docker Hub (or no internet): $GITLAB_IMAGE"
    fi
  fi
  echo "       Node capacity - requests: Argo CD ~1Gi$(has_source scm && echo ", Jenkins 0.5 CPU/1Gi (limit 3Gi)")$(has_source gitlab && echo ", GitLab ${GITLAB_CPU_REQUEST} CPU/${GITLAB_MEMORY_REQUEST} (limit ${GITLAB_MEMORY_LIMIT})"); builds up to 6Gi each:"
  kubectl top nodes 2>/dev/null | sed 's/^/       /' || warn "kubectl top nodes unavailable (metrics-server)"
  ((failed == 0)) || die "Preflight failed."
  ok "Preflight passed"
}

step_keycloak() {
  info "Keycloak clients in realm $KEYCLOAK_CP_REALM (existing clients are not changed)"
  local secret clients=()
  if has_source scm; then
    clients+=("$KEYCLOAK_JENKINS_CLIENT_ID")
    secret=$($API kc-client "$KEYCLOAK_JENKINS_CLIENT_ID" --groups-mapper \
      --redirect "https://$JENKINS_HOST/securityRealm/finishLogin" --redirect "https://$JENKINS_HOST/*" \
      --origin "https://$JENKINS_HOST")
    set_secret jenkins-oidc-secret "$secret"
  fi
  if has_source gitlab; then
    clients+=("$KEYCLOAK_GITLAB_CLIENT_ID")
    secret=$($API kc-client "$KEYCLOAK_GITLAB_CLIENT_ID" \
      --redirect "https://$GITLAB_HOST/users/auth/openid_connect/callback" --origin "https://$GITLAB_HOST")
    set_secret gitlab-oidc-secret "$secret"
  fi
  secret=$($API kc-client "$KEYCLOAK_ARGOCD_CLIENT_ID" --groups-mapper \
    --redirect "https://$ARGOCD_HOST/auth/callback" --origin "https://$ARGOCD_HOST")
  set_secret argocd-oidc-secret "$secret"
  $API kc-group "$KEYCLOAK_ADMIN_GROUP" --members "$KEYCLOAK_ADMIN_USERNAME"
  ok "Keycloak clients: ${clients[*]} $KEYCLOAK_ARGOCD_CLIENT_ID; admin group: $KEYCLOAK_ADMIN_GROUP"
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
  # security scan installed: policy/rules ConfigMaps and the scanner pull secret in the job pods
  local sec_pull="" sec_volumes=""
  if kubectl -n "$RUNNER_NAMESPACE" get configmap cicd-security-policy >/dev/null 2>&1; then
    sec_pull=$'\n        image_pull_secrets = ["cicd-security-pull"]'
    sec_volumes=$'\n        [[runners.kubernetes.volumes.config_map]]\n          name = "cicd-security-policy"\n          mount_path = "/etc/cicd-security/policy"\n          read_only = true'
    sec_volumes+=$'\n        [[runners.kubernetes.volumes.config_map]]\n          name = "cicd-security-rules"\n          mount_path = "/etc/cicd-security/rules"\n          read_only = true'
  fi
  render_file ../values_orig/gitlab-runner.yaml "$VALUES_DIR/gitlab-runner.yaml" \
    GITLAB_INTERNAL_URL="$GITLAB_INTERNAL_URL" RUNNER_CONCURRENT="$RUNNER_CONCURRENT" \
    RUNNER_NAMESPACE="$RUNNER_NAMESPACE" CICD_DOCKERHUB="$CICD_DOCKERHUB" \
    RUNNER_BUILD_MEMORY_LIMIT="$RUNNER_BUILD_MEMORY_LIMIT" CA_SECRET_NAME="$CA_SECRET_NAME" \
    SECURITY_PULL_SECRETS="$sec_pull" SECURITY_VOLUMES="$sec_volumes"
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

# CI/CD console image: the console plus the scripts it runs, pushed to Harbor
step_console-image() {
  require_cmds podman
  local image="$HARBOR_HOST/$CONSOLE_HARBOR_PROJECT/cicd-console:$CONSOLE_IMAGE_TAG" ctx podman=(podman)
  ((EUID == 0)) || podman=(sudo podman)   # same podman storage/trust as the CP-Portal image builds
  info "CI/CD console image $image"
  ctx=$(mktemp -d)
  cp -r ../console ../script ../starters ../gitops-template ../db-template ../ci-templates "$ctx/"
  rm -rf "$ctx/console/tests" "$ctx/script/"*.log
  find "$ctx" -name __pycache__ -prune -exec rm -rf {} +
  cp "$(command -v kubectl)" "$ctx/kubectl"
  $API harbor-project "$CONSOLE_HARBOR_PROJECT"
  printf '%s' "$REPOSITORY_PASSWORD" | "${podman[@]}" login "$HARBOR_HOST" --username "$REPOSITORY_USERNAME" --password-stdin >/dev/null
  "${podman[@]}" build -f "$ctx/console/Dockerfile" -t "$image" \
    --build-arg BASE_IMAGE="$CONSOLE_BASE_IMAGE" --build-arg PIP_INDEX_URL="$CONSOLE_PIP_INDEX_URL" \
    --build-arg APT_MIRROR="$CONSOLE_APT_MIRROR" "$ctx" || { rm -rf "$ctx"; die "Console image build failed."; }
  rm -rf "$ctx"
  "${podman[@]}" push "$image" || die "Console image push failed ($image)."
  ok "Console image pushed: $image"
}

step_console() {
  info "CI/CD console https://$CONSOLE_HOST in $CONSOLE_NAMESPACE"
  local image="$HARBOR_HOST/$CONSOLE_HARBOR_PROJECT/cicd-console:$CONSOLE_IMAGE_TAG" dir oidc_secret session_key scm_password
  ensure_namespace "$CONSOLE_NAMESPACE" app.kubernetes.io/part-of=cicd-portal
  copy_tls_secret "$CONSOLE_NAMESPACE"
  ensure_ca_secret "$CONSOLE_NAMESPACE"
  # redirect URIs: login callback, and the console root that Keycloak returns to after logout
  # (post.logout.redirect.uris "+" = the same list)
  oidc_secret=$($API kc-client "$KEYCLOAK_CONSOLE_CLIENT_ID" --groups-mapper \
    --redirect "https://$CONSOLE_HOST/oauth/callback" --redirect "https://$CONSOLE_HOST/" \
    --origin "https://$CONSOLE_HOST")
  # pull secret: robot account of the console's Harbor project (pull only is enough, push is harmless)
  mapfile -t robot < <($API harbor-robot "$CONSOLE_HARBOR_PROJECT" console)
  ((${#robot[@]} == 2)) || die "Cannot create the Harbor robot account (run: $0 console-image first)."
  kubectl -n "$CONSOLE_NAMESPACE" create secret docker-registry cicd-console-pull \
    --docker-server="$HARBOR_HOST" --docker-username="${robot[0]}" --docker-password="${robot[1]}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # keep the session key and the SCM password across re-runs
  session_key=$(kubectl -n "$CONSOLE_NAMESPACE" get secret cicd-console-secrets -o 'jsonpath={.data.session-key}' 2>/dev/null | base64 -d 2>/dev/null || true)
  [[ -n "$session_key" ]] || session_key=$(random_string 48)
  scm_password=${SCM_ADMIN_PASSWORD:-$(kubectl -n "$CONSOLE_NAMESPACE" get secret cicd-console-secrets -o 'jsonpath={.data.scm-admin-password}' 2>/dev/null | base64 -d 2>/dev/null || true)}
  if has_source scm && [[ -z "$scm_password" ]]; then
    warn "SCM_ADMIN_PASSWORD not set: scm vendors cannot be onboarded from the console (re-run with SCM_ADMIN_PASSWORD=...)"
  fi
  # values the scripts read from cp-portal-vars.sh, in a private temp dir (never on a command line)
  dir=$(mktemp -d)
  chmod 700 "$dir"
  {
    printf 'HOST_DOMAIN=%q\n' "$HOST_DOMAIN"
    printf 'K8S_STORAGECLASS=%q\n' "$K8S_STORAGECLASS"
    printf 'KEYCLOAK_URL=%q\n' "$KEYCLOAK_URL"
    printf 'KEYCLOAK_ADMIN_USERNAME=%q\n' "$KEYCLOAK_ADMIN_USERNAME"
    printf 'KEYCLOAK_ADMIN_PASSWORD=%q\n' "$KEYCLOAK_ADMIN_PASSWORD"
    printf 'KEYCLOAK_CP_REALM=%q\n' "$KEYCLOAK_CP_REALM"
    printf 'REPOSITORY_URL=%q\n' "$HARBOR_URL"
    printf 'REPOSITORY_USERNAME=%q\n' "$REPOSITORY_USERNAME"
    printf 'REPOSITORY_PASSWORD=%q\n' "$REPOSITORY_PASSWORD"
    printf 'DATABASE_URL=%q\n' "$PLATFORM_DB_URL"
    printf 'DATABASE_USER_PASSWORD=%q\n' "$DATABASE_USER_PASSWORD"
  } >"$dir/cp-portal-vars.sh"
  printf '%s' "$oidc_secret" >"$dir/oidc-client-secret"
  printf '%s' "$session_key" >"$dir/session-key"
  local from=(--from-file="$dir/cp-portal-vars.sh" --from-file="$dir/oidc-client-secret" --from-file="$dir/session-key")
  if [[ -n "$scm_password" ]]; then
    printf '%s' "$scm_password" >"$dir/scm-admin-password"
    from+=(--from-file="$dir/scm-admin-password")
  fi
  kubectl -n "$CONSOLE_NAMESPACE" create secret generic cicd-console-secrets "${from[@]}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  rm -rf "$dir"
  kubectl -n "$CONSOLE_NAMESPACE" create configmap cicd-console-vars --from-file=cicd-vars.sh=./cicd-vars.sh \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  mkdir -p "$VALUES_DIR"
  render_file ../manifests/console.yaml "$VALUES_DIR/console.yaml" \
    NAMESPACE="$CONSOLE_NAMESPACE" IMAGE="$image" CONSOLE_HOST="$CONSOLE_HOST" \
    OIDC_CLIENT_ID="$KEYCLOAK_CONSOLE_CLIENT_ID" CA_SECRET_NAME="$CA_SECRET_NAME" TLS_SECRET="$TLS_SECRET" \
    INGRESS_CLASS_NAME="$INGRESS_CLASS_NAME" JENKINS_API_URL="$CONSOLE_JENKINS_API_URL" \
    GITLAB_API_URL="$CONSOLE_GITLAB_API_URL" SCM_API_URL="$CONSOLE_SCM_API_URL"
  kubectl apply -f "$VALUES_DIR/console.yaml"
  # secrets, config map and image tag may have changed: start a new pod
  kubectl -n "$CONSOLE_NAMESPACE" rollout restart deployment/cicd-console >/dev/null
  kubectl -n "$CONSOLE_NAMESPACE" rollout status deployment/cicd-console --timeout=300s || \
    die "Console is not ready. Check: kubectl -n $CONSOLE_NAMESPACE logs deploy/cicd-console"
  ok "CI/CD console: https://$CONSOLE_HOST (K-PaaS SSO; '$KEYCLOAK_ADMIN_GROUP' = operators, cicd-<vendor> = vendors)"
}

# Security scanner image (Semgrep, Gitleaks, Trivy + DB, cicd-scan, rules) pushed to Harbor
step_security-image() {
  require_cmds podman
  local podman=(podman) ctx
  ((EUID == 0)) || podman=(sudo podman)
  info "Security scanner image $SECURITY_IMAGE"
  ctx=$(mktemp -d)
  cp -r ../security/scanner ../security/rules ../security/policy "$ctx/"
  $API harbor-project "$CONSOLE_HARBOR_PROJECT"
  printf '%s' "$REPOSITORY_PASSWORD" | "${podman[@]}" login "$HARBOR_HOST" --username "$REPOSITORY_USERNAME" --password-stdin >/dev/null
  "${podman[@]}" build -f "$ctx/scanner/Dockerfile" -t "$SECURITY_IMAGE" \
    --build-arg BASE_IMAGE="$SECURITY_BASE_IMAGE" --build-arg GITLEAKS_IMAGE="$SECURITY_GITLEAKS_IMAGE" \
    --build-arg TRIVY_IMAGE="$SECURITY_TRIVY_IMAGE" --build-arg SEMGREP_VERSION="$SECURITY_SEMGREP_VERSION" \
    --build-arg PIP_INDEX_URL="$CONSOLE_PIP_INDEX_URL" --build-arg APT_MIRROR="$CONSOLE_APT_MIRROR" \
    --build-arg TRIVY_DB_REPOSITORY="$SECURITY_TRIVY_DB_REPOSITORY" \
    --build-arg TRIVY_JAVA_DB_REPOSITORY="$SECURITY_TRIVY_JAVA_DB_REPOSITORY" "$ctx" || {
      rm -rf "$ctx"; die "Security scanner image build failed."; }
  rm -rf "$ctx"
  "${podman[@]}" push "$SECURITY_IMAGE" || die "Security scanner image push failed ($SECURITY_IMAGE)."
  ok "Security scanner image pushed: $SECURITY_IMAGE (rebuild regularly to refresh the Trivy DB)"
}

# Security scan in the pipelines: ConfigMaps (policy edited in the console, rules/settings from this repo),
# scanner pull secret, Harbor scan on push, optional Presidio and DefectDojo, GitLab templates/runner.
step_security() {
  local namespaces=() ns dir presidio_url="" policy_src="" robot v gitlab=0
  has_source scm && namespaces+=("$JENKINS_NAMESPACE")
  # gitlab in CICD_SOURCES but not installed yet (no automation token): skip its parts
  if has_source gitlab; then
    if [[ -n "$(get_secret automation-token)" ]]; then
      gitlab=1
      namespaces+=("$RUNNER_NAMESPACE")
    else
      warn "GitLab is in CICD_SOURCES but not installed (no automation token) - GitLab parts skipped."
      warn "  Not using GitLab: set CICD_SOURCES=\"scm\" in cicd-vars.sh. Installing it later: re-run '$0 security' after 'gitlab bootstrap templates runner'."
    fi
  fi
  ((${#namespaces[@]})) || die "No installed CI source (scm: Jenkins, gitlab: GitLab + runner)."
  info "Security scan for ${namespaces[*]} (image $SECURITY_IMAGE)"

  if [[ "$SECURITY_PRESIDIO" == true ]]; then
    ensure_namespace "$SECURITY_NAMESPACE" app.kubernetes.io/part-of=cicd-portal
    mkdir -p "$VALUES_DIR"
    render_file ../manifests/presidio.yaml "$VALUES_DIR/presidio.yaml" NAMESPACE="$SECURITY_NAMESPACE" PRESIDIO_IMAGE="$PRESIDIO_IMAGE"
    kubectl apply -f "$VALUES_DIR/presidio.yaml" >/dev/null
    kubectl -n "$SECURITY_NAMESPACE" rollout status deployment/presidio-analyzer --timeout=600s || \
      warn "Presidio is not ready yet: kubectl -n $SECURITY_NAMESPACE logs deploy/presidio-analyzer"
    presidio_url="http://presidio-analyzer.$SECURITY_NAMESPACE.svc.cluster.local:3000"
    ok "Presidio analyzer: $presidio_url"
  fi

  # rules + settings (always refreshed from the repository)
  dir=$(mktemp -d)
  cp ../security/rules/* "$dir/"
  python3 - "$dir/settings.json" "$SECURITY_TRIVY_DB_REPOSITORY" "$SECURITY_TRIVY_JAVA_DB_REPOSITORY" "$presidio_url" <<'PY'
import json, sys
path, db, java_db, presidio = sys.argv[1:]
s = json.load(open(path))
s["trivy"].update(db_repository=db, java_db_repository=java_db)
s["presidio"]["url"] = presidio
json.dump(s, open(path, "w"), ensure_ascii=False, indent=1)
PY
  # policy: kept once created (edited in the console); SECURITY_POLICY_RESET=1 restores the default
  for ns in "${namespaces[@]}"; do
    if kubectl -n "$ns" get configmap cicd-security-policy >/dev/null 2>&1; then
      kubectl -n "$ns" get configmap cicd-security-policy -o 'jsonpath={.data.policy\.json}' >"$dir/policy.current"
      [[ -s "$dir/policy.current" ]] && { policy_src="$dir/policy.current"; break; }
    fi
  done
  if [[ -z "$policy_src" || "${SECURITY_POLICY_RESET:-0}" == 1 ]]; then
    policy_src=../security/policy/policy.json
    info "Security policy: default (report mode - switch to enforce in the console 품질 관리 > 보안 게이트)"
  fi
  mapfile -t robot < <($API harbor-robot "$CONSOLE_HARBOR_PROJECT" security)
  ((${#robot[@]} == 2)) || die "Cannot create the Harbor robot account (run: $0 security-image first)."
  for ns in "${namespaces[@]}"; do
    ensure_namespace "$ns" app.kubernetes.io/part-of=cicd-portal
    kubectl -n "$ns" create configmap cicd-security-rules --from-file="$dir" --dry-run=client -o yaml | \
      kubectl label --local -f - app.kubernetes.io/part-of=cicd-portal -o yaml | kubectl apply -f - >/dev/null
    kubectl -n "$ns" create configmap cicd-security-policy --from-file=policy.json="$policy_src" --dry-run=client -o yaml | \
      kubectl label --local -f - app.kubernetes.io/part-of=cicd-portal -o yaml | kubectl apply -f - >/dev/null
    kubectl -n "$ns" create secret docker-registry cicd-security-pull \
      --docker-server="$HARBOR_HOST" --docker-username="${robot[0]}" --docker-password="${robot[1]}" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    if [[ -n "${DEFECTDOJO_URL:-}" && -n "${DEFECTDOJO_TOKEN:-}" ]]; then
      printf '%s' "$DEFECTDOJO_TOKEN" | kubectl -n "$ns" create secret generic cicd-security-defectdojo \
        --from-literal=DEFECTDOJO_URL="$DEFECTDOJO_URL" --from-file=DEFECTDOJO_TOKEN=/dev/stdin \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
      ok "DefectDojo upload enabled in $ns ($DEFECTDOJO_URL)"
    fi
    ok "$ns: ConfigMaps cicd-security-policy, cicd-security-rules, pull secret cicd-security-pull"
  done
  rm -rf "$dir"

  # Harbor: scan every pushed image (Trivy in Harbor) for all onboarded vendors
  for v in $(kubectl -n "$ARGOCD_NAMESPACE" get appprojects.argoproj.io -o name 2>/dev/null | sed 's|.*/||'); do
    [[ "$v" == default ]] && continue
    $API harbor-security "$v" ${SECURITY_HARBOR_PREVENT:+--prevent "$SECURITY_HARBOR_PREVENT"} || \
      warn "Harbor project $v: scan settings not changed"
  done

  if ((gitlab)); then
    load_gitlab_token
    $API gl-instance-var CICD_SECURITY_IMAGE="$SECURITY_IMAGE"
    if [[ -n "${DEFECTDOJO_URL:-}" && -n "${DEFECTDOJO_TOKEN:-}" ]]; then
      $API gl-instance-var DEFECTDOJO_URL="$DEFECTDOJO_URL"
      printf '%s' "$DEFECTDOJO_TOKEN" | $API gl-instance-secret DEFECTDOJO_TOKEN
    fi
    step_templates
    step_runner
  fi
  echo "       Jenkins (scm) apps get the security stages with a new Jenkinsfile: console 앱 추가 with"
  echo "       '기존 CI 파일 교체' (REPLACE_CI=1 ./add-app.sh <vendor> <app> <type>). GitLab apps use the templates now."
  if kubectl -n "$CONSOLE_NAMESPACE" get deployment cicd-console >/dev/null 2>&1; then
    echo "       Console: re-run '$0 console' once so it may read and edit the security ConfigMaps."
  fi
  ok "Security scan installed (policy: console 품질 관리)"
}

for step in "${STEPS[@]}"; do
  case "$step" in
    preflight|keycloak|argocd|console-image|console|security-image|security) "step_$step" ;;
    jenkins|jenkins-token)
      has_source scm || die "Step $step needs scm in CICD_SOURCES (now: $CICD_SOURCES)"
      "step_$step" ;;
    gitlab|bootstrap|templates|runner)
      has_source gitlab || die "Step $step needs gitlab in CICD_SOURCES (now: $CICD_SOURCES)"
      "step_$step" ;;
    *) die "Unknown step: $step (preflight keycloak jenkins jenkins-token gitlab bootstrap templates runner argocd console-image console security-image security)" ;;
  esac
done

echo
echo "-----------------------------------------------------------------------------"
if has_source scm; then
  echo "SCM    : https://scm.$HOST_DOMAIN   (K-PaaS source control: repositories, accounts, 참여자 권한)"
  echo "Jenkins: https://$JENKINS_HOST   (K-PaaS SSO; admins: Keycloak group '$KEYCLOAK_ADMIN_GROUP')"
fi
if has_source gitlab; then
  echo "GitLab : $GITLAB_URL   (K-PaaS SSO; break-glass: root / kubectl -n $GITLAB_NAMESPACE get secret $SECRET_NAME -o jsonpath='{.data.root-password}' | base64 -d)"
fi
echo "Argo CD: https://$ARGOCD_HOST   (K-PaaS SSO, admin group '$KEYCLOAK_ADMIN_GROUP'; break-glass: admin / kubectl -n $ARGOCD_NAMESPACE get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
echo "Next   : ./onboard-vendor.sh --source <$(echo $CICD_SOURCES | tr ' ' '|')> <vendor> [users]  ->  ./add-app.sh <vendor> <app> <java-gradle|java-maven|php|node|vue>"
if has_source scm; then
  echo "         (scm vendors: create the repositories and accounts in scm.$HOST_DOMAIN first - see README)"
fi
if kubectl -n "$CONSOLE_NAMESPACE" get deployment cicd-console >/dev/null 2>&1; then
  echo "Console: https://$CONSOLE_HOST   (K-PaaS SSO; web UI for vendors, applications, builds and deployments)"
else
  echo "Console: (optional) $0 console-image console  ->  https://$CONSOLE_HOST"
fi
echo "Check  : ./check-cicd-portal.sh"
echo "-----------------------------------------------------------------------------"
