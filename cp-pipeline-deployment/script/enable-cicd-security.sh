#!/bin/bash
# 품질 관리 (security scan of the CI/CD portal) for the K-PaaS cp-pipeline Jenkins (php-sample/Jenkinsfile).
#
# The Jenkinsfile reads, at run time and with the service account of the Jenkins pod, what the CI/CD console
# manages in the CI namespace of the portal (default cicd-jenkins):
#   ConfigMaps cicd-security-policy (gate, profiles, exceptions - 품질 관리 화면), cicd-security-rules
#   Secrets    cicd-security-pull (scanner image pull), cicd-security-defectdojo (optional upload), cicd-ca (K-PaaS CA)
# This grants exactly that read access (get on those names only). Re-runnable.
#
# Usage: ./enable-cicd-security.sh [apply|check|remove]     (default: apply, then check)
# Prerequisite: CI/CD portal security installed (cicd-portal-deployment: ./deploy-cicd-portal.sh security-image security)
# env SECURITY_NAMESPACE (default cicd-jenkins), JENKINS_DEPLOYMENT (default cp-pipeline-jenkins-deployment)
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
source cp-pipeline-vars.sh

ACTION=${1:-apply}
SECURITY_NAMESPACE=${SECURITY_NAMESPACE:-cicd-jenkins}
JENKINS_DEPLOYMENT=${JENKINS_DEPLOYMENT:-cp-pipeline-jenkins-deployment}
ROLE=cp-pipeline-security-read

info() { echo "[INFO] $*"; }
ok() { echo "[OK]   $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

kubectl get namespace "$SECURITY_NAMESPACE" >/dev/null 2>&1 || \
  die "Namespace $SECURITY_NAMESPACE not found: install the CI/CD portal (cicd-portal-deployment) first."
SA=$(kubectl -n "$NAMESPACE" get deployment "$JENKINS_DEPLOYMENT" -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true)
kubectl -n "$NAMESPACE" get deployment "$JENKINS_DEPLOYMENT" >/dev/null 2>&1 || \
  die "Deployment $NAMESPACE/$JENKINS_DEPLOYMENT not found (set JENKINS_DEPLOYMENT)."
SA=${SA:-default}

check() {
  local as="system:serviceaccount:$NAMESPACE:$SA" failed=0 obj
  for obj in configmap/cicd-security-policy configmap/cicd-security-rules secret/cicd-security-pull \
             secret/cicd-security-defectdojo secret/cicd-ca; do
    if [[ "$(kubectl auth can-i get "$obj" -n "$SECURITY_NAMESPACE" --as="$as" 2>/dev/null)" == yes ]]; then
      ok "$as can read $SECURITY_NAMESPACE/$obj"
    else
      warn "$as cannot read $SECURITY_NAMESPACE/$obj"; failed=1
    fi
  done
  kubectl -n "$SECURITY_NAMESPACE" get configmap cicd-security-policy >/dev/null 2>&1 || \
    warn "$SECURITY_NAMESPACE/cicd-security-policy does not exist yet: ./deploy-cicd-portal.sh security (cicd-portal-deployment)"
  kubectl -n "$SECURITY_NAMESPACE" get secret cicd-security-defectdojo >/dev/null 2>&1 || \
    info "DefectDojo is not configured: results stay in Jenkins (archived security/)"
  return $failed
}

case "$ACTION" in
  apply)
    kubectl apply -f - >/dev/null <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: $ROLE
  namespace: $SECURITY_NAMESPACE
  labels:
    app.kubernetes.io/part-of: cp-pipeline
rules:
  - apiGroups: [""]
    resources: [configmaps]
    resourceNames: [cicd-security-policy, cicd-security-rules]
    verbs: [get]
  - apiGroups: [""]
    resources: [secrets]
    resourceNames: [cicd-security-pull, cicd-security-defectdojo, cicd-ca]
    verbs: [get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: $ROLE
  namespace: $SECURITY_NAMESPACE
  labels:
    app.kubernetes.io/part-of: cp-pipeline
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: $ROLE
subjects:
  - kind: ServiceAccount
    name: $SA
    namespace: $NAMESPACE
YAML
    ok "Role/RoleBinding $SECURITY_NAMESPACE/$ROLE -> $NAMESPACE/$SA"
    check || die "Read access is not complete (see above)."
    echo
    echo "Pipelines from php-sample/Jenkinsfile now run 품질 관리 (SECURITY_SCAN=on, default)."
    echo "Policy, rules and exceptions: CI/CD console > 품질 관리 (profile 'php', app key <vendor>/<app>)."
    ;;
  check) check ;;
  remove)
    kubectl -n "$SECURITY_NAMESPACE" delete rolebinding,role "$ROLE" --ignore-not-found
    ok "Read access removed: the pipelines skip the security stages"
    ;;
  *) echo "Usage: $0 [apply|check|remove]" >&2; exit 2 ;;
esac
