#!/bin/bash
# Web address of existing applications in the current mode (CICD_EXPOSE, cicd-vars.sh): rewrites the gitops
# manifests of apps added before - Ingress (ingress-nginx) <-> Istio VirtualService (ISTIO_GATEWAY).
# New apps get the right kind from add-app.sh; run this once after switching a cluster to the Istio Gateway.
#
# Usage: ./app-expose.sh <vendor> [app ...]      (no app: every app of the vendor)
#   gitops apps/<app>/base: ingress.yaml -> virtualservice.yaml (or back), overlays/<env>: host patch replaced.
#   dev syncs automatically; prod changes with the next prod Sync (operators: console 'prod Sync' / Argo CD).
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
# shellcheck source=lib.sh
source ./lib.sh

VENDOR=${1:-}
NAME_RE='^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$'
[[ "$VENDOR" =~ $NAME_RE ]] || { echo "Usage: $0 <vendor> [app ...]" >&2; exit 2; }
shift
for a in "$@"; do [[ "$a" =~ $NAME_RE ]] || die "Invalid app name: $a"; done
load_portal_vars
require_cmds kubectl python3 git
SOURCE=$(vendor_source "$VENDOR")
[[ -n "$SOURCE" ]] || die "Vendor $VENDOR is not onboarded."
NS_MODE=$(vendor_ns_mode "$VENDOR")
EXPOSE=$(expose_mode)
KIND=ingress; FILE=ingress.yaml; OLD=virtualservice.yaml
[[ "$EXPOSE" == istio ]] && { KIND=virtualservice; FILE=virtualservice.yaml; OLD=ingress.yaml; }
info "Web addresses of $VENDOR: $([[ "$EXPOSE" == istio ]] && echo "Istio VirtualService ($ISTIO_GATEWAY)" || echo "Ingress ($INGRESS_CLASS_NAME)")"

gdir=$(gitops_clone "$VENDOR" "$SOURCE") || die "Cannot clone the gitops repository of $VENDOR."
trap 'gitops_cleanup "$gdir" "$SOURCE"' EXIT
APPS=("$@")
if ((${#APPS[@]} == 0)); then
  mapfile -t APPS < <(find "$gdir/apps" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
fi
((${#APPS[@]})) || die "No application in the gitops repository of $VENDOR."
tmp=$(mktemp -d)
changed=()
for APP in "${APPS[@]}"; do
  dir="$gdir/apps/$APP"
  [[ -f "$dir/base/kustomization.yaml" ]] || { warn "$APP: not in the gitops repository - skipped"; continue; }
  DEV_NS=$(env_namespace "$VENDOR" dev "$NS_MODE"); PROD_NS=$(env_namespace "$VENDOR" prod "$NS_MODE")
  expose_patch "$EXPOSE" "$APP" "$APP-$VENDOR-dev.$HOST_DOMAIN" "$(app_deployment dev).$DEV_NS.svc.cluster.local" > "$tmp/dev"
  expose_patch "$EXPOSE" "$APP" "$APP-$VENDOR.$HOST_DOMAIN" "$(app_deployment prod).$PROD_NS.svc.cluster.local" > "$tmp/prod"
  [[ -f "$dir/base/$FILE" ]] || render_file "../gitops-template/base/$FILE" "$dir/base/$FILE" APP="$APP" \
    TLS_SECRET="$TLS_SECRET" INGRESS_CLASS_NAME="$INGRESS_CLASS_NAME" ISTIO_GATEWAY="$ISTIO_GATEWAY" \
    ISTIO_API="$([[ "$EXPOSE" == istio ]] && istio_api || echo networking.istio.io/v1)"
  rm -f "$dir/base/$OLD"
  result=$(python3 expose_overlay.py convert "$dir" "$APP" "$KIND" "$tmp/dev" "$tmp/prod")
  if [[ "$result" == changed ]] || ! git -C "$gdir" diff --quiet -- "apps/$APP" || [[ -n "$(git -C "$gdir" status --porcelain -- "apps/$APP")" ]]; then
    changed+=("$APP"); ok "$APP: $FILE (https://$APP-$VENDOR-dev.$HOST_DOMAIN, https://$APP-$VENDOR.$HOST_DOMAIN)"
  else
    info "$APP: already $FILE"
  fi
done
rm -rf "$tmp"
((${#changed[@]})) || { ok "Nothing to change."; exit 0; }
if scm_commit_push "$gdir" main "Web address: $FILE for ${changed[*]} (cicd-portal app-expose.sh)"; then
  ok "gitops of $VENDOR pushed: ${changed[*]}"
  for APP in "${changed[@]}"; do
    kubectl -n "$ARGOCD_NAMESPACE" annotate applications.argoproj.io "$VENDOR-$APP-dev" \
      argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
  done
  echo "  dev : synced by Argo CD in a few minutes"
  echo "  prod: applied with the next prod Sync (console > app > prod Sync, operators)"
fi
