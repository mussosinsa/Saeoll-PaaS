#!/bin/bash
# Delete a vendor (업체 삭제). Without --yes only the plan is printed (nothing is changed).
#
# Usage: ./remove-vendor.sh [--yes] [--with-apps] [--delete-data] [--delete-images] [--delete-repos] <vendor>
#   The vendor must have no applications, or --with-apps deletes them first (./remove-app.sh with the same
#   --delete-* options; prod must be stopped: suspend the vendor first, ./vendor-state.sh <vendor> suspend).
#   always : Argo CD project <vendor> + gitops repository credentials, namespaces <vendor>-dev/-prod (or
#            <vendor>), Jenkins folder <vendor> (jobs, credentials; scm), Keycloak group cicd-<vendor>
#            (the user accounts are kept and listed), security policy entries of <vendor>/*
#   --delete-data   : allowed to delete namespaces that still hold volumes (PVC: DB data). Without it the
#                     script stops when a vendor namespace has a PVC.
#   --delete-images : Harbor project <vendor> with all images and robots (default: kept, robots disabled)
#   --delete-repos  : gitops repository (scm <vendor>-gitops / GitLab group <vendor> with every project) and,
#                     with --with-apps, the application source repositories (default: kept)
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
# shellcheck source=lib.sh
source ./lib.sh

YES=0 WITH_APPS=0 DEL_DATA=0 DEL_IMAGES=0 DEL_REPOS=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --yes) YES=1 ;;
    --with-apps) WITH_APPS=1 ;;
    --delete-data) DEL_DATA=1 ;;
    --delete-images) DEL_IMAGES=1 ;;
    --delete-repos) DEL_REPOS=1 ;;
    *) echo "Unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
VENDOR=${1:-}
NAME_RE='^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$'
if [[ ! "$VENDOR" =~ $NAME_RE ]]; then
  echo "Usage: $0 [--yes] [--with-apps] [--delete-data] [--delete-images] [--delete-repos] <vendor>" >&2
  exit 2
fi
load_portal_vars
require_cmds kubectl python3 git
kubectl -n "$ARGOCD_NAMESPACE" get appprojects.argoproj.io "$VENDOR" >/dev/null 2>&1 || \
  die "Vendor $VENDOR is not onboarded (Argo CD project $VENDOR not found)."
SOURCE=$(vendor_source "$VENDOR")
NS_MODE=$(vendor_ns_mode "$VENDOR")
CI_USER=$(vendor_ci_user "$VENDOR")
if [[ "$NS_MODE" == single ]]; then NAMESPACES=("$VENDOR"); else NAMESPACES=("$VENDOR-dev" "$VENDOR-prod"); fi
mapfile -t APPS < <(kubectl -n "$ARGOCD_NAMESPACE" get applications.argoproj.io -l "cicd.k-paas.org/vendor=$VENDOR" \
  -o jsonpath='{range .items[*]}{.metadata.labels.cicd\.k-paas\.org/app}{"\n"}{end}' | sort -u | sed '/^$/d')

# Plan ------------------------------------------------------------------------------------------------------------
if ((${#APPS[@]})) && ((!WITH_APPS)); then
  die "Vendor $VENDOR still has applications: ${APPS[*]}. Delete them first (앱 삭제) or use --with-apps."
fi
RUNNING=()
prod_ns=$(env_namespace "$VENDOR" prod "$NS_MODE")
for app in "${APPS[@]}"; do
  dep=$([[ "$NS_MODE" == single ]] && echo "$app-prod" || echo "$app")
  replicas=$(kubectl -n "$prod_ns" get deployment "$dep" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
  [[ -n "$replicas" && "$replicas" != 0 ]] && RUNNING+=("$app")
done
if ((${#RUNNING[@]})); then
  die "prod is running for: ${RUNNING[*]}. Suspend the vendor first (업체 중지, ./vendor-state.sh $VENDOR suspend)."
fi
PVCS=()
for ns in "${NAMESPACES[@]}"; do
  while read -r pvc; do [[ -n "$pvc" ]] && PVCS+=("$ns/$pvc"); done < <(kubectl -n "$ns" get pvc -o name 2>/dev/null | sed 's|.*/||')
done
if ((${#PVCS[@]})) && ((!DEL_DATA)); then
  die "Namespaces of $VENDOR hold volumes (DB data): ${PVCS[*]}. Back them up and run with --delete-data, or keep the vendor."
fi
PLAN=() KEEP=()
((${#APPS[@]})) && PLAN+=("applications: ${APPS[*]} (./remove-app.sh each)")
PLAN+=("Argo CD project $VENDOR and repository credentials repo-creds-$VENDOR-gitops")
PLAN+=("namespaces ${NAMESPACES[*]}${PVCS:+ with volumes ${PVCS[*]}}")
[[ "$SOURCE" == scm ]] && PLAN+=("Jenkins folder $VENDOR (jobs, build history, credentials)")
PLAN+=("Keycloak group cicd-$VENDOR (user accounts are kept)")
PLAN+=("security policy entries of $VENDOR/*")
if ((DEL_IMAGES)); then PLAN+=("Harbor project $VENDOR (all images, robots)"); else KEEP+=("Harbor project $VENDOR (robots disabled)"); fi
gitops_name=$([[ "$SOURCE" == gitlab ]] && echo "GitLab group $VENDOR (gitops and every project)" || echo "SCM repository $VENDOR-gitops")
if ((DEL_REPOS)); then PLAN+=("$gitops_name"); else KEEP+=("$gitops_name"); fi
[[ "$SOURCE" == scm && -n "$CI_USER" ]] && KEEP+=("Keycloak / SCM account $CI_USER (CI account)")
echo "Delete vendor $VENDOR ($SOURCE, namespaces ${NAMESPACES[*]}):"
printf '  - delete: %s\n' "${PLAN[@]}"
((${#KEEP[@]})) && printf '  - keep  : %s\n' "${KEEP[@]}"
if ((!YES)); then
  echo
  echo "Nothing changed (plan only). Run again with --yes to delete."
  exit 0
fi
echo

# 1. applications ---------------------------------------------------------------------------------------------------
app_opts=(--yes)
((DEL_DATA)) && app_opts+=(--delete-data)
((DEL_IMAGES)) && app_opts+=(--delete-images)
((DEL_REPOS)) && app_opts+=(--delete-repo)
for app in "${APPS[@]}"; do
  info "Deleting application $VENDOR/$app"
  ./remove-app.sh "${app_opts[@]}" "$VENDOR" "$app" </dev/null || die "Deleting $VENDOR/$app failed (see above). Fix it and run this again."
done

# 2. Argo CD project, namespaces ------------------------------------------------------------------------------------------
kubectl -n "$ARGOCD_NAMESPACE" delete appprojects.argoproj.io "$VENDOR" --ignore-not-found >/dev/null
kubectl -n "$ARGOCD_NAMESPACE" delete secret "repo-creds-$VENDOR-gitops" --ignore-not-found >/dev/null
ok "Argo CD project $VENDOR deleted"
for ns in "${NAMESPACES[@]}"; do
  kubectl delete namespace "$ns" --ignore-not-found --wait=false >/dev/null
  ok "Namespace $ns deleted (terminating in the background)"
done

# 3. CI, accounts, policy -----------------------------------------------------------------------------------------------
if [[ "$SOURCE" == scm ]]; then
  load_jenkins_token
  $API jenkins-delete "$VENDOR"
  # Keycloak password of the CI account kept by onboard-vendor.sh (the account itself is kept)
  kubectl -n "$JENKINS_NAMESPACE" patch secret "$SECRET_NAME" --type json \
    -p "[{\"op\":\"remove\",\"path\":\"/data/kc-$CI_USER-password\"}]" >/dev/null 2>&1 || true
fi
members=$($API kc-delete-group "cicd-$VENDOR")
$API policy-forget "$VENDOR/"

# 4. registry and repositories ------------------------------------------------------------------------------------------
if ((DEL_IMAGES)); then
  $API harbor-delete-project "$VENDOR"
else
  $API harbor-robots "$VENDOR" disable || warn "Harbor robots of $VENDOR not disabled"
fi
if ((DEL_REPOS)); then
  if [[ "$SOURCE" == scm ]]; then
    require_scm_admin
    DATABASE_USER_PASSWORD="$DATABASE_USER_PASSWORD" $API scm-delete-repo "$VENDOR-gitops"
  elif [[ "$SOURCE" == gitlab ]]; then
    load_gitlab_token
    $API gl-delete "$VENDOR" --group
  fi
fi

echo
echo "Vendor $VENDOR deleted."
((${#KEEP[@]})) && printf '  kept: %s\n' "${KEEP[@]}"
[[ -n "$members" ]] && echo "  Keycloak accounts of the former members (not deleted): $members"
exit 0
