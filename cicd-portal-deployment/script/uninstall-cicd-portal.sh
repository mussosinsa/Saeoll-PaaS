#!/bin/bash
# Remove CI/CD portal components and their Keycloak clients.
#   ./uninstall-cicd-portal.sh scm      Jenkins (jobs, credentials, build history)
#   ./uninstall-cicd-portal.sh gitlab   GitLab CE (all repositories and data) + Runner
#   ./uninstall-cicd-portal.sh console  CI/CD web console only (vendors, applications and data are kept)
#   ./uninstall-cicd-portal.sh security security policy/rules, Presidio, DefectDojo settings (pipelines keep
#                                       scanning in report mode with the defaults built into the scanner image)
#   ./uninstall-cicd-portal.sh all      both sources + Argo CD (all applications) + console
# A source still used by a vendor is refused unless FORCE=1. Vendor namespaces (<vendor>-dev/prod),
# Harbor projects, SCM repositories and the K-PaaS components are kept.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || exit 1
# shellcheck source=lib.sh
source ./lib.sh
load_portal_vars

TARGET=${1:-}
case "$TARGET" in
  scm) REMOVE=(scm) ;;
  gitlab) REMOVE=(gitlab) ;;
  console) REMOVE=(console) ;;
  security) REMOVE=(security) ;;
  all) REMOVE=(scm gitlab argocd console security) ;;
  *) echo "Usage: $0 <scm|gitlab|console|security|all>" >&2; exit 2 ;;
esac

# Vendors that would lose their CI/source
users=""
for src in scm gitlab; do
  [[ " ${REMOVE[*]} " == *" $src "* ]] || continue
  for v in $(kubectl -n "$ARGOCD_NAMESPACE" get appprojects.argoproj.io -o name 2>/dev/null | sed 's|.*/||'); do
    [[ "$v" == default ]] && continue
    [[ "$(vendor_source "$v")" == "$src" ]] && users+=" $v($src)"
  done
done
if [[ -n "$users" && "$TARGET" != all && "${FORCE:-0}" != 1 ]]; then
  die "Vendors still use this source:$users. Migrate them (./migrate-vendor.sh) or set FORCE=1."
fi

echo "This deletes:"
[[ " ${REMOVE[*]} " == *" scm "* ]] && echo "  - Jenkins (jobs, credentials, build history), Keycloak client $KEYCLOAK_JENKINS_CLIENT_ID"
[[ " ${REMOVE[*]} " == *" gitlab "* ]] && echo "  - GitLab (ALL repositories and data PVCs), runner, Keycloak client $KEYCLOAK_GITLAB_CLIENT_ID"
[[ " ${REMOVE[*]} " == *" argocd "* ]] && echo "  - Argo CD (all applications), Keycloak client $KEYCLOAK_ARGOCD_CLIENT_ID"
[[ " ${REMOVE[*]} " == *" console "* ]] && echo "  - CI/CD console (namespace $CONSOLE_NAMESPACE), Keycloak client $KEYCLOAK_CONSOLE_CLIENT_ID"
[[ " ${REMOVE[*]} " == *" security "* ]] && echo "  - Security policy/rules ConfigMaps (exceptions included), Presidio (namespace $SECURITY_NAMESPACE)"
[[ -n "$users" ]] && echo "  Vendors affected:$users"
read -r -p "Type '$TARGET' to confirm: " answer
[[ "$answer" == "$TARGET" ]] || { echo "Cancelled."; exit 0; }

remove_namespace() {
  local ns=$1 pvs
  pvs=$(kubectl get pvc -n "$ns" -o jsonpath='{.items[*].spec.volumeName}' 2>/dev/null)
  kubectl delete namespace "$ns" --ignore-not-found
  [[ -n "$pvs" ]] && kubectl delete pv $pvs --ignore-not-found
}

if [[ " ${REMOVE[*]} " == *" security "* ]]; then
  for ns in "$JENKINS_NAMESPACE" "$RUNNER_NAMESPACE"; do
    # the pull secret stays: existing Jenkinsfiles still start the scanner container
    kubectl -n "$ns" delete configmap cicd-security-policy cicd-security-rules --ignore-not-found 2>/dev/null
    kubectl -n "$ns" delete secret cicd-security-defectdojo --ignore-not-found 2>/dev/null
  done
  kubectl delete namespace "$SECURITY_NAMESPACE" --ignore-not-found
fi
if [[ " ${REMOVE[*]} " == *" console "* ]]; then
  kubectl delete namespace "$CONSOLE_NAMESPACE" --ignore-not-found
  kubectl delete clusterrolebinding,clusterrole cicd-console --ignore-not-found
  kubectl -n mariadb delete rolebinding,role cicd-console-mariadb --ignore-not-found 2>/dev/null
  $API kc-delete-client "$KEYCLOAK_CONSOLE_CLIENT_ID"
fi
if [[ " ${REMOVE[*]} " == *" argocd "* ]]; then
  # Applications first so their finalizers do not block the namespace
  kubectl -n "$ARGOCD_NAMESPACE" delete applications.argoproj.io --all --wait=false 2>/dev/null
  helm uninstall argocd -n "$ARGOCD_NAMESPACE" 2>/dev/null
  remove_namespace "$ARGOCD_NAMESPACE"
  $API kc-delete-client "$KEYCLOAK_ARGOCD_CLIENT_ID"
fi
if [[ " ${REMOVE[*]} " == *" scm "* ]]; then
  helm uninstall jenkins -n "$JENKINS_NAMESPACE" 2>/dev/null
  remove_namespace "$JENKINS_NAMESPACE"
  $API kc-delete-client "$KEYCLOAK_JENKINS_CLIENT_ID"
fi
if [[ " ${REMOVE[*]} " == *" gitlab "* ]]; then
  helm uninstall gitlab-runner -n "$RUNNER_NAMESPACE" 2>/dev/null
  remove_namespace "$RUNNER_NAMESPACE"
  remove_namespace "$GITLAB_NAMESPACE"
  $API kc-delete-client "$KEYCLOAK_GITLAB_CLIENT_ID"
fi
[[ "$TARGET" == all ]] && rm -rf ../values
echo
echo "Removed: ${REMOVE[*]}. Kept: Keycloak groups and users, vendor namespaces, Harbor projects, SCM repositories."
[[ "$TARGET" != console && "$TARGET" != security ]] && echo "Remove '${TARGET/all/scm gitlab}' from CICD_SOURCES in cicd-vars.sh (or the environment)."
echo "With an NFS StorageClass (Retain) clean the deleted volumes on the NFS server manually."
