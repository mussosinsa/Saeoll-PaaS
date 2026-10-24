#!/bin/bash
# Remove the CI/CD portal (Jenkins or GitLab CE + Runner, Argo CD and their Keycloak clients).
# Vendor namespaces (<vendor>-dev/prod), Harbor projects, SCM repositories and the K-PaaS
# components are kept.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || exit 1
# shellcheck source=lib.sh
source ./lib.sh
load_portal_vars

if [[ "$CICD_SOURCE" == scm ]]; then
  CONFIRM=$JENKINS_HOST
  echo "This deletes Jenkins (jobs, credentials, build history), Argo CD and the Keycloak clients"
  echo "$KEYCLOAK_JENKINS_CLIENT_ID / $KEYCLOAK_ARGOCD_CLIENT_ID. SCM repositories are not touched."
else
  CONFIRM=$GITLAB_HOST
  echo "This deletes GitLab (all repositories and data PVCs), the runner, Argo CD and the"
  echo "Keycloak clients $KEYCLOAK_GITLAB_CLIENT_ID / $KEYCLOAK_ARGOCD_CLIENT_ID."
fi
read -r -p "Type the host ($CONFIRM) to confirm: " answer
[[ "$answer" == "$CONFIRM" ]] || { echo "Cancelled."; exit 0; }

# Argo CD applications first so their finalizers do not block the namespace
kubectl -n "$ARGOCD_NAMESPACE" delete applications.argoproj.io --all --wait=false 2>/dev/null
helm uninstall argocd -n "$ARGOCD_NAMESPACE" 2>/dev/null
if [[ "$CICD_SOURCE" == scm ]]; then
  helm uninstall jenkins -n "$JENKINS_NAMESPACE" 2>/dev/null
  REMOVE_NS=("$ARGOCD_NAMESPACE" "$JENKINS_NAMESPACE")
else
  helm uninstall gitlab-runner -n "$RUNNER_NAMESPACE" 2>/dev/null
  REMOVE_NS=("$ARGOCD_NAMESPACE" "$RUNNER_NAMESPACE" "$GITLAB_NAMESPACE")
fi
for ns in "${REMOVE_NS[@]}"; do
  PVS=$(kubectl get pvc -n "$ns" -o jsonpath='{.items[*].spec.volumeName}' 2>/dev/null)
  kubectl delete namespace "$ns" --ignore-not-found
  [[ -n "$PVS" ]] && kubectl delete pv $PVS --ignore-not-found
done
if [[ "$CICD_SOURCE" == scm ]]; then
  $API kc-delete-client "$KEYCLOAK_JENKINS_CLIENT_ID"
else
  $API kc-delete-client "$KEYCLOAK_GITLAB_CLIENT_ID"
fi
$API kc-delete-client "$KEYCLOAK_ARGOCD_CLIENT_ID"
rm -rf ../values
echo
echo "Removed. Kept: Keycloak groups ($KEYCLOAK_ADMIN_GROUP, cicd-<vendor>) and users jenkins-<vendor>,"
echo "vendor namespaces, Harbor projects, SCM repositories."
echo "With an NFS StorageClass (Retain) clean the GitLab data on the NFS server manually."
