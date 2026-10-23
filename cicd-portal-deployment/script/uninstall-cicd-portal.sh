#!/bin/bash
# Remove the CI/CD portal (GitLab CE, GitLab Runner, Argo CD and their Keycloak clients).
# Vendor namespaces (<vendor>-dev/prod), Harbor projects and the K-PaaS components are kept.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || exit 1
# shellcheck source=lib.sh
source ./lib.sh
load_portal_vars

echo "This deletes GitLab (all repositories and data PVCs), the runner, Argo CD and the"
echo "Keycloak clients $KEYCLOAK_GITLAB_CLIENT_ID / $KEYCLOAK_ARGOCD_CLIENT_ID."
read -r -p "Type the GitLab host ($GITLAB_HOST) to confirm: " answer
[[ "$answer" == "$GITLAB_HOST" ]] || { echo "Cancelled."; exit 0; }

# Argo CD applications first so their finalizers do not block the namespace
kubectl -n "$ARGOCD_NAMESPACE" delete applications.argoproj.io --all --wait=false 2>/dev/null
helm uninstall argocd -n "$ARGOCD_NAMESPACE" 2>/dev/null
helm uninstall gitlab-runner -n "$RUNNER_NAMESPACE" 2>/dev/null
for ns in "$ARGOCD_NAMESPACE" "$RUNNER_NAMESPACE" "$GITLAB_NAMESPACE"; do
  PVS=$(kubectl get pvc -n "$ns" -o jsonpath='{.items[*].spec.volumeName}' 2>/dev/null)
  kubectl delete namespace "$ns" --ignore-not-found
  [[ -n "$PVS" ]] && kubectl delete pv $PVS --ignore-not-found
done
$API kc-delete-client "$KEYCLOAK_GITLAB_CLIENT_ID"
$API kc-delete-client "$KEYCLOAK_ARGOCD_CLIENT_ID"
rm -rf ../values
echo
echo "Removed. Kept: Keycloak groups ($KEYCLOAK_ADMIN_GROUP, cicd-<vendor>), vendor namespaces, Harbor projects."
echo "With an NFS StorageClass (Retain) clean the GitLab data on the NFS server manually."
