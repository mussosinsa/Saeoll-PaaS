#!/bin/bash
# Prepare a target namespace for PHP apps deployed from Jenkins:
#   - namespace, Harbor project and imagePullSecret
#   - ServiceAccount limited to that namespace (ClusterRole "edit" via RoleBinding)
#   - kubeconfig file to register in Jenkins as a "Secret file" credential
# Usage: ./create-php-deployer.sh [namespace] [harbor-project]
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
source cp-pipeline-vars.sh
PORTAL_VARS=${PORTAL_VARS:-"$SCRIPT_DIR/../../cp-portal-deployment/script/cp-portal-vars.sh"}
eval "$(sed -n '/^load_portal_vars()/,/^}/p' deploy-cp-pipeline.sh)"
load_portal_vars

TARGET_NS=${1:-php-apps}
HARBOR_PROJECT=${2:-$TARGET_NS}
SA=php-deployer
PULL_SECRET=harbor-regcred
HARBOR_HOST=$(echo "$REPOSITORY_URL" | awk -F[/:] '{print $4}')
OUT=${OUT:-"$SCRIPT_DIR/../php-deployer-$TARGET_NS.kubeconfig"}

kubectl create namespace "$TARGET_NS" --dry-run=client -o yaml | kubectl apply -f -

code=$(curl -k -s -o /dev/null -w '%{http_code}' -u "$REPOSITORY_USERNAME:$REPOSITORY_PASSWORD" \
  -H 'Content-Type: application/json' -X POST "$REPOSITORY_URL/api/v2.0/projects" \
  --data "{\"project_name\":\"$HARBOR_PROJECT\",\"public\":false}")
case "$code" in
  201|409) echo "[OK] Harbor project: $HARBOR_PROJECT" ;;
  *) echo "[ERROR] Cannot create Harbor project $HARBOR_PROJECT (HTTP $code)" >&2; exit 1 ;;
esac

kubectl -n "$TARGET_NS" create secret docker-registry "$PULL_SECRET" \
  --docker-server="$HARBOR_HOST" --docker-username="$REPOSITORY_USERNAME" \
  --docker-password="$REPOSITORY_PASSWORD" --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$TARGET_NS" create serviceaccount "$SA" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$TARGET_NS" create rolebinding "$SA-edit" --clusterrole=edit \
  --serviceaccount="$TARGET_NS:$SA" --dry-run=client -o yaml | kubectl apply -f -

TOKEN=$(kubectl -n "$TARGET_NS" create token "$SA" --duration="${TOKEN_DURATION:-8760h}")
CA=$(kubectl -n "$TARGET_NS" get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' | base64 -w0)

umask 077
cat >"$OUT" <<KCFG
apiVersion: v1
kind: Config
clusters:
- name: in-cluster
  cluster:
    server: https://kubernetes.default.svc
    certificate-authority-data: $CA
users:
- name: $SA
  user:
    token: $TOKEN
contexts:
- name: $SA@$TARGET_NS
  context:
    cluster: in-cluster
    user: $SA
    namespace: $TARGET_NS
current-context: $SA@$TARGET_NS
KCFG

cat <<MSG
[OK] kubeconfig written: $OUT (mode 600, token valid for ${TOKEN_DURATION:-8760h})

Register in Jenkins (Manage Jenkins > Credentials > Global):
  - Secret file        ID: php-deployer-kubeconfig  <- $OUT
  - Username/Password  ID: harbor-credentials       <- Harbor account
Then delete the local kubeconfig file after uploading it.
MSG
