#!/bin/bash
# Move a vendor from the K-PaaS SCM (+ Jenkins) to GitLab (+ GitLab Runner). Argo CD keeps
# deploying the same namespaces; only the source of the manifests changes.
#
# Usage: [PM_USERS=pm1] ./migrate-vendor.sh <vendor> [user1,user2,...]
#   env SCM_ADMIN_PASSWORD (scmadmin) is required; both sources must be installed.
#
# Steps (re-runnable):
#   1. onboard the vendor on GitLab (group, gitops project, CI variables, Argo CD project -> gitlab)
#   2. copy the SCM gitops repository <vendor>-gitops (current image tags included) to GitLab <vendor>/gitops
#   3. mirror every app repository <vendor>-<app> (all branches and tags) to GitLab <vendor>/<app>
#   4. point the Argo CD applications to the GitLab gitops repository
#   5. add .gitlab-ci.yml to main and develop (the develop pipeline then builds and deploys dev)
#   6. disable the Jenkins jobs <vendor>/<app>-dev and -release (history is kept)
# SCM repositories are not changed or deleted; make them read-only in scm.<domain> afterwards.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
# shellcheck source=lib.sh
source ./lib.sh

VENDOR=${1:-}
USERS=${2:-}
[[ "$VENDOR" =~ ^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$ ]] || { echo "Usage: $0 <vendor> [user1,user2,...]" >&2; exit 2; }
load_portal_vars
require_cmds kubectl python3 git
has_source scm && has_source gitlab || die "Both sources must be installed (CICD_SOURCES=\"scm gitlab\")."
require_scm_admin
CURRENT=$(vendor_source "$VENDOR")
[[ -n "$CURRENT" ]] || die "Vendor $VENDOR is not onboarded."
[[ "$CURRENT" == scm ]] && info "Migrating $VENDOR: scm -> gitlab" || info "Vendor $VENDOR already uses $CURRENT - resuming the remaining steps"

GITOPS_URL="$GITLAB_INTERNAL_URL/$VENDOR/gitops.git"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Apps of the vendor: name and starter type from the Argo CD dev applications
mapfile -t APPS < <(kubectl -n "$ARGOCD_NAMESPACE" get applications.argoproj.io \
  -l "cicd.k-paas.org/vendor=$VENDOR,cicd.k-paas.org/env=dev" \
  -o jsonpath='{range .items[*]}{.metadata.labels.cicd\.k-paas\.org/app}{" "}{.metadata.labels.cicd\.k-paas\.org/type}{"\n"}{end}')
info "Apps: ${APPS[*]:-(none)}"

# 1. GitLab onboarding ------------------------------------------------------------------------
ALLOW_SOURCE_CHANGE=1 ./onboard-vendor.sh --source gitlab "$VENDOR" "$USERS"
load_gitlab_token
gitlab_git() { # git with the GitLab automation token, without putting it on the command line
  GIT_SSL_CAINFO=$CA_FILE GIT_TERMINAL_PROMPT=0 \
    git -c credential.helper='!f() { echo username=oauth2; echo "password=$GITLAB_TOKEN"; }; f' "$@"
}

# 2. GitOps repository --------------------------------------------------------------------------
gdir=$(scm_clone "$VENDOR-gitops")
$API gl-push-dir "$VENDOR/gitops" "$gdir" --message "Migrate $VENDOR-gitops from K-PaaS SCM"
scm_cleanup "$gdir"

# 3. App repositories (full history) -----------------------------------------------------------
declare -A TYPES=()
for entry in "${APPS[@]}"; do
  read -r app type <<<"$entry"
  [[ -n "$app" ]] || continue
  state=$($API gl-project "$VENDOR" "$app" --visibility private --empty)
  mirror="$WORK/$app.git"
  askpass="$WORK/askpass"
  printf '#!/bin/sh\ncase "$1" in Username*) echo "$SCM_ADMIN_USER";; *) echo "$SCM_ADMIN_PASSWORD";; esac\n' >"$askpass"
  chmod 700 "$askpass"
  GIT_ASKPASS=$askpass GIT_TERMINAL_PROMPT=0 GIT_SSL_CAINFO=$CA_FILE \
    git clone -q --mirror "$SCM_GIT_URL/$VENDOR-$app" "$mirror" || die "Cannot clone SCM $VENDOR-$app"
  if [[ -z "$type" ]]; then   # apps added before the type label existed
    if git -C "$mirror" cat-file -e main:build.gradle 2>/dev/null || git -C "$mirror" cat-file -e main:build.gradle.kts 2>/dev/null; then type=java-gradle
    elif git -C "$mirror" cat-file -e main:pom.xml 2>/dev/null; then type=java-maven
    elif git -C "$mirror" cat-file -e main:composer.json 2>/dev/null; then type=php
    elif git -C "$mirror" cat-file -e main:vite.config.js 2>/dev/null; then type=vue
    elif git -C "$mirror" cat-file -e main:package.json 2>/dev/null; then type=node
    else die "Cannot detect the type of $VENDOR-$app; label the Argo CD app: kubectl -n $ARGOCD_NAMESPACE label app $VENDOR-$app-dev cicd.k-paas.org/type=<type>"
    fi
  fi
  TYPES[$app]=$type
  if [[ "$state" == created ]] || ! gitlab_git ls-remote --exit-code --heads "$GITLAB_GIT_URL/$VENDOR/$app.git" main >/dev/null 2>&1; then
    gitlab_git -C "$mirror" push -q --mirror "$GITLAB_GIT_URL/$VENDOR/$app.git"
    ok "Mirrored SCM $VENDOR-$app -> GitLab $VENDOR/$app ($(git -C "$mirror" for-each-ref --format=x refs/heads | wc -l) branches, $(git -C "$mirror" for-each-ref --format=x refs/tags | wc -l) tags)"
  else
    info "GitLab $VENDOR/$app already has main - not overwritten"
  fi
  $API gl-default-branch "$VENDOR/$app" main
  $API gl-protect-tag "$VENDOR/$app" 'v*'
done

# 4. Argo CD applications -> GitLab gitops ----------------------------------------------------
for entry in "${APPS[@]}"; do
  read -r app _ <<<"$entry"
  [[ -n "$app" ]] || continue
  for env in dev prod; do
    kubectl -n "$ARGOCD_NAMESPACE" patch applications.argoproj.io "$VENDOR-$app-$env" --type merge \
      -p "{\"metadata\":{\"labels\":{\"cicd.k-paas.org/type\":\"${TYPES[$app]}\"}},\"spec\":{\"source\":{\"repoURL\":\"$GITOPS_URL\"}}}" >/dev/null
    ok "Argo CD $VENDOR-$app-$env -> $GITOPS_URL"
  done
done

# 5. GitLab CI file (only .gitlab-ci.yml; existing files are kept) ------------------------------
for entry in "${APPS[@]}"; do
  read -r app _ <<<"$entry"
  [[ -n "$app" ]] || continue
  ci="$WORK/ci-$app"
  mkdir -p "$ci"
  cp "../starters/${TYPES[$app]}/.gitlab-ci.yml" "$ci/"
  for branch in main develop; do
    if gitlab_git ls-remote --exit-code --heads "$GITLAB_GIT_URL/$VENDOR/$app.git" "$branch" >/dev/null 2>&1; then
      $API gl-push-dir "$VENDOR/$app" "$ci" --branch "$branch" --only-missing \
        --message "Add GitLab CI (migrated from K-PaaS SCM + Jenkins)"
    fi
  done
done

# 6. Jenkins jobs -------------------------------------------------------------------------------
if JENKINS_USER=${JENKINS_USER:-$(get_secret jenkins-user)} JENKINS_API_TOKEN=${JENKINS_API_TOKEN:-$(get_secret jenkins-api-token)} \
   && [[ -n "$JENKINS_API_TOKEN" ]]; then
  export JENKINS_USER JENKINS_API_TOKEN
  for entry in "${APPS[@]}"; do
    read -r app _ <<<"$entry"
    [[ -n "$app" ]] || continue
    $API jenkins-disable "$VENDOR" "$app-dev" || warn "Disable Jenkins job $VENDOR/$app-dev manually"
    $API jenkins-disable "$VENDOR" "$app-release" || warn "Disable Jenkins job $VENDOR/$app-release manually"
  done
else
  warn "No Jenkins API token - disable the Jenkins jobs in folder $VENDOR manually"
fi

echo
echo "Vendor $VENDOR now uses GitLab: $GITLAB_URL/$VENDOR"
echo "Remaining manual steps:"
echo "  - scm.$HOST_DOMAIN: remove the vendor's 참여자 (or keep read-only) on $VENDOR-* repositories"
echo "  - Vendor users: sign in to GitLab once, then re-run: PM_USERS=... $0 $VENDOR <users>  (adds memberships)"
echo "  - Vendor PCs: git remote set-url origin $GITLAB_URL/$VENDOR/<app>.git  (password = GitLab access token)"
echo "  - Check: Argo CD apps of $VENDOR are Synced/Healthy; the first develop pipeline deploys dev"
