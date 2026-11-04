#!/bin/bash
# Stop (서비스 중지) or start (재개) an application environment.
#
# Usage: ./app-state.sh <vendor> <app> <dev|prod|all> <stop|start>
#   stop  : gitops overlays/<env> replicas count 0 (the former count is kept in a comment), the Deployment is
#           scaled to 0 right away. Argo CD keeps it at 0 (dev auto sync; prod: the next prod Sync keeps 0).
#           The Argo CD application gets the label cicd.k-paas.org/stopped=true (+ who / when / why).
#   start : the former replicas count is restored in gitops and on the Deployment.
#   The image is not changed: prod restarts the version it ran (pending prod changes still need prod Sync).
#   A dedicated MariaDB keeps running (its data is not touched).
#   Autoscaled environments (자동 확장, scale-app.sh): the HPA is paused with replicas 0 and resumes at minReplicas.
# env: REASON (shown in the console), ACTOR (who), CI=disable|keep (default keep): stop/start also disables /
#      enables the Jenkins jobs of the app (scm vendors), STOPPED_BY_VENDOR=1 (used by vendor-state.sh)
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
# shellcheck source=lib.sh
source ./lib.sh

VENDOR=${1:-}
APP=${2:-}
ENV_ARG=${3:-}
ACTION=${4:-}
NAME_RE='^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$'
if [[ ! "$VENDOR" =~ $NAME_RE || ! "$APP" =~ $NAME_RE || ! "$ENV_ARG" =~ ^(dev|prod|all)$ || ! "$ACTION" =~ ^(stop|start)$ ]]; then
  echo "Usage: $0 <vendor> <app> <dev|prod|all> <stop|start>" >&2
  exit 2
fi
load_portal_vars
require_cmds kubectl python3 git
SOURCE=$(vendor_source "$VENDOR")
[[ -n "$SOURCE" ]] || die "Vendor $VENDOR is not onboarded."
NS_MODE=$(vendor_ns_mode "$VENDOR")
ENVS=()
for env in dev prod; do
  [[ "$ENV_ARG" == all || "$ENV_ARG" == "$env" ]] || continue
  if kubectl -n "$ARGOCD_NAMESPACE" get applications.argoproj.io "$VENDOR-$APP-$env" >/dev/null 2>&1; then
    ENVS+=("$env")
  else
    warn "Argo CD application $VENDOR-$APP-$env not found - skipped"
  fi
done
((${#ENVS[@]})) || die "Application $VENDOR/$APP ($ENV_ARG) not found."
REASON=${REASON:-}
ACTOR=${ACTOR:-cicd-admin}

# 1. gitops: replicas count of the application in overlays/<env> ------------------------------------------
gdir=$(gitops_clone "$VENDOR" "$SOURCE") || die "Cannot clone the gitops repository of $VENDOR."
declare -A COUNT
for env in "${ENVS[@]}"; do
  file="$gdir/apps/$APP/overlays/$env/kustomization.yaml"
  [[ -f "$file" ]] || die "gitops apps/$APP/overlays/$env/kustomization.yaml not found."
  if grep -q "# cicd-portal autoscale replicas" "$file"; then
    # autoscaled (HPA): replicas 0 stops it (an HPA does nothing at 0), start scales back to minReplicas
    COUNT[$env]=$(python3 autoscale_overlay.py "$ACTION" "$(dirname "$file")" "$APP") || die "autoscale overlay of $env"
    continue
  fi
  COUNT[$env]=$(python3 - "$file" "$APP" "$ACTION" <<'PY'
import re, sys
path, app, action = sys.argv[1:]
lines = open(path, encoding="utf-8").read().splitlines()
start = next((i for i, l in enumerate(lines) if re.match(r"^replicas:\s*$", l)), None)
item = None
if start is not None:
    for i in range(start + 1, len(lines)):
        if lines[i] and not lines[i][0].isspace():
            break
        if re.match(r"^\s*-\s*name:\s*" + re.escape(app) + r"\s*$", lines[i]):
            item = i
            break
count_line = None
if item is not None:
    for i in range(item + 1, min(item + 4, len(lines))):
        if re.match(r"^\s*count:", lines[i]):
            count_line = i
            break
if count_line is None:
    # overlays from before the replicas field: add it (count 1 = the base)
    block = ["replicas:", f"  - name: {app}", "    count: 1"]
    if start is None:
        res = next((i for i, l in enumerate(lines) if re.match(r"^resources:\s*$", l)), len(lines) - 1)
        lines[res:res] = block
        count_line = res + 2
    else:
        lines[start + 1:start + 1] = block[1:]
        count_line = start + 2
m = re.match(r"^(\s*)count:\s*(\d+)\s*(#.*)?$", lines[count_line])
indent, current, comment = m.group(1), int(m.group(2)), m.group(3) or ""
if action == "stop":
    was = current if current > 0 else int((re.search(r"was (\d+)", comment) or [0, 1])[1])
    lines[count_line] = f"{indent}count: 0  # stopped by the CI/CD portal (was {was})"
    result = 0
else:
    was = re.search(r"was (\d+)", comment)
    result = current if current > 0 else int(was.group(1)) if was else 1
    lines[count_line] = f"{indent}count: {result}"
open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print(result)
PY
)
done
envs_text="${ENVS[*]}"
msg="$([[ "$ACTION" == stop ]] && echo Stop || echo Start) $APP ($envs_text) by $ACTOR${REASON:+: $REASON}"
if scm_commit_push "$gdir" main "${msg:0:200} (cicd-portal)"; then
  ok "gitops apps/$APP: $(for env in "${ENVS[@]}"; do printf '%s replicas %s  ' "$env" "${COUNT[$env]}"; done)"
else
  info "gitops apps/$APP already $([[ "$ACTION" == stop ]] && echo stopped || echo running) ($envs_text)"
fi
gitops_cleanup "$gdir" "$SOURCE"

# 2. Deployment now, Argo CD application label --------------------------------------------------------------
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for env in "${ENVS[@]}"; do
  ns=$(env_namespace "$VENDOR" "$env" "$NS_MODE")
  dep=$(app_deployment "$env")
  if kubectl -n "$ns" get deployment "$dep" >/dev/null 2>&1; then
    kubectl -n "$ns" scale deployment "$dep" --replicas="${COUNT[$env]}" >/dev/null
    ok "Deployment $ns/$dep: replicas ${COUNT[$env]}"
  else
    info "Deployment $ns/$dep not deployed yet"
  fi
  app_obj="$VENDOR-$APP-$env"
  if [[ "$ACTION" == stop ]]; then
    kubectl -n "$ARGOCD_NAMESPACE" label applications.argoproj.io "$app_obj" --overwrite \
      cicd.k-paas.org/stopped=true >/dev/null
    REASON_JSON=$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "${REASON:0:300}")
    kubectl -n "$ARGOCD_NAMESPACE" patch applications.argoproj.io "$app_obj" --type merge -p \
      "{\"metadata\":{\"annotations\":{\"cicd.k-paas.org/stopped-by\":\"$ACTOR\",\"cicd.k-paas.org/stopped-at\":\"$now\",\"cicd.k-paas.org/stopped-reason\":$REASON_JSON,\"cicd.k-paas.org/stopped-by-vendor\":\"$([[ "${STOPPED_BY_VENDOR:-0}" == 1 ]] && echo true || echo false)\"}}}" >/dev/null
  else
    kubectl -n "$ARGOCD_NAMESPACE" label applications.argoproj.io "$app_obj" cicd.k-paas.org/stopped- >/dev/null 2>&1 || true
    kubectl -n "$ARGOCD_NAMESPACE" annotate applications.argoproj.io "$app_obj" cicd.k-paas.org/stopped-by- \
      cicd.k-paas.org/stopped-at- cicd.k-paas.org/stopped-reason- cicd.k-paas.org/stopped-by-vendor- >/dev/null 2>&1 || true
  fi
  kubectl -n "$ARGOCD_NAMESPACE" annotate applications.argoproj.io "$app_obj" --overwrite \
    argocd.argoproj.io/refresh=normal >/dev/null 2>&1 || true
  ok "Argo CD $app_obj: $([[ "$ACTION" == stop ]] && echo 중지됨 || echo 재개)"
done

# 3. CI jobs (optional) ---------------------------------------------------------------------------------------
if [[ "${CI:-keep}" == disable && "$SOURCE" == scm ]]; then
  load_jenkins_token
  state=$([[ "$ACTION" == stop ]] && echo disable || echo enable)
  $API jenkins-jobs "$VENDOR" "$state" --only "$APP-dev,$APP-release,$APP-deploy"
fi

echo
if [[ "$ACTION" == stop ]]; then
  echo "Application $VENDOR/$APP stopped ($envs_text). The address answers 503 until it is started again."
else
  echo "Application $VENDOR/$APP started ($envs_text)."
fi
