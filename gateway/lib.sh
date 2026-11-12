# Common settings and helpers of the gateway scripts (ingress-nginx -> Istio ingress gateway). Source from gateway/.
# shellcheck shell=bash
GW_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$GW_DIR/.." && pwd)
PORTAL_DIR=${PORTAL_DIR:-"$REPO_DIR/cp-portal-deployment"}
PORTAL_VARS=${PORTAL_VARS:-"$PORTAL_DIR/script/cp-portal-vars.sh"}
CA_FILE=${CA_FILE:-"$PORTAL_DIR/certs/ca.crt"}

# Istio of this repository (applications/istio-<version>): Helm charts base, istiod, gateway
ISTIO_DIR=${ISTIO_DIR:-"$(ls -d "$REPO_DIR"/applications/istio-* 2>/dev/null | sort -V | tail -1)"}
ISTIO_NAMESPACE=${ISTIO_NAMESPACE:-istio-system}
ISTIO_HUB=${ISTIO_HUB:-""}                         # image registry of istiod / proxyv2 (closed network: Harbor mirror)
ISTIO_GATEWAY_SERVICE=${ISTIO_GATEWAY_SERVICE:-istio-ingressgateway}   # Deployment + LoadBalancer Service
ISTIO_GATEWAY=${ISTIO_GATEWAY:-"$ISTIO_NAMESPACE/cp-gateway"}       # Gateway every VirtualService binds to
GATEWAY_LOCAL_TRAFFIC=${GATEWAY_LOCAL_TRAFFIC:-true}                  # externalTrafficPolicy Local: client IPs kept
# ingress-nginx being replaced
NGINX_NAMESPACE=${NGINX_NAMESPACE:-ingress-nginx}
NGINX_SERVICE=${NGINX_SERVICE:-ingress-nginx-controller}
NGINX_DEPLOYMENT=${NGINX_DEPLOYMENT:-ingress-nginx-controller}
STATE_DIR=${STATE_DIR:-"$GW_DIR/state"}            # backups for the rollback (switch-ingress-ip.sh)

info() { echo "[INFO] $*"; }
ok() { echo "[OK]   $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

if ! command -v kubectl >/dev/null && [[ -x /var/lib/rancher/rke2/bin/kubectl ]]; then
  PATH="$PATH:/var/lib/rancher/rke2/bin"
  [[ -n "${KUBECONFIG:-}" || -f "$HOME/.kube/config" ]] || export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
fi

# HOST_DOMAIN and INGRESS_LB_IP of K-PaaS (cp-portal-vars.sh), unless set in the environment
load_domain() {
  if [[ -z "${HOST_DOMAIN:-}" && -f "$PORTAL_VARS" ]]; then
    HOST_DOMAIN=$(set +u; source "$PORTAL_VARS" >/dev/null 2>&1; echo "$HOST_DOMAIN")
    INGRESS_LB_IP=${INGRESS_LB_IP:-$(set +u; source "$PORTAL_VARS" >/dev/null 2>&1; echo "${INGRESS_LB_IP:-}")}
  fi
  [[ -n "${HOST_DOMAIN:-}" && "$HOST_DOMAIN" != *'{'* ]] || die "HOST_DOMAIN unknown: set it, or PORTAL_VARS=<cp-portal-vars.sh>"
  if [[ -z "${INGRESS_LB_IP:-}" && "$HOST_DOMAIN" =~ ^(([0-9]{1,3}\.){3}[0-9]{1,3})\.nip\.io$ ]]; then
    INGRESS_LB_IP=${BASH_REMATCH[1]}
  fi
  TLS_SECRET=${TLS_SECRET:-"$HOST_DOMAIN-tls"}
  TLS_SOURCE_NAMESPACE=${TLS_SOURCE_NAMESPACE:-cp-portal}
}

istio_api() {
  local served
  served=$(kubectl get crd virtualservices.networking.istio.io \
    -o jsonpath='{range .spec.versions[?(@.served==true)]}{.name}{" "}{end}' 2>/dev/null || true)
  if [[ " $served " == *" v1 "* ]]; then echo networking.istio.io/v1; else echo networking.istio.io/v1beta1; fi
}

lb_ip() { # namespace service
  kubectl -n "$1" get service "$2" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
}

# The wildcard certificate of K-PaaS (cp-portal/<domain>-tls) next to the gateway: an Istio Gateway reads its
# credentialName from its own namespace. Re-run after every certificate renewal (ingress-to-istio.sh --apply does).
sync_tls_secret() {
  local src
  src=$(kubectl -n "$TLS_SOURCE_NAMESPACE" get secret "$TLS_SECRET" -o json 2>/dev/null) || {
    warn "TLS secret $TLS_SOURCE_NAMESPACE/$TLS_SECRET not found - the Gateway needs it in $ISTIO_NAMESPACE"; return 1; }
  printf '%s' "$src" | python3 -c '
import json, sys
s = json.load(sys.stdin)
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": s["type"],
                  "metadata": {"name": s["metadata"]["name"], "namespace": sys.argv[1],
                               "labels": {"app.kubernetes.io/managed-by": "ingress-to-istio"},
                               "annotations": {"ingress-to-istio/copied-from": sys.argv[2]}},
                  "data": s["data"]}))' "$ISTIO_NAMESPACE" "$TLS_SOURCE_NAMESPACE/$TLS_SECRET" | kubectl apply -f - >/dev/null
  ok "TLS secret $ISTIO_NAMESPACE/$TLS_SECRET (copy of $TLS_SOURCE_NAMESPACE/$TLS_SECRET)"
}
