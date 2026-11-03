#!/bin/bash
# Delete an application (앱 삭제). Without --yes only the plan is printed (nothing is changed).
#
# Usage: ./remove-app.sh [--yes] [--delete-data] [--delete-images] [--delete-repo] <vendor> <app>
#   always : Argo CD <vendor>-<app>-dev/prod and what they deployed (Deployment, Service, Ingress, MariaDB
#            StatefulSet: the applications get the resources finalizer before they are deleted),
#            gitops apps/<app>/ (a commit: the history keeps it), Jenkins jobs <app>-dev/-release/-deploy,
#            security policy entries (profile, exceptions) of <vendor>/<app>
#   --delete-data   : DB data and Secrets: dedicated MariaDB volume data-<app>-mariadb-0, shared database and
#                     user <vendor>_<app>_<env> on the K-PaaS MariaDB, Secrets <app>-db / <app>-mariadb-root
#                     (default: kept, so 앱 추가 + DB 연결 with the same names finds the data again)
#   --delete-images : Harbor repository <vendor>/<app>        (default: kept)
#   --delete-repo   : source repository (scm: SCM_REPO, default <vendor>-<app>, and its scm.<domain> entry;
#                     gitlab: project <vendor>/<app>)          (default: kept)
# prod must not be running: stop it first (./app-state.sh <vendor> <app> prod stop) or it was never deployed.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
# shellcheck source=lib.sh
source ./lib.sh

YES=0 DEL_DATA=0 DEL_IMAGES=0 DEL_REPO=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --yes) YES=1 ;;
    --delete-data) DEL_DATA=1 ;;
    --delete-images) DEL_IMAGES=1 ;;
    --delete-repo) DEL_REPO=1 ;;
    *) echo "Unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
VENDOR=${1:-}
APP=${2:-}
NAME_RE='^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$'
if [[ ! "$VENDOR" =~ $NAME_RE || ! "$APP" =~ $NAME_RE || "$APP" == gitops ]]; then
  echo "Usage: $0 [--yes] [--delete-data] [--delete-images] [--delete-repo] <vendor> <app>" >&2
  exit 2
fi
load_portal_vars
require_cmds kubectl python3 git
SOURCE=$(vendor_source "$VENDOR")
[[ -n "$SOURCE" ]] || die "Vendor $VENDOR is not onboarded."
NS_MODE=$(vendor_ns_mode "$VENDOR")
TYPE=$(kubectl -n "$ARGOCD_NAMESPACE" get applications.argoproj.io -l "cicd.k-paas.org/vendor=$VENDOR,cicd.k-paas.org/app=$APP" \
  -o jsonpath='{.items[0].metadata.labels.cicd\.k-paas\.org/type}' 2>/dev/null || true)
SCM_REPO=${SCM_REPO:-$VENDOR-$APP}

# prod running? (deployed, replicas > 0 and not stopped by the portal)
ENVS=()
for env in dev prod; do
  kubectl -n "$ARGOCD_NAMESPACE" get applications.argoproj.io "$VENDOR-$APP-$env" >/dev/null 2>&1 && ENVS+=("$env")
done
prod_ns=$(env_namespace "$VENDOR" prod "$NS_MODE")
prod_replicas=$(kubectl -n "$prod_ns" get deployment "$(app_deployment prod)" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
if [[ -n "$prod_replicas" && "$prod_replicas" != 0 ]]; then
  die "prod of $VENDOR/$APP is running ($prod_ns/$(app_deployment prod), replicas $prod_replicas). Stop it first: 서비스 중지 (prod) or ./app-state.sh $VENDOR $APP prod stop"
fi

# What exists (plan) ------------------------------------------------------------------------------------------
PLAN=() KEEP=() TODO=()
for env in "${ENVS[@]}"; do PLAN+=("Argo CD application $VENDOR-$APP-$env and its resources"); done
((${#ENVS[@]})) || info "No Argo CD applications for $VENDOR/$APP (already deleted?) - cleaning up the rest"
declare -A DBKIND
for env in dev prod; do
  env_names "$env"
  host=$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.DB_HOST}' 2>/dev/null | base64 -d 2>/dev/null || true)
  pvc=""
  kubectl -n "$NS" get pvc "data-$DB_POD" >/dev/null 2>&1 && pvc="data-$DB_POD"
  if [[ -n "$pvc" ]]; then DBKIND[$env]=dedicated
  elif [[ -n "$host" && "$host" == "${PLATFORM_DB_URL%%:*}" ]]; then DBKIND[$env]=shared
  elif [[ -n "$host" ]]; then DBKIND[$env]=external
  else continue
  fi
  case "${DBKIND[$env]}" in
    dedicated) what="$env DB: volume $NS/$pvc (dedicated MariaDB data) + Secrets $SECRET, $ROOT_SECRET" ;;
    shared) what="$env DB: database and user $(db_ident "${VENDOR}_${APP}_${env}") on the K-PaaS MariaDB + Secret $NS/$SECRET" ;;
    external) what="$env DB: Secret $NS/$SECRET (the external database itself is never touched)" ;;
  esac
  if ((DEL_DATA)); then PLAN+=("$what"); else KEEP+=("$what"); fi
done
PLAN+=("gitops apps/$APP/ (commit; recoverable from the git history)")
if [[ "$SOURCE" == scm ]]; then PLAN+=("Jenkins jobs $VENDOR/$APP-dev, $APP-release, $APP-deploy (build history)"); fi
PLAN+=("security policy entries of $VENDOR/$APP (profile, exceptions)")
if ((DEL_IMAGES)); then PLAN+=("Harbor repository $VENDOR/$APP (all images)"); else KEEP+=("Harbor repository $VENDOR/$APP"); fi
if [[ "$TYPE" != image ]]; then
  repo_name=$([[ "$SOURCE" == scm ]] && echo "SCM repository $SCM_REPO" || echo "GitLab project $VENDOR/$APP")
  if ((DEL_REPO)); then PLAN+=("$repo_name (source code)"); else KEEP+=("$repo_name"); fi
fi
echo "Delete application $VENDOR/$APP (${TYPE:-?}, ${SOURCE}):"
printf '  - delete: %s\n' "${PLAN[@]}"
((${#KEEP[@]})) && printf '  - keep  : %s\n' "${KEEP[@]}"
if ((!YES)); then
  echo
  echo "Nothing changed (plan only). Run again with --yes to delete."
  exit 0
fi
echo

# 1. Argo CD applications with their resources -------------------------------------------------------------
for env in "${ENVS[@]}"; do
  app_obj="$VENDOR-$APP-$env"
  # (kubectl warns about Argo CD's own finalizer name: not an error, kept out of the log)
  out=$(kubectl -n "$ARGOCD_NAMESPACE" patch applications.argoproj.io "$app_obj" --type merge \
    -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}' 2>&1) || die "$out"
  kubectl -n "$ARGOCD_NAMESPACE" delete applications.argoproj.io "$app_obj" --wait=false >/dev/null
done
for env in "${ENVS[@]}"; do
  app_obj="$VENDOR-$APP-$env"
  for _ in $(seq 1 60); do
    kubectl -n "$ARGOCD_NAMESPACE" get applications.argoproj.io "$app_obj" >/dev/null 2>&1 || break
    sleep 5
  done
  if kubectl -n "$ARGOCD_NAMESPACE" get applications.argoproj.io "$app_obj" >/dev/null 2>&1; then
    die "Argo CD application $app_obj is still being deleted after 5 minutes (Argo CD UI: $app_obj > events). Run this again later."
  fi
  ok "Argo CD application $app_obj and its resources deleted"
done

# 2. Database ---------------------------------------------------------------------------------------------------
if ((DEL_DATA)); then
  for env in dev prod; do
    [[ -n "${DBKIND[$env]:-}" ]] || continue
    env_names "$env"
    case "${DBKIND[$env]}" in
      dedicated)
        kubectl -n "$NS" delete pvc "data-$DB_POD" --ignore-not-found --wait=false >/dev/null
        ok "Volume $NS/data-$DB_POD deleted" ;;
      shared)
        name=$(db_ident "${VENDOR}_${APP}_${env}")
        platform_sql <<SQL || die "Cannot drop database $name on the K-PaaS MariaDB."
DROP DATABASE IF EXISTS \`$name\`;
DROP USER IF EXISTS '$name'@'%';
SQL
        ok "Database and user $name dropped on the K-PaaS MariaDB" ;;
    esac
    kubectl -n "$NS" delete secret "$SECRET" "$ROOT_SECRET" --ignore-not-found --wait=false >/dev/null
    ok "Secrets $NS/$SECRET deleted"
  done
fi

# 3. gitops -------------------------------------------------------------------------------------------------------
gdir=$(gitops_clone "$VENDOR" "$SOURCE") || die "Cannot clone the gitops repository of $VENDOR."
if [[ -d "$gdir/apps/$APP" ]]; then
  git -C "$gdir" rm -r -q "apps/$APP"
  scm_commit_push "$gdir" main "Remove $APP (cicd-portal, ${ACTOR:-cicd-admin}${REASON:+: ${REASON:0:150}})" || true
  ok "gitops apps/$APP removed"
else
  info "gitops apps/$APP not found"
fi
gitops_cleanup "$gdir" "$SOURCE"

# 4. CI ---------------------------------------------------------------------------------------------------------
if [[ "$SOURCE" == scm ]]; then
  load_jenkins_token
  for job in "$APP-dev" "$APP-release" "$APP-deploy"; do $API jenkins-delete "$VENDOR" "$job"; done
fi
$API policy-forget "$VENDOR/$APP"

# 5. Images and source (optional) --------------------------------------------------------------------------------
if ((DEL_IMAGES)); then $API harbor-delete-repo "$VENDOR" "$APP"; fi
if ((DEL_REPO)) && [[ "$TYPE" != image ]]; then
  if [[ "$SOURCE" == scm ]]; then
    require_scm_admin
    rc=0
    DATABASE_USER_PASSWORD="$DATABASE_USER_PASSWORD" $API scm-delete-repo "$SCM_REPO" || rc=$?
    ((rc == 0)) || TODO+=("SCM repository $SCM_REPO was not deleted (see [TODO] above): fix it, then ./remove-app.sh --yes --delete-repo $VENDOR $APP")
    ((rc == 0 || rc == 3)) || die "Deleting SCM repository $SCM_REPO failed."
  else
    load_gitlab_token
    $API gl-delete "$VENDOR/$APP"
  fi
fi

echo
echo "Application $VENDOR/$APP deleted."
((${#KEEP[@]})) && printf '  kept: %s\n' "${KEEP[@]}"
if ((${#TODO[@]})); then
  printf '[TODO] %s\n' "${TODO[@]}"
  exit 3
fi
exit 0
