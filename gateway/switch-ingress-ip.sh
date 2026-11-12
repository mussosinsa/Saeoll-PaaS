#!/bin/bash
# Move the public address from ingress-nginx to the Istio ingress gateway (or back) - MetalLB, same IP, so DNS and
# nip.io names stay as they are (docs/ingress-nginx-to-istio.md, 4).
#
# Usage: ./switch-ingress-ip.sh to-istio [--ip <address>] [--yes]   ingress-nginx gives up the address, the gateway takes it
#        ./switch-ingress-ip.sh to-nginx [--yes]                    rollback (from the backup in gateway/state/)
#        ./switch-ingress-ip.sh stop-nginx | start-nginx           ingress-nginx replicas 0 / back (keep it stopped
#                                                                   a week or two before uninstalling it)
# The address is free for a few seconds in between: requests fail for about a minute. Before: ingress-to-istio.sh
# --apply and --verify --ip <temporary gateway IP>.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

CMD=${1:-}; shift || true
IP="" YES=0
while (($#)); do
  case "$1" in
    --ip) IP=${2:-}; shift ;;
    --yes) YES=1 ;;
    *) die "unknown option $1" ;;
  esac
  shift
done
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
NGINX_BACKUP="$STATE_DIR/ingress-nginx-service.json"
GW_BACKUP="$STATE_DIR/istio-gateway-annotation.txt"

confirm() { # what
  ((YES)) && return 0
  local a
  read -rp "  $1 - 계속하려면 주소($IP)를 입력하세요: " a
  [[ "$a" == "$IP" ]] || die "취소했습니다."
}
wait_ip() { # namespace service ip
  for _ in $(seq 1 60); do
    [[ "$(lb_ip "$1" "$2")" == "$3" ]] && return 0
    sleep 2
  done
  return 1
}
metallb_check() {
  kubectl get ipaddresspools.metallb.io -A >/dev/null 2>&1 ||
    die "MetalLB not found: move the address with your load balancer, or change the DNS record *.<domain> to the gateway address instead"
}

case "$CMD" in
  to-istio)
    load_domain
    metallb_check
    kubectl -n "$ISTIO_NAMESPACE" get service "$ISTIO_GATEWAY_SERVICE" >/dev/null 2>&1 || die "run ./install-istio-gateway.sh first"
    kubectl get virtualservices.networking.istio.io -A -o name | grep -q . || die "no VirtualService yet: ./ingress-to-istio.sh --apply"
    kubectl -n "$ISTIO_NAMESPACE" get secret "$TLS_SECRET" >/dev/null 2>&1 || die "TLS secret $ISTIO_NAMESPACE/$TLS_SECRET missing: ./ingress-to-istio.sh --apply"
    IP=${IP:-$(lb_ip "$NGINX_NAMESPACE" "$NGINX_SERVICE")}
    IP=${IP:-${INGRESS_LB_IP:-}}
    [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "address unknown: --ip <address of *.$HOST_DOMAIN>"
    info "ingress-nginx $NGINX_NAMESPACE/$NGINX_SERVICE ($(lb_ip "$NGINX_NAMESPACE" "$NGINX_SERVICE")) -> gateway $ISTIO_NAMESPACE/$ISTIO_GATEWAY_SERVICE ($(lb_ip "$ISTIO_NAMESPACE" "$ISTIO_GATEWAY_SERVICE")) : $IP"
    confirm "모든 화면이 약 1분 끊깁니다"
    # backups for to-nginx
    kubectl -n "$NGINX_NAMESPACE" get service "$NGINX_SERVICE" -o json > "$NGINX_BACKUP" 2>/dev/null || warn "no ingress-nginx service to back up"
    kubectl -n "$ISTIO_NAMESPACE" get service "$ISTIO_GATEWAY_SERVICE" \
      -o jsonpath='{.metadata.annotations.metallb\.universe\.tf/loadBalancerIPs}' > "$GW_BACKUP" || true
    ok "backup: $STATE_DIR"
    # 1. ingress-nginx gives up the address (ClusterIP keeps it reachable inside the cluster for a rollback)
    if [[ -s "$NGINX_BACKUP" ]]; then
      python3 - "$NGINX_BACKUP" <<'PY' | kubectl replace -f - >/dev/null
import json, sys
s = json.load(open(sys.argv[1]))
for k in ("resourceVersion", "uid", "creationTimestamp", "managedFields"):
    s["metadata"].pop(k, None)
s.pop("status", None)
s["metadata"].setdefault("annotations", {}).pop("metallb.universe.tf/loadBalancerIPs", None)
spec = s["spec"]
spec["type"] = "ClusterIP"
for k in ("externalTrafficPolicy", "healthCheckNodePort", "allocateLoadBalancerNodePorts", "loadBalancerIP",
          "loadBalancerClass", "loadBalancerSourceRanges", "externalIPs"):
    spec.pop(k, None)
for p in spec.get("ports", []):
    p.pop("nodePort", None)
print(json.dumps(s))
PY
      ok "ingress-nginx: ClusterIP (address released)"
    fi
    sleep 3
    # 2. the gateway takes it
    kubectl -n "$ISTIO_NAMESPACE" annotate service "$ISTIO_GATEWAY_SERVICE" --overwrite "metallb.universe.tf/loadBalancerIPs=$IP" >/dev/null
    if ! wait_ip "$ISTIO_NAMESPACE" "$ISTIO_GATEWAY_SERVICE" "$IP"; then
      warn "the gateway did not get $IP - rolling back"
      "$0" to-nginx --yes
      exit 1
    fi
    ok "gateway $ISTIO_NAMESPACE/$ISTIO_GATEWAY_SERVICE: $IP"
    "$GW_DIR/ingress-to-istio.sh" --verify --ip "$IP" --quiet || warn "check the addresses above; rollback: $0 to-nginx"
    echo
    echo "Rollback (if needed): $0 to-nginx"
    echo "Later (after a week or two): $0 stop-nginx, then uninstall ingress-nginx"
    ;;
  to-nginx)
    [[ -s "$NGINX_BACKUP" ]] || die "no backup in $STATE_DIR (to-istio was not run here)"
    IP=$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(((s.get("status") or {}).get("loadBalancer") or {}).get("ingress", [{}])[0].get("ip", ""))' "$NGINX_BACKUP")
    [[ -n "$IP" ]] || IP=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["metadata"].get("annotations", {}).get("metallb.universe.tf/loadBalancerIPs", ""))' "$NGINX_BACKUP")
    confirm "ingress-nginx 로 되돌립니다"
    old=$(cat "$GW_BACKUP" 2>/dev/null || true)
    if [[ -n "$old" && "$old" != "$IP" ]]; then
      kubectl -n "$ISTIO_NAMESPACE" annotate service "$ISTIO_GATEWAY_SERVICE" --overwrite "metallb.universe.tf/loadBalancerIPs=$old" >/dev/null
    else
      kubectl -n "$ISTIO_NAMESPACE" annotate service "$ISTIO_GATEWAY_SERVICE" "metallb.universe.tf/loadBalancerIPs-" >/dev/null 2>&1 || true
    fi
    sleep 3
    kubectl -n "$NGINX_NAMESPACE" scale deployment "$NGINX_DEPLOYMENT" --replicas=1 >/dev/null 2>&1 || true
    python3 - "$NGINX_BACKUP" "$IP" <<'PY' | kubectl replace -f - >/dev/null
import json, sys
s = json.load(open(sys.argv[1]))
for k in ("resourceVersion", "uid", "creationTimestamp", "managedFields"):
    s["metadata"].pop(k, None)
s.pop("status", None)
if sys.argv[2]:                      # the same address again
    s["metadata"].setdefault("annotations", {})["metallb.universe.tf/loadBalancerIPs"] = sys.argv[2]
for p in s["spec"].get("ports", []):
    p.pop("nodePort", None)          # new node ports if the old ones were taken meanwhile
s["spec"].pop("healthCheckNodePort", None)
print(json.dumps(s))
PY
    wait_ip "$NGINX_NAMESPACE" "$NGINX_SERVICE" "$IP" && ok "ingress-nginx: $IP again" || die "ingress-nginx did not get $IP back: kubectl -n $NGINX_NAMESPACE describe service $NGINX_SERVICE"
    ;;
  stop-nginx)
    kubectl -n "$NGINX_NAMESPACE" scale deployment "$NGINX_DEPLOYMENT" --replicas=0 >/dev/null && ok "ingress-nginx stopped (replicas 0)"
    ;;
  start-nginx)
    kubectl -n "$NGINX_NAMESPACE" scale deployment "$NGINX_DEPLOYMENT" --replicas=1 >/dev/null && ok "ingress-nginx started"
    ;;
  *)
    echo "Usage: $0 to-istio [--ip <address>] [--yes] | to-nginx [--yes] | stop-nginx | start-nginx" >&2; exit 2 ;;
esac
