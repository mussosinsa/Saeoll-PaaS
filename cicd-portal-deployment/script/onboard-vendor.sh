#!/bin/bash
# Onboard a vendor (team) to the CI/CD portal.
#
# Usage: ./onboard-vendor.sh [--source scm|gitlab] [--namespace split|single] <vendor> [user1,user2,...]
#   --source : where the vendor's repositories and CI live. Required when both sources are
#              installed; fixed after the first onboarding (recorded on the Argo CD project).
#              Use migrate-vendor.sh to move a vendor from scm to gitlab.
#              scm = trusted/internal teams only (the SCM web UI shows all repositories to everyone)
#   --namespace : split (default) = namespaces <vendor>-dev and <vendor>-prod
#              single = one namespace <vendor> for dev and prod (resources <app>-dev / <app>-prod,
#              shared quota: default 8 CPU / 16Gi / 60 pods). Fixed after the first onboarding.
#   vendor   : lowercase id, e.g. saeoll -> Harbor project, namespace(s), Argo CD project
#   users    : Keycloak usernames of the vendor developers (Keycloak group cicd-<vendor>;
#              gitlab: also GitLab group members (Developer) after their first GitLab sign-in)
#   env PM_USERS=pm1,pm2 : vendor PMs, GitLab Maintainer (merge to main, create release tags v*)
#
# --source scm (K-PaaS SCM + Jenkins), env:
#   SCM_ADMIN_PASSWORD  git password of the SCM admin (scm.<domain> > 내정보 관리)
#   SCM_CI_PASSWORD     git password of the CI account (after its first scm login)
#   SCM_CI_USER         CI account (default jenkins-<vendor>, created in Keycloak if missing). An existing
#                       user with a git password can be used instead, e.g. SCM_CI_USER=saeoll (remembered).
#   The gitops repository <vendor>-gitops is created in SCM-Manager if missing (SCM_CREATE_GITOPS=0 to skip).
#   The script creates the Keycloak account jenkins-<vendor> if it does not exist and stops
#   with a checklist while SCM items are missing; re-run after completing them.
#
# Creates (idempotent):
#   all    : Keycloak group cicd-<vendor>, Harbor project <vendor> + robot "cicd",
#            namespaces <vendor>-dev/prod (quota, limits, pull secret, TLS), Argo CD AppProject + repo credentials
#   scm    : Keycloak user jenkins-<vendor>, gitops repo README, Jenkins folder <vendor> + folder credentials
#   gitlab : GitLab group <vendor>, project <vendor>/gitops, group CI variables
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
# shellcheck source=lib.sh
source ./lib.sh

SOURCE=""
NS_MODE=""
ARGS=()
while (($#)); do
  case "$1" in
    --source) SOURCE=${2:-}; shift 2 ;;
    --source=*) SOURCE=${1#--source=}; shift ;;
    --namespace) NS_MODE=${2:-}; shift 2 ;;
    --namespace=*) NS_MODE=${1#--namespace=}; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
VENDOR=${ARGS[0]:-}
USERS=${ARGS[1]:-}
[[ "$VENDOR" =~ ^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$ ]] || {
  echo "Usage: $0 [--source scm|gitlab] [--namespace split|single] <vendor: lowercase letters, digits, '-'> [user1,user2,...]" >&2; exit 2; }
[[ "$VENDOR" != "$TEMPLATES_GROUP" ]] || die "'$TEMPLATES_GROUP' is reserved for the CI templates."
load_portal_vars
require_cmds kubectl python3

# Source of this vendor: fixed once onboarded (migrate-vendor.sh changes it scm -> gitlab)
CURRENT=$(vendor_source "$VENDOR")
if [[ -n "$CURRENT" && -n "$SOURCE" && "$SOURCE" != "$CURRENT" && "${ALLOW_SOURCE_CHANGE:-0}" != 1 ]]; then
  die "Vendor $VENDOR already uses '$CURRENT'. To move it to gitlab use ./migrate-vendor.sh $VENDOR"
fi
SOURCE=${SOURCE:-$CURRENT}
if [[ -z "$SOURCE" ]]; then
  read -ra installed <<<"$CICD_SOURCES"
  ((${#installed[@]} == 1)) || die "Choose the vendor's source: $0 --source <$(echo $CICD_SOURCES | tr ' ' '|')> $VENDOR ..."
  SOURCE=${installed[0]}
fi
[[ "$SOURCE" == scm || "$SOURCE" == gitlab ]] || die "--source must be scm or gitlab (got '$SOURCE')."
has_source "$SOURCE" || die "Source '$SOURCE' is not installed (CICD_SOURCES=$CICD_SOURCES)."
# Namespace layout: fixed once onboarded (moving running apps and data is a manual migration)
[[ -z "$NS_MODE" || "$NS_MODE" == split || "$NS_MODE" == single ]] || die "--namespace must be split or single (got '$NS_MODE')."
if [[ -n "$CURRENT" ]]; then
  CURRENT_NS_MODE=$(vendor_ns_mode "$VENDOR")
  [[ -z "$NS_MODE" || "$NS_MODE" == "$CURRENT_NS_MODE" ]] || \
    die "Vendor $VENDOR already uses the '$CURRENT_NS_MODE' namespace layout; changing it needs a manual migration of its apps and data."
  NS_MODE=$CURRENT_NS_MODE
fi
NS_MODE=${NS_MODE:-split}
info "Vendor $VENDOR -> source $SOURCE, namespace layout $NS_MODE"
ENVS=(dev prod)
if [[ "$NS_MODE" == single ]]; then
  NAMESPACES=("$VENDOR")
  QUOTA_CPU=${QUOTA_CPU:-8} QUOTA_MEMORY=${QUOTA_MEMORY:-16Gi} QUOTA_PODS=${QUOTA_PODS:-60} QUOTA_PVCS=${QUOTA_PVCS:-20}
else
  NAMESPACES=("$VENDOR-dev" "$VENDOR-prod")
fi
PULL_SECRET=harbor-cicd
CI_USER=${SCM_CI_USER:-}
[[ -n "$CI_USER" ]] || CI_USER=$(vendor_ci_user "$VENDOR")
TODO=()

if [[ "$SOURCE" == scm ]]; then
  require_cmds git
  require_scm_admin
  load_jenkins_token
  GITOPS_REPO="$VENDOR-gitops"
  GITOPS_URL="$SCM_INTERNAL_GIT_URL/$GITOPS_REPO"
else
  load_gitlab_token
  GITOPS_URL="$GITLAB_INTERNAL_URL/$VENDOR/gitops.git"
fi

# 1. Keycloak group (Argo CD / Jenkins access) -------------------------------------
ALL_USERS=$(printf '%s,%s' "$USERS" "${PM_USERS:-}" | sed 's/^,*//; s/,*$//')
$API kc-group "cicd-$VENDOR" --members "$ALL_USERS"

# 2. Harbor project and robot account ------------------------------------------------
$API harbor-project "$VENDOR"
mapfile -t robot < <($API harbor-robot "$VENDOR" cicd)
((${#robot[@]} == 2)) || die "Cannot create the Harbor robot account for $VENDOR."

# 3. Namespaces --------------------------------------------------------------------------
for ns in "${NAMESPACES[@]}"; do
  # never take over a namespace created for something else (e.g. a CP-Portal user namespace)
  owner=$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)
  if kubectl get namespace "$ns" >/dev/null 2>&1 && [[ "$owner" != cicd-portal && "${ALLOW_EXISTING_NAMESPACE:-0}" != 1 ]]; then
    die "Namespace $ns already exists and is not managed by the CI/CD portal. Choose another vendor id, or ALLOW_EXISTING_NAMESPACE=1 to use it."
  fi
  if [[ "$NS_MODE" == single ]]; then
    ensure_namespace "$ns" cp.k-paas.org/vendor="$VENDOR" app.kubernetes.io/managed-by=cicd-portal
  else
    ensure_namespace "$ns" cp.k-paas.org/vendor="$VENDOR" cp.k-paas.org/env="${ns##*-}" app.kubernetes.io/managed-by=cicd-portal
  fi
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: vendor-quota
  namespace: $ns
spec:
  hard:
    requests.cpu: "${QUOTA_CPU:-4}"
    requests.memory: ${QUOTA_MEMORY:-8Gi}
    limits.memory: ${QUOTA_MEMORY:-8Gi}
    pods: "${QUOTA_PODS:-30}"
    persistentvolumeclaims: "${QUOTA_PVCS:-10}"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: vendor-defaults
  namespace: $ns
spec:
  limits:
  - type: Container
    default:
      memory: 512Mi
    defaultRequest:
      cpu: 50m
      memory: 128Mi
EOF
  kubectl -n "$ns" create secret docker-registry "$PULL_SECRET" \
    --docker-server="$HARBOR_HOST" --docker-username="${robot[0]}" --docker-password="${robot[1]}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  copy_tls_secret "$ns"
  ok "Namespace $ns (quota, limits, pull secret $PULL_SECRET, TLS secret)"
done

# 4. Source repositories and CI -------------------------------------------------------------
if [[ "$SOURCE" == scm ]]; then
  # CI account in Keycloak (SCM/Jenkins/Argo CD use it for git access to the vendor repos)
  if [[ "$CI_USER" == "jenkins-$VENDOR" ]]; then   # dedicated CI account: create it if missing
    ci_kc_password=$(get_secret "kc-$CI_USER-password")
    [[ -n "$ci_kc_password" ]] || ci_kc_password=$(random_string 20)
    state=$(printf '%s' "$ci_kc_password" | $API kc-user "$CI_USER" --email "$CI_USER@cicd.$HOST_DOMAIN")
    if [[ "$state" == created ]]; then
      set_secret "kc-$CI_USER-password" "$ci_kc_password"
    fi
    login_hint="(Keycloak password of $CI_USER: kubectl -n $JENKINS_NAMESPACE get secret $SECRET_NAME -o jsonpath='{.data.kc-$CI_USER-password}' | base64 -d)"
  else
    login_hint="(existing user $CI_USER: use its own Keycloak password)"
  fi
  if [[ -z "${SCM_CI_PASSWORD:-}" ]]; then
    TODO+=("Sign in to https://scm.$HOST_DOMAIN as $CI_USER, set its git password in 내정보 관리 if not done, re-run with SCM_CI_PASSWORD='<that git password>'
      $login_hint")
  fi
  # The gitops repository is used only by Jenkins/Argo CD: create it directly in SCM-Manager when
  # missing (SCM_CREATE_GITOPS=0 to require creating it in scm.<domain> instead)
  if [[ "${SCM_CREATE_GITOPS:-1}" == 1 ]]; then
    $API scm-create "$GITOPS_REPO" --user "$CI_USER" --level WRITE \
      --description "$VENDOR deployment manifests (CI/CD portal, Argo CD)" >/dev/null
  fi
  if ! $API scm-check "$GITOPS_REPO" --user "$CI_USER" --level WRITE; then
    TODO+=("In https://scm.$HOST_DOMAIN make sure Git repository '$GITOPS_REPO' exists and $CI_USER is 참여자 (쓰기 권한)")
  fi
  if ((${#TODO[@]} == 0)); then
    # gitops repository skeleton (main branch)
    dir=$(scm_clone "$GITOPS_REPO")
    if [[ ! -f "$dir/README.md" ]]; then
      cat >"$dir/README.md" <<EOF
# $VENDOR gitops

Kubernetes manifests of $VENDOR services, deployed by Argo CD (CI/CD portal).

- \`apps/<app>/base\`: Deployment, Service, Ingress
- \`apps/<app>/overlays/dev\`: namespace $(env_namespace "$VENDOR" dev "$NS_MODE"), image tag updated by Jenkins \`<app>-dev\`
- \`apps/<app>/overlays/prod\`: namespace $(env_namespace "$VENDOR" prod "$NS_MODE"), image tag updated by Jenkins \`<app>-release\`

Do not edit \`newTag\` by hand except for a rollback.
EOF
    fi
    if scm_commit_push "$dir" main "Initialize $VENDOR gitops (cicd-portal)"; then
      ok "SCM $GITOPS_REPO initialized (main)"
    else
      info "SCM $GITOPS_REPO already initialized"
    fi
    scm_cleanup "$dir"

    # Jenkins folder with folder-scoped credentials
    $API jenkins-folder "$VENDOR" --group "cicd-$VENDOR"
    printf '%s' "${robot[1]}" | $API jenkins-cred "$VENDOR" "$VENDOR-harbor" --username "${robot[0]}" \
      --description "Harbor robot account ($VENDOR)"
    printf '%s' "$SCM_CI_PASSWORD" | $API jenkins-cred "$VENDOR" "$VENDOR-scm" --username "$CI_USER" \
      --description "SCM account $CI_USER (read app repositories, write $GITOPS_REPO)"
    REPO_USER=$CI_USER
    REPO_PASSWORD=$SCM_CI_PASSWORD
  fi
else
  $API gl-group "$VENDOR" --visibility private >/dev/null
  $API gl-project "$VENDOR" gitops --visibility private >/dev/null
  [[ -n "$USERS" ]] && $API gl-members "$VENDOR" "$USERS" --level 30
  [[ -n "${PM_USERS:-}" ]] && $API gl-members "$VENDOR" "$PM_USERS" --level 40
  # CI writes image tags to the gitops repo; Argo CD reads it
  gitops_ci_token=$($API gl-project-token "$VENDOR/gitops" gitops-ci --scopes write_repository,read_repository --level 40)
  gitops_cd_token=$($API gl-project-token "$VENDOR/gitops" gitops-argocd --scopes read_repository --level 20)
  printf '%s' "$gitops_ci_token" | $API gl-group-var "$VENDOR" GITOPS_TOKEN --masked
  printf '%s' "${robot[0]}" | $API gl-group-var "$VENDOR" HARBOR_USER
  printf '%s' "${robot[1]}" | $API gl-group-var "$VENDOR" HARBOR_PASSWORD --masked
  REPO_USER=gitops-argocd
  REPO_PASSWORD=$gitops_cd_token
fi

# 5. Argo CD project and repository credentials ------------------------------------------------
if [[ -n "${REPO_PASSWORD:-}" ]]; then
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-creds-$VENDOR-gitops
  namespace: $ARGOCD_NAMESPACE
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: $GITOPS_URL
  username: $REPO_USER
  password: $REPO_PASSWORD
EOF
fi
kubectl apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: $VENDOR
  namespace: $ARGOCD_NAMESPACE
  labels:
    cicd.k-paas.org/source: $SOURCE
    cicd.k-paas.org/ns-mode: $NS_MODE
  annotations:
    cicd.k-paas.org/scm-ci-user: "$([[ "$SOURCE" == scm ]] && echo "$CI_USER")"
spec:
  description: Applications of $VENDOR (CI/CD portal)
  sourceRepos:
    - $GITOPS_URL
  destinations:
$(for ns in "${NAMESPACES[@]}"; do printf '    - server: https://kubernetes.default.svc\n      namespace: %s\n' "$ns"; done)
  clusterResourceWhitelist: []
  namespaceResourceBlacklist:
    - group: ""
      kind: ResourceQuota
    - group: ""
      kind: LimitRange
  roles:
    - name: developer
      description: View all, sync dev only (prod sync is done by cicd-admins)
      groups:
        - cicd-$VENDOR
      policies:
        - p, proj:$VENDOR:developer, applications, get, $VENDOR/*, allow
        - p, proj:$VENDOR:developer, applications, sync, $VENDOR/*-dev, allow
        - p, proj:$VENDOR:developer, logs, get, $VENDOR/*, allow
EOF
ok "Argo CD project $VENDOR (repo $GITOPS_URL)"

echo
if ((${#TODO[@]})); then
  echo "Vendor $VENDOR partially onboarded. Complete these in K-PaaS source control and re-run $0 $VENDOR:"
  printf '  - %s\n' "${TODO[@]}"
  exit 3
fi
echo "Vendor $VENDOR onboarded."
if [[ "$SOURCE" == scm ]]; then
  echo "  SCM          : https://scm.$HOST_DOMAIN  (gitops repository $GITOPS_REPO, CI account $CI_USER)"
  echo "  Jenkins      : https://$JENKINS_HOST/job/$VENDOR/  (Keycloak group cicd-$VENDOR: read/build)"
else
  echo "  GitLab group : $GITLAB_URL/$VENDOR   (gitops repo: $GITLAB_URL/$VENDOR/gitops)"
fi
echo "  Harbor       : $HARBOR_URL/harbor/projects  (project $VENDOR, robot ${robot[0]})"
echo "  Namespaces   : ${NAMESPACES[*]} (layout $NS_MODE)"
echo "  Argo CD      : https://$ARGOCD_HOST  (project $VENDOR, Keycloak group cicd-$VENDOR)"
echo "Next: ./add-app.sh $VENDOR <app> <java-gradle|java-maven|php|node|vue>"
