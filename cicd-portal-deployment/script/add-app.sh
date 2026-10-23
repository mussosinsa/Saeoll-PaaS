#!/bin/bash
# Add an application to an onboarded vendor.
#
# Usage: ./add-app.sh <vendor> <app> <type> [health-path]
#   type        : java-gradle | java-maven | php | node | vue
#   health-path : readiness/liveness path (default: /healthz.php for php, /healthz otherwise)
#
# Creates (idempotent; existing files are never overwritten):
#   GitLab project <vendor>/<app> with the starter source (main + develop), tag v* protected
#   gitops <vendor>/gitops: apps/<app>/base + overlays/dev,prod
#   Argo CD Applications <vendor>-<app>-dev (auto sync) and <vendor>-<app>-prod (manual sync)
# For an existing source repository set SKIP_STARTER=1 and add the include from
# ../starters/<type>/.gitlab-ci.yml, a Dockerfile listening on 8080 and the health path.
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
load_gitlab_token
require_cmds kubectl python3

PROJECT="$VENDOR/$APP"
GITOPS_URL="$GITLAB_INTERNAL_URL/$VENDOR/gitops.git"
IMAGE_REPO="$HARBOR_HOST/$VENDOR/$APP"
SUBST=(--subst APP="$APP" --subst VENDOR="$VENDOR" --subst HOST_DOMAIN="$HOST_DOMAIN"
       --subst IMAGE_REPO="$IMAGE_REPO" --subst HEALTH_PATH="$HEALTH_PATH" --subst TLS_SECRET="$TLS_SECRET")

kubectl -n "$ARGOCD_NAMESPACE" get appproject "$VENDOR" >/dev/null 2>&1 || \
  die "Vendor $VENDOR is not onboarded. Run ./onboard-vendor.sh $VENDOR first."

# 1. Source project --------------------------------------------------------------------
state=$($API gl-project "$VENDOR" "$APP" --visibility private)
if [[ "${SKIP_STARTER:-0}" != 1 ]]; then
  $API gl-push-dir "$PROJECT" "../starters/$TYPE" --only-missing "${SUBST[@]}" \
    --message "Add $TYPE starter (cicd-portal)"
fi
$API gl-protect-tag "$PROJECT" 'v*'
[[ "$state" == created ]] && ok "Source project: $GITLAB_URL/$PROJECT" || info "Source project exists: $GITLAB_URL/$PROJECT"

# 2. GitOps manifests (kept if already present: CI owns the image tags) ---------------
$API gl-push-dir "$VENDOR/gitops" ../gitops-template --prefix "apps/$APP" --only-missing "${SUBST[@]}" \
  --message "Add $APP manifests (cicd-portal)"

# develop last: creating it starts the first dev pipeline, which needs the manifests
$API gl-branch "$PROJECT" develop --ref main

# 3. Argo CD applications -----------------------------------------------------------------
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

echo
echo "Application $PROJECT ($TYPE) ready."
echo "  Source   : $GITLAB_URL/$PROJECT   (develop -> dev, tag vX.Y.Z -> prod)"
echo "  Pipeline : $GITLAB_URL/$PROJECT/-/pipelines"
echo "  Dev URL  : https://$APP-$VENDOR-dev.$HOST_DOMAIN"
echo "  Prod URL : https://$APP-$VENDOR.$HOST_DOMAIN   (after Argo CD sync of $VENDOR-$APP-prod)"
echo "  Argo CD  : https://$ARGOCD_HOST/applications?labels=cicd.k-paas.org%2Fvendor%3D$VENDOR"
echo "The dev application stays Degraded until the first develop pipeline pushes an image."
