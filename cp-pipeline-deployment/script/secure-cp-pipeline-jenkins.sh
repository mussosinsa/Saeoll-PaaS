#!/bin/bash
# Restrict network access to the K-PaaS pipeline Jenkins (cp-pipeline-jenkins).
#
# Why: the K-PaaS image ships Jenkins 2.46.1 (2017) running privileged, with an admin user and a
# legacy API token baked into the image, and the cp-pipeline namespace is excluded from the K-PaaS
# Kyverno default NetworkPolicy - so every pod in the cluster can reach Jenkins on 8080/50000.
# The chart (cp-pipeline-jenkins 1.6.2) has no setting for the admin password.
#
# This adds a NetworkPolicy so only pods in the cp-pipeline namespace (pipeline API/UI) reach Jenkins.
# kubectl port-forward (administrators) keeps working. Re-runnable.
#
# Usage: ./secure-cp-pipeline-jenkins.sh [apply|check|remove]     (default: apply, then check)
#   env ALLOW_NAMESPACES="ns1 ns2" : also allow these namespaces (default: none)
#       CHECK_NAMESPACE=default    : namespace used for the "blocked" test pod
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
source cp-pipeline-vars.sh

ACTION=${1:-apply}
POLICY=cp-pipeline-jenkins-same-namespace
DEPLOY=cp-pipeline-jenkins-deployment
SERVICE=cp-pipeline-jenkins-service
CHECK_NAMESPACE=${CHECK_NAMESPACE:-default}
TEST_IMAGE=${TEST_IMAGE:-curlimages/curl:8.10.1}

info() { echo "[INFO] $*"; }
ok() { echo "[OK]   $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

# HTTP status of Jenkins /login from a short-lived pod in namespace $1 ("000" = blocked/timeout)
probe() {
  kubectl -n "$1" run "jenkins-netcheck-$RANDOM" --rm -i --restart=Never --quiet --image="$TEST_IMAGE" \
    --labels=app.kubernetes.io/part-of=jenkins-netcheck --command -- \
    curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$SERVICE.$NAMESPACE.svc.cluster.local:8080/login" 2>/dev/null || true
}

check() {
  info "Access check (HTTP status of /login; 000 = blocked)"
  local inside outside
  inside=$(probe "$NAMESPACE"); outside=$(probe "$CHECK_NAMESPACE")
  echo "       from $NAMESPACE (pipeline API): ${inside:-error}"
  echo "       from $CHECK_NAMESPACE (other namespaces): ${outside:-error}"
  [[ "$inside" =~ ^[1-5][0-9][0-9]$ ]] || die "Jenkins is not reachable from $NAMESPACE - check the policy and the Jenkins pod."
  if kubectl -n "$NAMESPACE" get networkpolicy "$POLICY" >/dev/null 2>&1; then
    [[ "$outside" == 000* || -z "$outside" ]] && ok "Jenkins is reachable only from $NAMESPACE" || \
      echo "[WARN] Jenkins is still reachable from $CHECK_NAMESPACE (CNI without NetworkPolicy support?)" >&2
  else
    [[ "$outside" == 000* ]] || echo "[WARN] No policy: Jenkins is reachable from every namespace" >&2
  fi
}

kubectl -n "$NAMESPACE" get deploy "$DEPLOY" >/dev/null 2>&1 || die "Deployment $DEPLOY not found in $NAMESPACE."

case "$ACTION" in
  apply)
    # Select the Jenkins pods with the deployment's own selector
    selector=$(kubectl -n "$NAMESPACE" get deploy "$DEPLOY" -o jsonpath='{.spec.selector.matchLabels}')
    [[ -n "$selector" ]] || die "Cannot read the pod selector of $DEPLOY."
    python3 - "$NAMESPACE" "$POLICY" "$selector" "${ALLOW_NAMESPACES:-}" <<'PY' | kubectl apply -f - >/dev/null
import json, sys
ns, name, selector, allow = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), sys.argv[4].split()
sources = [{"podSelector": {}}] + [
    {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": n}}} for n in allow]
print(json.dumps({
    "apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy",
    "metadata": {"name": name, "namespace": ns, "labels": {"app.kubernetes.io/managed-by": "secure-cp-pipeline-jenkins"}},
    "spec": {"podSelector": {"matchLabels": selector}, "policyTypes": ["Ingress"], "ingress": [{"from": sources}]},
}))
PY
    ok "NetworkPolicy $NAMESPACE/$POLICY (Jenkins pods $selector: ingress from $NAMESPACE${ALLOW_NAMESPACES:+ + $ALLOW_NAMESPACES})"
    check
    echo "Next: run a pipeline in https://pipeline.<domain> to confirm the pipeline API still reaches Jenkins."
    ;;
  check) check ;;
  remove)
    kubectl -n "$NAMESPACE" delete networkpolicy "$POLICY" --ignore-not-found
    ok "NetworkPolicy removed"
    ;;
  *) echo "Usage: $0 [apply|check|remove]" >&2; exit 2 ;;
esac
