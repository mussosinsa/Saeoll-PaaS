#!/bin/bash
# Add an application to an onboarded vendor.
#
# Usage: ./add-app.sh <vendor> <app> <type> [health-path]
#   type        : java-gradle | java-maven | php | node | vue
#   health-path : readiness/liveness path (default: /healthz.php for php, /healthz otherwise)
#
# The vendor's source (scm|gitlab) comes from onboard-vendor.sh (Argo CD project label).
# scm vendors (env SCM_ADMIN_PASSWORD), prepared in scm.<domain>:
#   Git repository <vendor>-<app> with jenkins-<vendor> as 참여자 (보기 권한) and the developers (쓰기 권한)
# Creates (idempotent; existing files are never overwritten):
#   source  : starter files on main + branch develop (scm: repository <vendor>-<app>;
#             gitlab: project <vendor>/<app> with protected tags v*). SKIP_STARTER=1 keeps your own source.
#   gitops  : apps/<app>/base + overlays/dev,prod
#   CI      : scm: Jenkins jobs <vendor>/<app>-dev (Poll SCM develop) and <vendor>/<app>-release (RELEASE_TAG)
#             gitlab: .gitlab-ci.yml from the starter
#   Argo CD : <vendor>-<app>-dev (auto sync), <vendor>-<app>-prod (manual sync)
# Your own repository needs a Dockerfile listening on 8080, the health path and the CI file
# (Jenkinsfile or .gitlab-ci.yml) from ../starters/<type>/.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
# shellcheck source=lib.sh
source ./lib.sh

VENDOR=${1:-}
APP=${2:-}
TYPE=${3:-}
NAME_RE='^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$'
if [[ ! "$VENDOR" =~ $NAME_RE || ! "$APP" =~ $NAME_RE || ! -d "../starters/$TYPE" || "$APP" == gitops ]]; then
  echo "Usage: $0 <vendor> <app> <java-gradle|java-maven|php|node|vue> [health-path]" >&2
  exit 2
fi
HEALTH_PATH=${4:-$([[ "$TYPE" == php ]] && echo /healthz.php || echo /healthz)}
load_portal_vars
require_cmds kubectl python3
SOURCE=$(vendor_source "$VENDOR")
[[ -n "$SOURCE" ]] || die "Vendor $VENDOR is not onboarded. Run ./onboard-vendor.sh --source <scm|gitlab> $VENDOR first."
has_source "$SOURCE" || die "Vendor $VENDOR uses '$SOURCE', which is not in CICD_SOURCES ($CICD_SOURCES)."
info "Vendor $VENDOR uses $SOURCE"
CI_USER="jenkins-$VENDOR"
IMAGE_REPO="$HARBOR_HOST/$VENDOR/$APP"

if [[ "$SOURCE" == scm ]]; then
  require_cmds git
  require_scm_admin
  load_jenkins_token
  SOURCE_REPO="$VENDOR-$APP"
  GITOPS_REPO="$VENDOR-gitops"
  GITOPS_URL="$SCM_INTERNAL_GIT_URL/$GITOPS_REPO"
else
  load_gitlab_token
  GITOPS_URL="$GITLAB_INTERNAL_URL/$VENDOR/gitops.git"
fi
SUBST=(APP="$APP" VENDOR="$VENDOR" HOST_DOMAIN="$HOST_DOMAIN" IMAGE_REPO="$IMAGE_REPO" HEALTH_PATH="$HEALTH_PATH"
       TLS_SECRET="$TLS_SECRET" HARBOR_HOST="$HARBOR_HOST" GITOPS_REPO_URL="$GITOPS_URL"
       BASE_REGISTRY="$CICD_BASE_REGISTRY" KANIKO_IMAGE="$KANIKO_IMAGE" CICD_DOCKERHUB="$CICD_DOCKERHUB")


if [[ "$SOURCE" == scm ]]; then
  # 1. SCM source repository (created in scm.<domain>) --------------------------------------
  $API scm-check "$SOURCE_REPO" --user "$CI_USER" --level READ || \
    die "Prepare '$SOURCE_REPO' in https://scm.$HOST_DOMAIN (Git, 참여자: $CI_USER 보기 권한, developers 쓰기 권한) and re-run."
  dir=$(scm_clone "$SOURCE_REPO")
  if [[ "${SKIP_STARTER:-0}" != 1 ]]; then
    added=$(render_tree "../starters/$TYPE" "$dir" --exclude .gitlab-ci.yml "${SUBST[@]}")
    if scm_commit_push "$dir" main "Add $TYPE starter (cicd-portal)"; then
      ok "SCM $SOURCE_REPO: $added starter file(s) pushed to main"
    else
      info "SCM $SOURCE_REPO: starter files already present"
    fi
  fi
  git -C "$dir" rev-parse -q --verify HEAD >/dev/null || die "SCM $SOURCE_REPO is empty (SKIP_STARTER=1): push your source to main first."
  [[ -f "$dir/Jenkinsfile" ]] || warn "SCM $SOURCE_REPO has no Jenkinsfile on main - copy ../starters/$TYPE/Jenkinsfile and adjust it"

  # 2. GitOps manifests (kept if already present: CI owns the image tags) -------------------
  gdir=$(scm_clone "$GITOPS_REPO")
  mkdir -p "$gdir/apps/$APP"
  render_tree ../gitops-template "$gdir/apps/$APP" "${SUBST[@]}" >/dev/null
  if scm_commit_push "$gdir" main "Add $APP manifests (cicd-portal)"; then
    ok "SCM $GITOPS_REPO: apps/$APP manifests pushed"
  else
    info "SCM $GITOPS_REPO: apps/$APP already present"
  fi
  scm_cleanup "$gdir"

  # 3. Jenkins jobs ------------------------------------------------------------------------------
  $API jenkins-job "$VENDOR" "$APP-dev" --repo-url "$SCM_INTERNAL_GIT_URL/$SOURCE_REPO" --credentials "$VENDOR-scm" \
    --description "$VENDOR/$APP: develop -> $VENDOR-dev (Argo CD auto sync). Source: https://scm.$HOST_DOMAIN ($SOURCE_REPO)"
  $API jenkins-job "$VENDOR" "$APP-release" --release --repo-url "$SCM_INTERNAL_GIT_URL/$SOURCE_REPO" --credentials "$VENDOR-scm" \
    --description "$VENDOR/$APP: RELEASE_TAG vX.Y.Z -> image + gitops prod (Argo CD sync by cicd-admins)"

  # develop last: it starts the first dev build, which needs the manifests and the job
  if GIT_TERMINAL_PROMPT=0 git -C "$dir" ls-remote --exit-code --heads origin develop >/dev/null 2>&1; then
    info "SCM $SOURCE_REPO: branch develop exists"
  else
    GIT_TERMINAL_PROMPT=0 git -C "$dir" push -q origin HEAD:refs/heads/develop
    ok "SCM $SOURCE_REPO: branch develop created"
  fi
  scm_cleanup "$dir"
else
  # 1. GitLab source project ----------------------------------------------------------------------
  PROJECT="$VENDOR/$APP"
  state=$($API gl-project "$VENDOR" "$APP" --visibility private)
  if [[ "${SKIP_STARTER:-0}" != 1 ]]; then
    gl_subst=()
    for kv in "${SUBST[@]}"; do gl_subst+=(--subst "$kv"); done
    $API gl-push-dir "$PROJECT" "../starters/$TYPE" --only-missing --exclude Jenkinsfile "${gl_subst[@]}" \
      --message "Add $TYPE starter (cicd-portal)"
  fi
  $API gl-protect-tag "$PROJECT" 'v*'
  [[ "$state" == created ]] && ok "Source project: $GITLAB_URL/$PROJECT" || info "Source project exists: $GITLAB_URL/$PROJECT"

  # 2. GitOps manifests (kept if already present: CI owns the image tags) ------------------------
  gl_subst=()
  for kv in "${SUBST[@]}"; do gl_subst+=(--subst "$kv"); done
  $API gl-push-dir "$VENDOR/gitops" ../gitops-template --prefix "apps/$APP" --only-missing "${gl_subst[@]}" \
    --message "Add $APP manifests (cicd-portal)"

  # develop last: creating it starts the first dev pipeline, which needs the manifests
  $API gl-branch "$PROJECT" develop --ref main
fi

# 4. Argo CD applications ---------------------------------------------------------------------------
for env in dev prod; do
  if [[ "$env" == dev ]]; then
    sync='  syncPolicy:
    automated:
      prune: true
      selfHeal: true'
  else
    sync='  syncPolicy: {}             # manual sync = production approval (cicd-admins)'
  fi
  kubectl apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $VENDOR-$APP-$env
  namespace: $ARGOCD_NAMESPACE
  labels:
    cicd.k-paas.org/vendor: $VENDOR
    cicd.k-paas.org/app: $APP
    cicd.k-paas.org/env: $env
    cicd.k-paas.org/type: $TYPE
spec:
  project: $VENDOR
  source:
    repoURL: $GITOPS_URL
    targetRevision: main
    path: apps/$APP/overlays/$env
  destination:
    server: https://kubernetes.default.svc
    namespace: $VENDOR-$env
$sync
EOF
  ok "Argo CD application $VENDOR-$APP-$env"
done

# Pipeline jobs need one build before Poll SCM starts watching develop
if [[ "$SOURCE" == scm ]]; then
  $API jenkins-build "$VENDOR" "$APP-dev"
fi

echo
echo "Application $VENDOR/$APP ($TYPE) ready."
if [[ "$SOURCE" == scm ]]; then
  echo "  Source   : https://scm.$HOST_DOMAIN  repository $SOURCE_REPO  (clone: $SCM_GIT_URL/$SOURCE_REPO)"
  echo "  Jenkins  : https://$JENKINS_HOST/job/$VENDOR/  ($APP-dev: develop, $APP-release: RELEASE_TAG=vX.Y.Z)"
else
  echo "  Source   : $GITLAB_URL/$VENDOR/$APP   (develop -> dev, tag vX.Y.Z -> prod)"
  echo "  Pipeline : $GITLAB_URL/$VENDOR/$APP/-/pipelines"
fi
echo "  Dev URL  : https://$APP-$VENDOR-dev.$HOST_DOMAIN"
echo "  Prod URL : https://$APP-$VENDOR.$HOST_DOMAIN   (after Argo CD sync of $VENDOR-$APP-prod)"
echo "  Argo CD  : https://$ARGOCD_HOST/applications?labels=cicd.k-paas.org%2Fvendor%3D$VENDOR"
echo "The dev application stays Degraded until the first develop build pushes an image."
