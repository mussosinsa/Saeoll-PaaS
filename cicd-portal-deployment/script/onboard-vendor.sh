#!/bin/bash
# Onboard a vendor (team) to the CI/CD portal.
#
# Usage: ./onboard-vendor.sh <vendor> [user1,user2,...]
#   vendor : lowercase id, e.g. saeoll -> GitLab group, Harbor project, namespaces <vendor>-dev/prod
#   users  : Keycloak/GitLab usernames of the vendor developers (Developer role).
#            GitLab membership needs one prior GitLab sign-in per user; re-run to add later.
#
# Creates (idempotent):
#   Keycloak group cicd-<vendor> (+ members)        -> Argo CD project role
#   GitLab group <vendor>, project <vendor>/gitops, group CI variables
#   Harbor project <vendor> + robot account "cicd"
#   namespaces <vendor>-dev, <vendor>-prod (quota, limits, pull secret, TLS secret)
#   Argo CD AppProject <vendor> + repository credentials for the gitops repo
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
# shellcheck source=lib.sh
source ./lib.sh

VENDOR=${1:-}
USERS=${2:-}
[[ "$VENDOR" =~ ^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$ ]] || {
  echo "Usage: $0 <vendor: lowercase letters, digits, '-'> [user1,user2,...]" >&2; exit 2; }
[[ "$VENDOR" != "$TEMPLATES_GROUP" ]] || die "'$TEMPLATES_GROUP' is reserved for the CI templates."
load_portal_vars
load_gitlab_token
require_cmds kubectl python3
ENVS=(dev prod)
PULL_SECRET=harbor-cicd
GITOPS_PROJECT="$VENDOR/gitops"
GITOPS_URL="$GITLAB_INTERNAL_URL/$VENDOR/gitops.git"

# 1. Keycloak group (Argo CD access) --------------------------------------------
$API kc-group "cicd-$VENDOR" --members "$USERS"

# 2. GitLab group, gitops project, members ----------------------------------------
$API gl-group "$VENDOR" --visibility private >/dev/null
$API gl-project "$VENDOR" gitops --visibility private >/dev/null
[[ -n "$USERS" ]] && $API gl-members "$VENDOR" "$USERS" --level 30

# CI writes image tags to the gitops repo; Argo CD reads it
gitops_ci_token=$($API gl-project-token "$GITOPS_PROJECT" gitops-ci --scopes write_repository,read_repository --level 40)
gitops_cd_token=$($API gl-project-token "$GITOPS_PROJECT" gitops-argocd --scopes read_repository --level 20)
printf '%s' "$gitops_ci_token" | $API gl-group-var "$VENDOR" GITOPS_TOKEN --masked

# 3. Harbor project and robot account ---------------------------------------------
$API harbor-project "$VENDOR"
mapfile -t robot < <($API harbor-robot "$VENDOR" cicd)
((${#robot[@]} == 2)) || die "Cannot create the Harbor robot account for $VENDOR."
printf '%s' "${robot[0]}" | $API gl-group-var "$VENDOR" HARBOR_USER
printf '%s' "${robot[1]}" | $API gl-group-var "$VENDOR" HARBOR_PASSWORD --masked

# 4. Namespaces ---------------------------------------------------------------------
for env in "${ENVS[@]}"; do
  ns="$VENDOR-$env"
  ensure_namespace "$ns" cp.k-paas.org/vendor="$VENDOR" cp.k-paas.org/env="$env" app.kubernetes.io/managed-by=cicd-portal
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
    persistentvolumeclaims: "10"
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

# 5. Argo CD project and repository credentials --------------------------------------
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
  username: gitops-argocd
  password: $gitops_cd_token
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: $VENDOR
  namespace: $ARGOCD_NAMESPACE
spec:
  description: Applications of $VENDOR (CI/CD portal)
  sourceRepos:
    - $GITOPS_URL
  destinations:
    - server: https://kubernetes.default.svc
      namespace: $VENDOR-dev
    - server: https://kubernetes.default.svc
      namespace: $VENDOR-prod
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
echo "Vendor $VENDOR onboarded."
echo "  GitLab group : $GITLAB_URL/$VENDOR   (gitops repo: $GITLAB_URL/$GITOPS_PROJECT)"
echo "  Harbor       : $HARBOR_URL/harbor/projects  (project $VENDOR, robot ${robot[0]})"
echo "  Namespaces   : $VENDOR-dev, $VENDOR-prod"
echo "  Argo CD      : https://$ARGOCD_HOST  (project $VENDOR, Keycloak group cicd-$VENDOR)"
echo "Next: ./add-app.sh $VENDOR <app> <java-gradle|java-maven|php|node|vue>"
