#!/bin/bash
# Istio ingress gateway in place of ingress-nginx (docs/ingress-nginx-to-istio.md, 2).
#
# Usage: ./install-istio-gateway.sh [--ip <LoadBalancer IP>]
#   1. istio-base + istiod (Helm charts of applications/istio-<version>) - skipped when istiod already runs
#   2. istio-ingressgateway: Deployment + LoadBalancer Service (externalTrafficPolicy Local; --ip: MetalLB address,
#      e.g. a temporary one while ingress-nginx still holds the real one; switch-ingress-ip.sh moves it later)
#   3. TLS secret <domain>-tls copied from cp-portal into istio-system
#   4. Gateway cp-gateway (ISTIO_GATEWAY): :80 redirect to https, :443 *.<domain> with the wildcard certificate.
#      An existing Gateway of that name is not changed (its hosts are shown).
# No sidecar injection: only the gateway is Istio; the applications stay as they are.
# Env: ISTIO_HUB (closed network: registry of istio/pilot and istio/proxyv2), ISTIO_DIR, GATEWAY_LOCAL_TRAFFIC=false
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

IP=""
while (($#)); do
  case "$1" in
    --ip) IP=${2:-}; shift 2 ;;
    *) echo "Usage: $0 [--ip <LoadBalancer IP>]" >&2; exit 2 ;;
  esac
done
[[ -z "$IP" || "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "--ip must be an IPv4 address"
for c in kubectl helm python3; do command -v "$c" >/dev/null || die "$c is not installed"; done
load_domain
[[ -d "$ISTIO_DIR/manifests/charts" ]] || die "Istio charts not found ($ISTIO_DIR/manifests/charts) - set ISTIO_DIR"
CHARTS="$ISTIO_DIR/manifests/charts"
VERSION=$(sed -n 's/^version: *//p' "$CHARTS/base/Chart.yaml" | head -1)
hub=(); [[ -n "$ISTIO_HUB" ]] && hub=(--set "global.hub=$ISTIO_HUB")

# 1. control plane ----------------------------------------------------------------------------------------------------
kubectl create namespace "$ISTIO_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if kubectl -n "$ISTIO_NAMESPACE" get deployment istiod >/dev/null 2>&1; then
  ok "istiod already installed ($(kubectl -n "$ISTIO_NAMESPACE" get deployment istiod -o jsonpath='{.spec.template.spec.containers[0].image}')) - kept"
else
  info "Istio $VERSION: istio-base, istiod"
  helm upgrade --install istio-base "$CHARTS/base" -n "$ISTIO_NAMESPACE" --set defaultRevision=default >/dev/null
  helm upgrade --install istiod "$CHARTS/istio-control/istio-discovery" -n "$ISTIO_NAMESPACE" "${hub[@]}" \
    --set "global.tag=$VERSION" --set meshConfig.accessLogFile=/dev/stdout --wait --timeout 10m >/dev/null
  ok "istiod $VERSION"
fi

# 2. ingress gateway --------------------------------------------------------------------------------------------------
if kubectl -n "$ISTIO_NAMESPACE" get service "$ISTIO_GATEWAY_SERVICE" >/dev/null 2>&1; then
  ok "Gateway service $ISTIO_NAMESPACE/$ISTIO_GATEWAY_SERVICE already installed - kept"
else
  values=$(mktemp)
  {
    echo "service:"
    echo "  type: LoadBalancer"
    [[ "$GATEWAY_LOCAL_TRAFFIC" == true ]] && echo "  externalTrafficPolicy: Local"
    [[ -n "$IP" ]] && printf '  annotations:\n    metallb.universe.tf/loadBalancerIPs: "%s"\n' "$IP"
    echo "podDisruptionBudget:"
    echo "  minAvailable: 1"
    echo "autoscaling:"
    echo "  minReplicas: 2"
  } > "$values"
  info "Gateway $ISTIO_GATEWAY_SERVICE (LoadBalancer${IP:+ $IP})"
  helm upgrade --install "$ISTIO_GATEWAY_SERVICE" "$CHARTS/gateway" -n "$ISTIO_NAMESPACE" -f "$values" \
    --wait --timeout 10m >/dev/null || { rm -f "$values"; die "Gateway installation failed: kubectl -n $ISTIO_NAMESPACE get pods"; }
  rm -f "$values"
fi
if [[ -n "$IP" && "$(lb_ip "$ISTIO_NAMESPACE" "$ISTIO_GATEWAY_SERVICE")" != "$IP" ]]; then
  kubectl -n "$ISTIO_NAMESPACE" annotate service "$ISTIO_GATEWAY_SERVICE" --overwrite "metallb.universe.tf/loadBalancerIPs=$IP" >/dev/null
fi
for _ in $(seq 1 60); do
  addr=$(lb_ip "$ISTIO_NAMESPACE" "$ISTIO_GATEWAY_SERVICE")
  [[ -n "$addr" && ( -z "$IP" || "$addr" == "$IP" ) ]] && break
  sleep 3
done
[[ -n "${addr:-}" ]] || die "No LoadBalancer address for $ISTIO_NAMESPACE/$ISTIO_GATEWAY_SERVICE (MetalLB pool? kubectl -n $ISTIO_NAMESPACE describe service $ISTIO_GATEWAY_SERVICE)"
[[ -z "$IP" || "$addr" == "$IP" ]] || die "$ISTIO_GATEWAY_SERVICE got $addr, not $IP (is $IP free and in a MetalLB IPAddressPool?)"
ok "Gateway address: $addr"

# 3. certificate ------------------------------------------------------------------------------------------------------
sync_tls_secret || true

# 4. Gateway ------------------------------------------------------------------------------------------------------------
gns=${ISTIO_GATEWAY%%/*} gname=${ISTIO_GATEWAY#*/}
if kubectl -n "$gns" get gateways.networking.istio.io "$gname" >/dev/null 2>&1; then
  ok "Gateway $ISTIO_GATEWAY exists - kept (hosts: $(kubectl -n "$gns" get gateways.networking.istio.io "$gname" -o jsonpath='{.spec.servers[*].hosts}'))"
else
  selector=$(kubectl -n "$ISTIO_NAMESPACE" get service "$ISTIO_GATEWAY_SERVICE" -o jsonpath='{.spec.selector.istio}')
  kubectl apply -f - >/dev/null <<EOF
apiVersion: $(istio_api)
kind: Gateway
metadata:
  name: $gname
  namespace: $gns
  labels:
    app.kubernetes.io/managed-by: ingress-to-istio
spec:
  selector:
    istio: ${selector:-ingressgateway}
  servers:
    - port: {number: 80, name: http, protocol: HTTP}
      hosts: ["*.$HOST_DOMAIN", "$HOST_DOMAIN"]
      tls: {httpsRedirect: true}
    - port: {number: 443, name: https, protocol: HTTPS}
      hosts: ["*.$HOST_DOMAIN", "$HOST_DOMAIN"]
      tls: {mode: SIMPLE, credentialName: $TLS_SECRET}
EOF
  ok "Gateway $ISTIO_GATEWAY: *.$HOST_DOMAIN (http -> https, certificate $TLS_SECRET)"
fi
echo
echo "Next: ./ingress-to-istio.sh            (VirtualServices from the Ingresses: dry run, then --apply)"
echo "      ./ingress-to-istio.sh --verify --ip $addr   (test every address through the gateway before switching)"
