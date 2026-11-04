#!/bin/bash
# Autoscaling (자동 확장, HPA) of an application environment.
#
# Usage: ./scale-app.sh <vendor> <app> <dev|prod> <on|off>
#   on : gitops apps/<app>/overlays/<env>: autoscale.yaml (HorizontalPodAutoscaler, PodDisruptionBudget when
#        min >= 2) + patches (no fixed replicas, CPU request, spread over nodes, optional sticky session cookie).
#        env MIN (2) MAX (6) CPU_TARGET (70 %) MEMORY_TARGET (0 = CPU only) CPU_REQUEST (200m) STICKY (0|1)
#        Re-run with other values to change them.
#   off: the fixed replica count from before is restored.
#   dev is synced by Argo CD automatically; prod needs the prod Sync of cicd-admins (like every prod change).
#   Checks: MAX x CPU_REQUEST and MAX pods must fit the vendor quota (vendor-quota of the namespace);
#   metrics-server must answer (kubectl top), otherwise the HPA cannot read the CPU usage.
# env: ACTOR, REASON
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
# shellcheck source=lib.sh
source ./lib.sh

VENDOR=${1:-}
APP=${2:-}
ENV_NAME=${3:-}
ACTION=${4:-}
NAME_RE='^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$'
if [[ ! "$VENDOR" =~ $NAME_RE || ! "$APP" =~ $NAME_RE || ! "$ENV_NAME" =~ ^(dev|prod)$ || ! "$ACTION" =~ ^(on|off)$ ]]; then
  echo "Usage: $0 <vendor> <app> <dev|prod> <on|off>" >&2
  exit 2
fi
MIN=${MIN:-2} MAX=${MAX:-6} CPU_TARGET=${CPU_TARGET:-70} MEMORY_TARGET=${MEMORY_TARGET:-0}
CPU_REQUEST=${CPU_REQUEST:-200m} STICKY=${STICKY:-0} ACTOR=${ACTOR:-cicd-admin}
for v in MIN MAX CPU_TARGET MEMORY_TARGET; do [[ "${!v}" =~ ^[0-9]{1,3}$ ]] || die "$v must be a number (got '${!v}')."; done
[[ "$CPU_REQUEST" =~ ^[0-9]+m$|^[0-9]+$ ]] || die "CPU_REQUEST must look like 200m or 1 (got '$CPU_REQUEST')."
load_portal_vars
require_cmds kubectl python3 git
SOURCE=$(vendor_source "$VENDOR")
[[ -n "$SOURCE" ]] || die "Vendor $VENDOR is not onboarded."
NS_MODE=$(vendor_ns_mode "$VENDOR")
APP_OBJ="$VENDOR-$APP-$ENV_NAME"
kubectl -n "$ARGOCD_NAMESPACE" get applications.argoproj.io "$APP_OBJ" >/dev/null 2>&1 || \
  die "Argo CD application $APP_OBJ not found."
NS=$(env_namespace "$VENDOR" "$ENV_NAME" "$NS_MODE")

millicores() { # 200m | 1 | 1.5 -> 200 | 1000 | 1500 (anything else: 0)
  if [[ "$1" =~ ^[0-9]+m$ ]]; then echo "${1%m}"
  elif [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then python3 -c 'import sys; print(int(float(sys.argv[1]) * 1000))' "$1"
  else echo 0; fi
}

if [[ "$ACTION" == on ]]; then
  ((MIN >= 1 && MIN <= MAX && MAX <= 50)) || die "1 <= MIN <= MAX <= 50 (got MIN=$MIN MAX=$MAX)."
  # quota: the most the HPA may create must fit the namespace quota
  hard_cpu=$(kubectl -n "$NS" get resourcequota vendor-quota -o jsonpath='{.status.hard.requests\.cpu}' 2>/dev/null || true)
  used_cpu=$(kubectl -n "$NS" get resourcequota vendor-quota -o jsonpath='{.status.used.requests\.cpu}' 2>/dev/null || true)
  hard_pods=$(kubectl -n "$NS" get resourcequota vendor-quota -o jsonpath='{.status.hard.pods}' 2>/dev/null || true)
  need=$(( MAX * $(millicores "$CPU_REQUEST") ))
  if [[ -n "$hard_cpu" ]]; then
    hard=$(millicores "$hard_cpu")
    ((need <= hard)) || die "MAX $MAX x CPU request $CPU_REQUEST = ${need}m exceeds the quota of $NS (requests.cpu $hard_cpu). Lower MAX / CPU_REQUEST or raise the vendor quota (QUOTA_CPU)."
    used=$(millicores "${used_cpu:-0}")
    ((need <= hard - used + 1000)) || warn "$NS uses ${used_cpu:-0} of $hard_cpu CPU requests: the HPA may not reach $MAX pods (pending pods). Check the other apps of $VENDOR."
  fi
  if [[ -n "$hard_pods" ]] && ((MAX > hard_pods)); then
    die "MAX $MAX exceeds the pod quota of $NS ($hard_pods)."
  fi
  kubectl top pods -n "$NS" >/dev/null 2>&1 || \
    warn "metrics-server does not answer (kubectl top): the HPA cannot read CPU usage until it does (cp-portal-deployment/script/install-metrics-server.sh)"
fi

gdir=$(gitops_clone "$VENDOR" "$SOURCE") || die "Cannot clone the gitops repository of $VENDOR."
overlay="$gdir/apps/$APP/overlays/$ENV_NAME"
[[ -f "$overlay/kustomization.yaml" ]] || die "gitops apps/$APP/overlays/$ENV_NAME not found."
stopped=$(kubectl -n "$ARGOCD_NAMESPACE" get applications.argoproj.io "$APP_OBJ" \
  -o jsonpath='{.metadata.labels.cicd\.k-paas\.org/stopped}' 2>/dev/null || true)
if [[ "$ACTION" == on ]]; then
  python3 autoscale_overlay.py enable "$overlay" "$APP" --min "$MIN" --max "$MAX" --cpu "$CPU_TARGET" \
    --memory "$MEMORY_TARGET" --cpu-request "$CPU_REQUEST" $([[ "$STICKY" == 1 ]] && echo --sticky) >/dev/null || \
    die "Cannot write the autoscaling of apps/$APP/overlays/$ENV_NAME."
  # a stopped environment stays stopped (서비스 재개 starts it at MIN)
  [[ "$stopped" == true ]] && python3 autoscale_overlay.py stop "$overlay" "$APP" >/dev/null
  msg="Autoscale $APP $ENV_NAME: $MIN-$MAX pods, CPU ${CPU_TARGET}% of $CPU_REQUEST"
  ((MEMORY_TARGET)) && msg+=", memory ${MEMORY_TARGET}%"
  [[ "$STICKY" == 1 ]] && msg+=", sticky session"
else
  grep -q "# cicd-portal autoscale begin" "$overlay/kustomization.yaml" || { info "Autoscaling of $APP $ENV_NAME is not on."; gitops_cleanup "$gdir" "$SOURCE"; exit 0; }
  kept=$(python3 autoscale_overlay.py disable "$overlay" "$APP") || die "Cannot remove the autoscaling of apps/$APP/overlays/$ENV_NAME."
  msg="Autoscale $APP $ENV_NAME off (replicas $kept)"
fi
if scm_commit_push "$gdir" main "$msg by $ACTOR${REASON:+: ${REASON:0:150}} (cicd-portal)"; then
  ok "gitops apps/$APP/overlays/$ENV_NAME: $msg"
else
  info "gitops apps/$APP/overlays/$ENV_NAME unchanged"
fi
gitops_cleanup "$gdir" "$SOURCE"
kubectl -n "$ARGOCD_NAMESPACE" annotate applications.argoproj.io "$APP_OBJ" --overwrite \
  argocd.argoproj.io/refresh=normal >/dev/null 2>&1 || true

echo
if [[ "$ENV_NAME" == prod ]]; then
  echo "prod: applied by the next prod Sync (CI/CD console > $VENDOR/$APP > prod Sync)."
else
  echo "dev: Argo CD $APP_OBJ syncs automatically (~3 min)."
fi
if [[ "$ACTION" == on ]]; then
  echo "Status after the sync: kubectl -n $NS get hpa   (TARGETS shows the CPU use; <unknown> = no metrics yet)"
  echo "The first sync sets the Deployment to 1 replica for a moment; the HPA raises it to $MIN right after."
fi
