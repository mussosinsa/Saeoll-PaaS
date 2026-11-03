#!/bin/bash
# Suspend (업체 중지) or resume (재개) a vendor.
#
# Usage: ./vendor-state.sh <vendor> <suspend|resume>
#   suspend : every running application environment is stopped (./app-state.sh, marked "stopped by vendor"),
#             Jenkins jobs of the vendor folder disabled (scm), Harbor robots disabled (cicd, push, upload:
#             no image push or pull with them), Argo CD project: deny sync window (no sync, also not manual) and
#             label cicd.k-paas.org/suspended=true (the CI/CD console then lets vendor members only look).
#   resume  : the reverse; only the environments stopped by the suspension are started again
#             (an application stopped before stays stopped).
# env: REASON, ACTOR
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
# shellcheck source=lib.sh
source ./lib.sh

VENDOR=${1:-}
ACTION=${2:-}
NAME_RE='^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$'
if [[ ! "$VENDOR" =~ $NAME_RE || ! "$ACTION" =~ ^(suspend|resume)$ ]]; then
  echo "Usage: $0 <vendor> <suspend|resume>" >&2
  exit 2
fi
load_portal_vars
require_cmds kubectl python3 git
SOURCE=$(vendor_source "$VENDOR")
[[ -n "$SOURCE" ]] || die "Vendor $VENDOR is not onboarded."
ACTOR=${ACTOR:-cicd-admin}
export ACTOR REASON="${REASON:-}"
PROJECT=(-n "$ARGOCD_NAMESPACE" appprojects.argoproj.io "$VENDOR")

# Argo CD applications of the vendor: "<app> <env> <stopped label> <stopped by vendor>"
apps_of_vendor() {
  kubectl -n "$ARGOCD_NAMESPACE" get applications.argoproj.io -l "cicd.k-paas.org/vendor=$VENDOR" \
    -o jsonpath='{range .items[*]}{.metadata.labels.cicd\.k-paas\.org/app}{" "}{.metadata.labels.cicd\.k-paas\.org/env}{" "}{.metadata.labels.cicd\.k-paas\.org/stopped}{" "}{.metadata.annotations.cicd\.k-paas\.org/stopped-by-vendor}{"\n"}{end}'
}

if [[ "$ACTION" == suspend ]]; then
  # 1. applications (before the deny window: app-state.sh refreshes the applications)
  while read -r app env stopped _; do
    [[ -n "$app" ]] || continue
    if [[ "$stopped" == true ]]; then
      info "$VENDOR/$app $env already stopped (kept stopped on resume)"
    else
      STOPPED_BY_VENDOR=1 REASON="업체 중지${REASON:+: $REASON}" ./app-state.sh "$VENDOR" "$app" "$env" stop </dev/null
    fi
  done < <(apps_of_vendor)
  # 2. Argo CD project: deny every sync, mark suspended
  kubectl patch "${PROJECT[@]}" --type merge -p '{"spec":{"syncWindows":[{"kind":"deny","schedule":"* * * * *","duration":"24h","applications":["*"],"manualSync":false}]}}' >/dev/null
  kubectl label "${PROJECT[@]}" --overwrite cicd.k-paas.org/suspended=true >/dev/null
  REASON_JSON=$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "${REASON:0:300}")
  kubectl patch "${PROJECT[@]}" --type merge -p "{\"metadata\":{\"annotations\":{\"cicd.k-paas.org/suspended-by\":\"$ACTOR\",\"cicd.k-paas.org/suspended-at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"cicd.k-paas.org/suspended-reason\":$REASON_JSON}}}" >/dev/null
  ok "Argo CD project $VENDOR: suspended (deny sync window)"
  # 3. CI and registry
  if [[ "$SOURCE" == scm ]]; then
    load_jenkins_token
    $API jenkins-jobs "$VENDOR" disable
  else
    warn "GitLab pipelines of $VENDOR keep running; they cannot deploy (Argo CD deny window) or push (Harbor robot disabled)"
  fi
  $API harbor-robots "$VENDOR" disable
  echo
  echo "Vendor $VENDOR suspended. Vendor members can still sign in to the CI/CD console and look, but not build or deploy."
else
  kubectl patch "${PROJECT[@]}" --type json -p '[{"op":"remove","path":"/spec/syncWindows"}]' >/dev/null 2>&1 || true
  kubectl label "${PROJECT[@]}" cicd.k-paas.org/suspended- >/dev/null 2>&1 || true
  kubectl annotate "${PROJECT[@]}" cicd.k-paas.org/suspended-by- cicd.k-paas.org/suspended-at- \
    cicd.k-paas.org/suspended-reason- >/dev/null 2>&1 || true
  ok "Argo CD project $VENDOR: syncs allowed again"
  $API harbor-robots "$VENDOR" enable
  if [[ "$SOURCE" == scm ]]; then
    load_jenkins_token
    $API jenkins-jobs "$VENDOR" enable
  fi
  while read -r app env stopped by_vendor; do
    [[ -n "$app" && "$stopped" == true ]] || continue
    if [[ "$by_vendor" == true ]]; then
      ./app-state.sh "$VENDOR" "$app" "$env" start </dev/null
    else
      info "$VENDOR/$app $env was stopped before the suspension - kept stopped"
    fi
  done < <(apps_of_vendor)
  echo
  echo "Vendor $VENDOR resumed."
fi
