#!/bin/bash
# Delete a vendor (업체 삭제). Without --yes only the plan is printed (nothing is changed).
#
# Usage: ./remove-vendor.sh [--yes] [--with-apps] [--delete-data] [--delete-images] [--delete-repos]
#                           [--delete-users] [--users u1,u2] <vendor>
#   The vendor must have no applications, or --with-apps deletes them first (./remove-app.sh with the same
#   --delete-data / --delete-images; prod must be stopped: suspend the vendor first, ./vendor-state.sh <vendor> suspend).
#   always : Argo CD project <vendor> + gitops repository credentials, namespaces of the vendor, Jenkins folder
#            <vendor> (jobs, credentials; scm), Keycloak group cicd-<vendor>, security policy entries of <vendor>/*
#   --delete-data   : allowed to delete namespaces that still hold volumes (PVC: DB data). Without it the
#                     script stops when a vendor namespace has a PVC.
#   --delete-images : Harbor project <vendor> with all images and robots (default: kept, robots disabled)
#   --delete-repos  : scm: every SCM repository <vendor>-* (gitops and applications, also those of apps deleted
#                     before) except repositories of other vendors; gitlab: group <vendor> (default: kept)
#                     SCM_RESTART=1: restart SCM-Manager once when it cannot delete files still in use (NFS)
#   --delete-users  : accounts in Keycloak, SCM-Manager and the scm.<domain> DB: the CI account jenkins-<vendor>,
#                     the members of cicd-<vendor> and --users u1,u2 - except operators (cicd-admins), protected
#                     accounts and users that belong to another group (another vendor, a K-PaaS group).
#                     Default: kept (they are listed).
# A vendor whose Argo CD project is already gone (an earlier, interrupted deletion) is cleaned up the same way:
# what is left (namespaces labelled with the vendor, Jenkins folder, group, repositories, accounts) is deleted.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
# shellcheck source=lib.sh
source ./lib.sh

YES=0 WITH_APPS=0 DEL_DATA=0 DEL_IMAGES=0 DEL_REPOS=0 DEL_USERS=0 EXTRA_USERS=""
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --yes) YES=1 ;;
    --with-apps) WITH_APPS=1 ;;
    --delete-data) DEL_DATA=1 ;;
    --delete-images) DEL_IMAGES=1 ;;
    --delete-repos) DEL_REPOS=1 ;;
    --delete-users) DEL_USERS=1 ;;
    --users) EXTRA_USERS=${2:-}; shift ;;
    *) echo "Unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
VENDOR=${1:-}
NAME_RE='^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$'
if [[ ! "$VENDOR" =~ $NAME_RE || ! "$EXTRA_USERS" =~ ^[A-Za-z0-9._@,-]*$ ]]; then
  echo "Usage: $0 [--yes] [--with-apps] [--delete-data] [--delete-images] [--delete-repos] [--delete-users] [--users u1,u2] <vendor>" >&2
  exit 2
fi
load_portal_vars
require_cmds kubectl python3 git
LEFTOVER=0
if kubectl -n "$ARGOCD_NAMESPACE" get appprojects.argoproj.io "$VENDOR" >/dev/null 2>&1; then
  SOURCE=$(vendor_source "$VENDOR")
  NS_MODE=$(vendor_ns_mode "$VENDOR")
  CI_USER=$(vendor_ci_user "$VENDOR")
  if [[ "$NS_MODE" == single ]]; then NAMESPACES=("$VENDOR"); else NAMESPACES=("$VENDOR-dev" "$VENDOR-prod"); fi
else
  # interrupted deletion: clean up what is left
  LEFTOVER=1
  SOURCE=${SOURCE:-$(has_source scm && echo scm || echo gitlab)}
  NS_MODE=split
  CI_USER="jenkins-$VENDOR"
  mapfile -t NAMESPACES < <(kubectl get namespaces -l "cp.k-paas.org/vendor=$VENDOR" -o name 2>/dev/null | sed 's|.*/||')
  info "Argo CD project $VENDOR not found: cleaning up what is left of vendor $VENDOR ($SOURCE)"
fi
mapfile -t APPS < <(kubectl -n "$ARGOCD_NAMESPACE" get applications.argoproj.io -l "cicd.k-paas.org/vendor=$VENDOR" \
  -o jsonpath='{range .items[*]}{.metadata.labels.cicd\.k-paas\.org/app}{"\n"}{end}' | sort -u | sed '/^$/d')
[[ "$SOURCE" == scm ]] && { ((DEL_REPOS || DEL_USERS)) && require_scm_admin; }
[[ "$SOURCE" == gitlab ]] && ((DEL_REPOS)) && load_gitlab_token

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
# SCM repositories of the vendor: <vendor>-*, without those of other vendors (other projects' gitops,
# applications of other vendors, every repository of a vendor named <vendor>-...)
REPOS=()
if ((DEL_REPOS)) && [[ "$SOURCE" == scm ]]; then
  protect=()
  while read -r p; do
    [[ -n "$p" && "$p" != "$VENDOR" ]] || continue
    protect+=("$p-gitops")
    [[ "$p" == "$VENDOR-"* ]] && protect+=("$p-")
  done < <(kubectl -n "$ARGOCD_NAMESPACE" get appprojects.argoproj.io -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  while read -r v a; do
    [[ -n "$a" && "$v" != "$VENDOR" ]] && protect+=("$v-$a")
  done < <(kubectl -n "$ARGOCD_NAMESPACE" get applications.argoproj.io -l cicd.k-paas.org/vendor \
    -o jsonpath='{range .items[*]}{.metadata.labels.cicd\.k-paas\.org/vendor}{" "}{.metadata.labels.cicd\.k-paas\.org/app}{"\n"}{end}')
  mapfile -t REPOS < <(DATABASE_USER_PASSWORD="$DATABASE_USER_PASSWORD" $API scm-vendor-repos "$VENDOR" \
    --protect "$(IFS=,; echo "${protect[*]}")")
fi

PLAN=() KEEP=() TODO=()
((${#APPS[@]})) && PLAN+=("applications: ${APPS[*]} (./remove-app.sh each)")
((LEFTOVER)) || PLAN+=("Argo CD project $VENDOR and repository credentials repo-creds-$VENDOR-gitops")
((${#NAMESPACES[@]})) && PLAN+=("namespaces ${NAMESPACES[*]}${PVCS:+ with volumes ${PVCS[*]}}")
[[ "$SOURCE" == scm ]] && PLAN+=("Jenkins folder $VENDOR (jobs, build history, credentials)")
PLAN+=("Keycloak group cicd-$VENDOR")
PLAN+=("security policy entries of $VENDOR/*")
if ((DEL_IMAGES)); then PLAN+=("Harbor project $VENDOR (all images, robots)"); else KEEP+=("Harbor project $VENDOR (robots disabled)"); fi
if [[ "$SOURCE" == gitlab ]]; then
  if ((DEL_REPOS)); then PLAN+=("GitLab group $VENDOR (gitops and every project)"); else KEEP+=("GitLab group $VENDOR"); fi
elif ((DEL_REPOS)); then
  if ((${#REPOS[@]})); then PLAN+=("SCM repositories ${REPOS[*]}"); else info "No SCM repositories $VENDOR-* found"; fi
else
  KEEP+=("SCM repositories $VENDOR-gitops and $VENDOR-<app>")
fi
echo "Delete vendor $VENDOR ($SOURCE${NAMESPACES[*]:+, namespaces ${NAMESPACES[*]}}):"
printf '  - delete: %s\n' "${PLAN[@]}"
((${#KEEP[@]})) && printf '  - keep  : %s\n' "${KEEP[@]}"
if ((DEL_USERS)); then
  echo "Accounts:"
  DATABASE_USER_PASSWORD="$DATABASE_USER_PASSWORD" $API vendor-accounts "$VENDOR" --ci-user "$CI_USER" --extra "$EXTRA_USERS"
else
  echo "  - keep  : user accounts (CI account $CI_USER, members of cicd-$VENDOR) - --delete-users deletes them"
fi
if ((!YES)); then
  echo
  echo "Nothing changed (plan only). Run again with --yes to delete."
  exit 0
fi
echo

# 1. applications (their SCM repositories are deleted with the vendor's repositories, step 5) -----------------------
app_opts=(--yes)
((DEL_DATA)) && app_opts+=(--delete-data)
((DEL_IMAGES)) && app_opts+=(--delete-images)
for app in "${APPS[@]}"; do
  info "Deleting application $VENDOR/$app"
  rc=0
  SCM_REPO="$VENDOR-$app" ./remove-app.sh "${app_opts[@]}" "$VENDOR" "$app" </dev/null || rc=$?
  if ((rc == 3)); then
    TODO+=("$VENDOR/$app: a part was not deleted (see [TODO] above)")
  elif ((rc != 0)); then
    die "Deleting $VENDOR/$app failed (see above). Fix it and run this again."
  fi
done

# 2. Argo CD project, namespaces ------------------------------------------------------------------------------------------
if ((!LEFTOVER)); then
  kubectl -n "$ARGOCD_NAMESPACE" delete appprojects.argoproj.io "$VENDOR" --ignore-not-found >/dev/null
  ok "Argo CD project $VENDOR deleted"
fi
kubectl -n "$ARGOCD_NAMESPACE" delete secret "repo-creds-$VENDOR-gitops" --ignore-not-found --wait=false >/dev/null
for ns in "${NAMESPACES[@]}"; do
  kubectl delete namespace "$ns" --ignore-not-found --wait=false >/dev/null
  ok "Namespace $ns deleted (terminating in the background)"
done

# 3. CI, accounts, policy -----------------------------------------------------------------------------------------------
if [[ "$SOURCE" == scm ]]; then
  load_jenkins_token
  $API jenkins-delete "$VENDOR"
  # Keycloak password of the CI account kept by onboard-vendor.sh
  kubectl -n "$JENKINS_NAMESPACE" patch secret "$SECRET_NAME" --type json \
    -p "[{\"op\":\"remove\",\"path\":\"/data/kc-$CI_USER-password\"}]" >/dev/null 2>&1 || true
fi
if ((DEL_USERS)); then
  # before the group: the members are read from it
  DATABASE_USER_PASSWORD="$DATABASE_USER_PASSWORD" $API vendor-accounts "$VENDOR" --ci-user "$CI_USER" \
    --extra "$EXTRA_USERS" --yes >/dev/null
fi
members=$($API kc-delete-group "cicd-$VENDOR")
$API policy-forget "$VENDOR/"

# 4. registry ---------------------------------------------------------------------------------------------------------------
if ((DEL_IMAGES)); then
  $API harbor-delete-project "$VENDOR"
else
  $API harbor-robots "$VENDOR" disable 2>/dev/null || info "Harbor robots of $VENDOR not disabled (project not found?)"
fi

# 5. repositories -----------------------------------------------------------------------------------------------------------
if ((DEL_REPOS)); then
  if [[ "$SOURCE" == scm ]] && ((${#REPOS[@]})); then
    rc=0
    DATABASE_USER_PASSWORD="$DATABASE_USER_PASSWORD" $API scm-delete-repo "${REPOS[@]}" \
      $([[ "${SCM_RESTART:-0}" == 1 ]] && echo --restart) || rc=$?
    ((rc == 0)) || TODO+=("SCM repositories not deleted (see [TODO] above); run this again with SCM_RESTART=1 (콘솔: SCM-Manager 재시작 허용)")
    ((rc == 0 || rc == 3)) || die "Deleting SCM repositories failed."
  elif [[ "$SOURCE" == gitlab ]]; then
    $API gl-delete "$VENDOR" --group
  fi
fi

echo
echo "Vendor $VENDOR deleted."
((${#KEEP[@]})) && printf '  kept: %s\n' "${KEEP[@]}"
[[ -n "$members" ]] && ((!DEL_USERS)) && echo "  Keycloak accounts of the former members (not deleted): $members"
if ((${#TODO[@]})); then
  printf '[TODO] %s\n' "${TODO[@]}"
  exit 3
fi
exit 0
