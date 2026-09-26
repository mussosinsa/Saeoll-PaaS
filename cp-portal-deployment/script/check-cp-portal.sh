#!/bin/bash
# Read-only diagnostics for a CP-Portal whose dashboard keeps loading or shows
# "-" for the host cluster. Run from cp-portal-deployment/script.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || exit 1
# shellcheck source=cp-portal-vars.sh
source ./cp-portal-vars.sh
OPENBAO_INIT_FILE=${OPENBAO_INIT_FILE:-../secmg/unseal-key}
# shellcheck source=../secmg_orig/openbao-common.sh
source ../secmg_orig/openbao-common.sh
OPENBAO_NAMESPACE=${NAMESPACE[0]}
OPENBAO_WAIT_ATTEMPTS=3

PORTAL_NS=${NAMESPACE[4]}
DB_NS=${NAMESPACE[1]}
FAILED=0

section() { printf '\n===== %s =====\n' "$*"; }
ok() { echo "[OK]   $*"; }
fail() { echo "[FAIL] $*"; FAILED=1; }
warn() { echo "[WARN] $*"; }

# 1. Pods ---------------------------------------------------------------------
section "1. Pod status"
for ns in "${NAMESPACE[0]}" "$DB_NS" "${NAMESPACE[3]}" "$PORTAL_NS"; do
  bad=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | \
    awk '{split($2,r,"/"); if ($3!="Completed" && ($3!="Running" || r[1]!=r[2] || $4+0>3)) print}')
  if [[ -n "$bad" ]]; then
    fail "namespace $ns has pods that are not healthy (not Ready or restarting):"
    echo "$bad" | sed 's/^/       /'
  else
    ok "namespace $ns pods are Running/Ready"
  fi
done

# 2. OpenBao seal state ---------------------------------------------------------
section "2. OpenBao seal state"
seal_json=$(kubectl -n "$OPENBAO_NAMESPACE" exec openbao-0 -c openbao -- \
  sh -c 'BAO_ADDR=http://127.0.0.1:8200 bao status -format=json' 2>/dev/null)
sealed=$(printf '%s' "$seal_json" | openbao_json_scalar sealed 2>/dev/null)
if [[ "$sealed" == "false" ]]; then
  ok "OpenBao is unsealed"
elif [[ "$sealed" == "true" ]]; then
  fail "OpenBao is SEALED (pod restarted?). The portal cannot read the cluster token."
  echo "       Fix: re-run unseal, e.g. ./deploy-cp-portal.sh or the curl commands in README."
else
  fail "Cannot read OpenBao status from openbao-0"
fi

# 3. Host cluster record in MariaDB -------------------------------------------
section "3. Host cluster in MariaDB (cp.cp_clusters)"
db_pod=$(kubectl -n "$DB_NS" get pods -l app.kubernetes.io/name=mariadb -o name 2>/dev/null | head -n 1)
cluster_rows=$(kubectl -n "$DB_NS" exec "${db_pod:-mariadb-0}" -- env MYSQL_PWD="$DATABASE_USER_PASSWORD" \
  sh -c 'c=$(command -v mariadb || command -v mysql); "$c" -uroot -N -e "SELECT cluster_id, name, cluster_type, provider_type, status FROM cp.cp_clusters"' 2>/dev/null)
if [[ -z "$cluster_rows" ]]; then
  fail "No rows read from cp.cp_clusters (DB not initialized or not reachable)"
else
  echo "$cluster_rows" | sed 's/^/       /'
fi
HOST_IDS=$(echo "$cluster_rows" | awk '$3=="host" {print $1}')

# 4. Cluster secret in OpenBao and token validity -----------------------------
section "4. Cluster credentials in OpenBao"
if [[ "$sealed" != "false" || ! -s "$OPENBAO_INIT_FILE" ]]; then
  warn "Skipped (OpenBao sealed or $OPENBAO_INIT_FILE missing)"
elif start_openbao_port_forward >/dev/null 2>&1; then
  ROOT_TOKEN=$(openbao_json_scalar root_token <"$OPENBAO_INIT_FILE")
  for id in $HOST_IDS; do
    secret=$(curl -s -H "X-Vault-Token: $ROOT_TOKEN" "$SECMG_URL/v1/secret/data/cluster/$id")
    api=$(printf '%s' "$secret" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("data",{}).get("data",{}).get("clusterApiUrl",""))' 2>/dev/null)
    token=$(printf '%s' "$secret" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("data",{}).get("data",{}).get("clusterToken",""))' 2>/dev/null)
    if [[ -z "$api" || -z "$token" ]]; then
      fail "secret/cluster/$id is missing in OpenBao (DB cluster_id and OpenBao secret do not match)"
      continue
    fi
    ok "secret/cluster/$id exists (clusterApiUrl=$api)"
    code=$(curl -k -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" "$api/api/v1/nodes?limit=1")
    case "$code" in
      200) ok "Cluster token works against $api (HTTP 200)" ;;
      401|403) fail "Cluster token rejected by $api (HTTP $code) - regenerate the token" ;;
      *) fail "Cannot reach $api from this host (HTTP ${code:-none}) - check VIP/HAProxy port" ;;
    esac
    # The API server must also be reachable from inside the pod network.
    echo "       Pod network check: kubectl -n $PORTAL_NS run apitest --rm -i --restart=Never --image=curlimages/curl -- curl -sk -o /dev/null -w '%{http_code}\\n' $api/version"
  done

  # 5. AppRole CIDR binding vs portal pod IPs ----------------------------------
  section "5. AppRole bound CIDRs vs CP-Portal pod IPs"
  role=$(curl -s -H "X-Vault-Token: $ROOT_TOKEN" "$SECMG_URL/v1/auth/approle/role/$SECMG_ROLE_NAME")
  cidrs=$(printf '%s' "$role" | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin).get("data",{}).get("secret_id_bound_cidrs") or []))' 2>/dev/null)
  echo "       secret_id_bound_cidrs: ${cidrs:-<none>}"
  pod_ips=$(kubectl -n "$PORTAL_NS" get pods -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' | sort -u)
  outside=$(CIDRS="$cidrs" python3 -c '
import ipaddress, os, sys
nets = [ipaddress.ip_network(c, strict=False) for c in os.environ["CIDRS"].split()]
for ip in sys.stdin.read().split():
    if nets and not any(ipaddress.ip_address(ip) in n for n in nets):
        print(ip)' <<<"$pod_ips")
  if [[ -z "$cidrs" ]]; then
    warn "AppRole has no CIDR binding"
  elif [[ -n "$outside" ]]; then
    fail "CP-Portal pod IPs outside AppRole bound CIDRs (OpenBao login will be denied): $(echo $outside)"
  else
    ok "All CP-Portal pod IPs are inside the AppRole bound CIDRs"
  fi
  stop_openbao_port_forward
else
  fail "Could not open a port-forward to OpenBao"
fi

# 6. metrics-server -----------------------------------------------------------
section "6. metrics-server (CPU/Memory usage, TOP 5 nodes)"
if [[ "$(kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)" == "True" ]]; then
  ok "metrics.k8s.io API is available"
else
  fail "metrics-server is not installed/available - usage columns and TOP 5 charts stay empty"
fi

# 7. Recent errors in portal API logs -------------------------------------------
section "7. Recent errors in CP-Portal API logs"
for deploy in $(kubectl -n "$PORTAL_NS" get deploy -o name 2>/dev/null | grep -E 'api|ui'); do
  errors=$(kubectl -n "$PORTAL_NS" logs "$deploy" --tail=300 2>/dev/null | \
    grep -iE 'error|exception|denied|refused|timed? ?out|unauthori|sealed|x509' | tail -n 5)
  if [[ -n "$errors" ]]; then
    warn "$deploy"
    echo "$errors" | cut -c1-300 | sed 's/^/       /'
  fi
done

echo
((FAILED)) && echo "Some checks failed. Fix the [FAIL] items above first." || echo "All checks passed."
