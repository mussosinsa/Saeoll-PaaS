#!/bin/bash
# Ingresses -> Istio VirtualServices on the Gateway (docs/ingress-nginx-to-istio.md, 3). Re-runnable: run it again
# after installing or upgrading something that creates Ingresses (K-PaaS charts keep making Ingresses).
#
# Usage: ./ingress-to-istio.sh [--apply] [--prune] [--verify] [--ip <gateway IP>] [--class nginx] [--namespace ns] [--quiet]
#   (none)     dry run: the routes per host + the report (unconverted nginx annotations); full manifest in
#              gateway/out/ingress-to-istio.json
#   --apply    TLS secret copied to istio-system, VirtualServices / DestinationRules applied
#   --prune    with --apply: VirtualServices / DestinationRules made by this tool whose Ingress is gone are deleted
#   --verify   every converted host through the gateway (curl --resolve <host>:443:<ip>): no 404 / 5xx
#   --ip       address for --verify (default: the gateway's LoadBalancer IP) - test before switching the IP
#   --class / --namespace   only these Ingresses (default: every Ingress)
# Hosts that already have a VirtualService not made by this tool (e.g. the CI/CD portal's) are left alone.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

APPLY=0 PRUNE=0 VERIFY=0 QUIET=0 IP="" FILTER=()
while (($#)); do
  case "$1" in
    --apply) APPLY=1 ;;
    --prune) PRUNE=1 ;;
    --verify) VERIFY=1 ;;
    --quiet) QUIET=1 ;;
    --ip) IP=${2:-}; shift ;;
    --class|--namespace) FILTER+=("$1" "${2:-}"); shift ;;
    *) echo "Usage: $0 [--apply] [--prune] [--verify] [--ip <gateway IP>] [--class c] [--namespace ns] [--quiet]" >&2; exit 2 ;;
  esac
  shift
done
command -v python3 >/dev/null || die "python3 is not installed"
kubectl get crd virtualservices.networking.istio.io >/dev/null 2>&1 || die "Istio is not installed (./install-istio-gateway.sh)"
load_domain
OUT_DIR="$GW_DIR/out"; mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/ingress-to-istio.json"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
kubectl get ingress -A -o json > "$tmp/ing.json"
kubectl get services -A -o json > "$tmp/svc.json"
kubectl get virtualservices.networking.istio.io -A -o json > "$tmp/vs.json" 2>/dev/null || echo '{"items":[]}' > "$tmp/vs.json"
python3 -c 'import json,sys; print(json.dumps({"ingresses": json.load(open(sys.argv[1])), "services": json.load(open(sys.argv[2])),
                                               "virtualservices": json.load(open(sys.argv[3]))}))' \
  "$tmp/ing.json" "$tmp/svc.json" "$tmp/vs.json" |
  python3 "$GW_DIR/ingress_to_istio.py" --gateway "$ISTIO_GATEWAY" --api "$(istio_api)" "${FILTER[@]}" > "$tmp/result.json"
python3 - "$tmp/result.json" "$OUT" "$QUIET" <<'PY'
import json, sys
res = json.load(open(sys.argv[1]))
json.dump({"apiVersion": "v1", "kind": "List", "items": res["objects"]}, open(sys.argv[2], "w"), indent=1)
quiet = sys.argv[3] == "1"
for o in res["objects"]:
    if quiet:
        break
    if o["kind"] != "VirtualService":
        print(f"  DestinationRule {o['metadata']['namespace']}/{o['metadata']['name']}: {json.dumps(o['spec']['trafficPolicy'])}")
        continue
    print(f"  {o['spec']['hosts'][0]}  ({o['metadata']['namespace']}/{o['metadata']['name']}, from {o['metadata']['annotations']['ingress-to-istio/sources']})")
    for r in o["spec"]["http"]:
        m = " | ".join(f"{k} {v}" for x in r["match"] for k, v in x["uri"].items())
        if "redirect" in r:
            print(f"      {m:40s} -> redirect {r['redirect']['uri']}")
            continue
        d = r["route"][0]["destination"]
        rw = r.get("rewrite") or {}
        rw = f"  rewrite {rw.get('uri') or rw.get('uriRegexRewrite')}" if rw else ""
        to = f"  timeout {r['timeout']}" if "timeout" in r else ""
        print(f"      {m:40s} -> {d['host'].split('.svc')[0]}:{(d.get('port') or {}).get('number', '-')}{rw}{to}")
for line in res["report"]:
    print(line)
print(f"[INFO] {sum(o['kind'] == 'VirtualService' for o in res['objects'])} hosts, "
      f"{sum(o['kind'] == 'DestinationRule' for o in res['objects'])} DestinationRules -> {sys.argv[2]}")
PY
mapfile -t HOSTS < <(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["hosts"]))' "$tmp/result.json")

if ((APPLY)); then
  sync_tls_secret || warn "the Gateway cannot serve https without $ISTIO_NAMESPACE/$TLS_SECRET"
  if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["items"] else 1)' "$OUT"; then
    kubectl apply -f "$OUT" >/dev/null
    ok "applied: $OUT"
  fi
  if ((PRUNE)); then
    for kind in virtualservices.networking.istio.io destinationrules.networking.istio.io; do
      kubectl get "$kind" -A -l app.kubernetes.io/managed-by=ingress-to-istio \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' | while read -r ns name; do
        [[ -n "$name" ]] || continue
        python3 -c 'import json,sys; sys.exit(0 if any(o["metadata"]["namespace"] == sys.argv[2] and o["metadata"]["name"] == sys.argv[3]
                    and o["kind"].lower() + "s" == sys.argv[4].split(".")[0] for o in json.load(open(sys.argv[1]))["items"]) else 1)' \
          "$OUT" "$ns" "$name" "$kind" && continue
        kubectl -n "$ns" delete "$kind" "$name" >/dev/null && ok "pruned $kind $ns/$name (its Ingress is gone)"
      done
    done
  fi
fi

if ((VERIFY)); then
  IP=${IP:-$(lb_ip "$ISTIO_NAMESPACE" "$ISTIO_GATEWAY_SERVICE")}
  [[ -n "$IP" ]] || die "gateway address unknown: --ip <address>"
  cacert=(); [[ -s "$CA_FILE" ]] && cacert=(--cacert "$CA_FILE")
  info "Through the gateway $IP (curl --resolve <host>:443:$IP)"
  failed=0
  mapfile -t ALL < <({ printf '%s\n' "${HOSTS[@]}"
    kubectl get virtualservices.networking.istio.io -A -o jsonpath='{range .items[*]}{.spec.hosts[0]}{"\n"}{end}' 2>/dev/null; } |
    sed '/^$/d' | grep -v '^\*' | sort -u)
  for h in "${ALL[@]}"; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${cacert[@]}" --resolve "$h:443:$IP" "https://$h/" || true)
    if [[ "$code" =~ ^(2|3)[0-9][0-9]$|^401$|^403$ ]]; then ok "https://$h/ -> $code"
    else warn "https://$h/ -> ${code:-no answer}"; failed=1; fi
  done
  ((failed == 0)) || die "some addresses do not answer through the gateway (404: no route; 503: service not ready; 000: TLS/certificate)"
  ok "all addresses answer through $IP"
fi
