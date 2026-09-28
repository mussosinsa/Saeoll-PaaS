#!/bin/bash
# Onboard a PHP maintenance vendor: isolated dev/prod namespaces, Harbor
# project + robot account, namespace-scoped deployer kubeconfigs.
#
# Usage: ./onboard-php-vendor.sh <vendor> [envs]
#   vendor : lowercase id, e.g. vendor-a  (namespaces <vendor>-dev, <vendor>-prod)
#   envs   : default "dev prod"
# Env overrides: QUOTA_CPU, QUOTA_MEMORY, QUOTA_PODS, TOKEN_DURATION
#
# Output (mode 600, not committed): ../vendors/<vendor>/
#   harbor-robot.env, kubeconfig-<env>, jenkins-credentials.txt
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
source cp-pipeline-vars.sh
PORTAL_VARS=${PORTAL_VARS:-"$SCRIPT_DIR/../../cp-portal-deployment/script/cp-portal-vars.sh"}
eval "$(sed -n '/^load_portal_vars()/,/^}/p' deploy-cp-pipeline.sh)"
load_portal_vars

VENDOR=${1:-}
ENVS=${2:-"dev prod"}
[[ "$VENDOR" =~ ^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$ ]] || {
  echo "Usage: $0 <vendor-id: lowercase letters, digits, '-'> [\"dev prod\"]" >&2
  exit 2
}

HARBOR_HOST=$(echo "$REPOSITORY_URL" | awk -F[/:] '{print $4}')
PULL_SECRET=harbor-regcred
SA=deployer
OUT_DIR="$SCRIPT_DIR/../vendors/$VENDOR"
umask 077
mkdir -p "$OUT_DIR"

harbor_api() {
  local method=$1 path=$2 data=${3:-}
  curl -k -sS -u "$REPOSITORY_USERNAME:$REPOSITORY_PASSWORD" \
    -H 'Content-Type: application/json' -X "$method" \
    ${data:+--data "$data"} -w '\n%{http_code}' "$REPOSITORY_URL/api/v2.0$path"
}

# 1. Harbor project and robot account -----------------------------------------
resp=$(harbor_api POST /projects "{\"project_name\":\"$VENDOR\",\"public\":false}")
case "${resp##*$'\n'}" in
  201) echo "[OK] Harbor project created: $VENDOR" ;;
  409) echo "[INFO] Harbor project exists: $VENDOR" ;;
  *) echo "[ERROR] Harbor project $VENDOR: ${resp%$'\n'*}" >&2; exit 1 ;;
esac

ROBOT_FILE="$OUT_DIR/harbor-robot.env"
if [[ -s "$ROBOT_FILE" ]]; then
  echo "[INFO] Reusing robot credentials in $ROBOT_FILE"
else
  resp=$(harbor_api POST /robots "{\"name\":\"ci\",\"description\":\"Jenkins CI for $VENDOR\",\"duration\":-1,\"level\":\"project\",\"permissions\":[{\"kind\":\"project\",\"namespace\":\"$VENDOR\",\"access\":[{\"resource\":\"repository\",\"action\":\"push\"},{\"resource\":\"repository\",\"action\":\"pull\"}]}]}")
  code=${resp##*$'\n'}
  body=${resp%$'\n'*}
  if [[ "$code" != "201" ]]; then
    echo "[ERROR] Cannot create Harbor robot account (HTTP $code): $body" >&2
    [[ "$code" == "409" ]] && echo "[ERROR] Delete robot 'ci' in Harbor project $VENDOR (Robot Accounts) and re-run." >&2
    exit 1
  fi
  printf '%s' "$body" | python3 -c '
import json, shlex, sys
d = json.load(sys.stdin)
print("HARBOR_ROBOT_USER=" + shlex.quote(d["name"]))
print("HARBOR_ROBOT_SECRET=" + shlex.quote(d["secret"]))' >"$ROBOT_FILE"
  echo "[OK] Harbor robot account created"
fi
# shellcheck disable=SC1090
source "$ROBOT_FILE"

# 2. Namespaces per environment ------------------------------------------------
CA=$(kubectl -n default get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' | base64 -w0)
for env in $ENVS; do
  ns="$VENDOR-$env"
  echo "[INFO] Preparing namespace $ns"
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "$ns" --overwrite cp.k-paas.org/vendor="$VENDOR" cp.k-paas.org/env="$env" >/dev/null

  kubectl apply -f - <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: vendor-quota
  namespace: $ns
spec:
  hard:
    requests.cpu: "${QUOTA_CPU:-4}"
    requests.memory: ${QUOTA_MEMORY:-8Gi}
    limits.memory: ${QUOTA_MEMORY:-8Gi}
    pods: "${QUOTA_PODS:-30}"
    persistentvolumeclaims: "10"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: vendor-defaults
  namespace: $ns
spec:
  limits:
  - type: Container
    default:
      memory: 256Mi
    defaultRequest:
      cpu: 50m
      memory: 64Mi
EOF

  kubectl -n "$ns" create secret docker-registry "$PULL_SECRET" \
    --docker-server="$HARBOR_HOST" --docker-username="$HARBOR_ROBOT_USER" \
    --docker-password="$HARBOR_ROBOT_SECRET" --dry-run=client -o yaml | kubectl apply -f -

  # Wildcard *.HOST_DOMAIN certificate generated for CP-Portal
  kubectl -n "$CP_PORTAL_NAMESPACE" get secret "$TLS_SECRET" -o json | python3 -c '
import json, sys
s = json.load(sys.stdin)
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": s["type"],
                  "metadata": {"name": s["metadata"]["name"], "namespace": sys.argv[1]},
                  "data": s["data"]}))' "$ns" | kubectl apply -f -

  kubectl -n "$ns" create serviceaccount "$SA" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$ns" create rolebinding "$SA-edit" --clusterrole=edit \
    --serviceaccount="$ns:$SA" --dry-run=client -o yaml | kubectl apply -f -

  token=$(kubectl -n "$ns" create token "$SA" --duration="${TOKEN_DURATION:-8760h}")
  cat >"$OUT_DIR/kubeconfig-$env" <<EOF
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
    token: $token
contexts:
- name: $SA@$ns
  context:
    cluster: in-cluster
    user: $SA
    namespace: $ns
current-context: $SA@$ns
EOF
done

# 3. Summary for Jenkins ---------------------------------------------------------
{
  echo "Jenkins folder: $VENDOR   (Manage Jenkins > Credentials > Folder '$VENDOR')"
  echo
  echo "ID                       Kind                    Value"
  echo "$VENDOR-harbor-robot     Username with password  $HARBOR_ROBOT_USER / (HARBOR_ROBOT_SECRET in harbor-robot.env)"
  for env in $ENVS; do
    printf '%-24s Secret file             %s\n' "$VENDOR-kubeconfig-$env" "$OUT_DIR/kubeconfig-$env"
  done
  echo "$VENDOR-scm               Username with password  SCM read-only account for Jenkins (jenkins-$VENDOR)"
  echo
  echo "Harbor project : $HARBOR_HOST/$VENDOR"
  for env in $ENVS; do echo "Namespace      : $VENDOR-$env"; done
} >"$OUT_DIR/jenkins-credentials.txt"

echo
cat "$OUT_DIR/jenkins-credentials.txt"
echo
echo "[OK] Vendor $VENDOR onboarded. Files: $OUT_DIR (delete after registering them in Jenkins)"
