#!/usr/bin/env bash
# Install K-PaaS foundation components on an existing Kubernetes cluster.
# This script never runs cluster.yml and does not reconfigure Kubernetes,
# Calico, MetalLB, or the existing NFS provisioner.

set -Eeuo pipefail
umask 077

PROJECT_ROOT="${PROJECT_ROOT:-/root/Saeoll-PaaS}"
STANDALONE_DIR="${STANDALONE_DIR:-${PROJECT_ROOT}/standalone}"
APPLICATIONS_DIR="${APPLICATIONS_DIR:-${PROJECT_ROOT}/applications}"
COMPAT_LINK="${COMPAT_LINK:-/root/cp-deployment}"
HELM_VERSION="${HELM_VERSION:-3.18.4}"
INGRESS_MANIFEST="${INGRESS_MANIFEST:-${APPLICATIONS_DIR}/ingress-nginx-1.13.3/deploy.yaml}"
INGRESS_NAMESPACE="${INGRESS_NAMESPACE:-ingress-nginx}"
INGRESS_SERVICE="${INGRESS_SERVICE:-ingress-nginx-controller}"
INGRESS_LB_IP="${INGRESS_LB_IP:-192.168.20.155}"
SOURCE_SC="${SOURCE_SC:-nfs-client}"
CP_SC="${CP_SC:-cp-storageclass}"
OPENBAO_NAMESPACE="${OPENBAO_NAMESPACE:-k-paas-system}"
OPENBAO_RELEASE="${OPENBAO_RELEASE:-controller-vault}"
OPENBAO_CHART_VERSION="${OPENBAO_CHART_VERSION:-0.19.0}"
OPENBAO_CHART="${OPENBAO_CHART:-oci://registry.k-paas.org/kpaas/openbao}"
OPENBAO_POD="${OPENBAO_POD:-controller-vault-0}"
CP_PORTAL_NAMESPACE="${CP_PORTAL_NAMESPACE:-cp-portal}"
CP_PORTAL_RELEASE="${CP_PORTAL_RELEASE:-cp-portal}"
CP_PORTAL_CHART="${CP_PORTAL_CHART:-oci://registry.k-paas.org/kpaas/cp-portal}"
CP_PORTAL_CHART_VERSION="${CP_PORTAL_CHART_VERSION:-}"
CP_PORTAL_MANIFEST="${CP_PORTAL_MANIFEST:-}"
CP_PORTAL_VALUES_FILE="${CP_PORTAL_VALUES_FILE:-}"
CP_PORTAL_TIMEOUT="${CP_PORTAL_TIMEOUT:-10m}"
POD_NETWORK="${POD_NETWORK:-172.16.0.0/16}"
KEY_FILE="${KEY_FILE:-${STANDALONE_DIR}/.keys}"
LOG_DIR="${LOG_DIR:-/var/log/kpaas}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/install-existing-k8s-$(date +%Y%m%d-%H%M%S).log}"
CREATE_COMPAT_SA="${CREATE_COMPAT_SA:-Y}"
COMPAT_TOKEN_DURATION="${COMPAT_TOKEN_DURATION:-999999h}"

mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'rc=$?; echo "[ERROR] line ${LINENO}: command failed (exit=${rc})"; echo "[INFO] log: ${LOG_FILE}"; exit ${rc}' ERR

log()  { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
ok()   { echo "[OK] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

wait_pod_running() {
  local ns="$1" pod="$2" timeout="${3:-300}" elapsed phase
  for ((elapsed=0; elapsed<timeout; elapsed+=5)); do
    phase="$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == Running ]] && return 0
    sleep 5
  done
  kubectl -n "$ns" get pod "$pod" -o wide || true
  return 1
}

wait_external_ip() {
  local ns="$1" service="$2" expected="$3" timeout="${4:-180}" elapsed ip
  for ((elapsed=0; elapsed<timeout; elapsed+=3)); do
    ip="$(kubectl -n "$ns" get service "$service" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ "$ip" == "$expected" ]] && return 0
    sleep 3
  done
  return 1
}

install_helm() {
  local current="" arch tmp
  if command -v helm >/dev/null 2>&1; then
    current="$(helm version --short 2>/dev/null | sed -E 's/^v([0-9.]+).*/\1/' || true)"
  fi
  [[ "$current" == "$HELM_VERSION" ]] && { ok "Helm ${HELM_VERSION}"; return; }
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "unsupported architecture for Helm: $(uname -m)" ;;
  esac
  tmp="$(mktemp -d)"
  log "Installing Helm ${HELM_VERSION}"
  curl -fL --retry 3 "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${arch}.tar.gz" -o "${tmp}/helm.tgz"
  tar -xzf "${tmp}/helm.tgz" -C "$tmp"
  install -m 0755 "${tmp}/linux-${arch}/helm" /usr/local/bin/helm
  rm -rf "$tmp"
  helm version
}

preflight() {
  log "Preflight checks"
  [[ $EUID -eq 0 ]] || die "run as root"
  [[ -r /etc/os-release ]] || die "/etc/os-release not found"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == rocky && "${VERSION_ID:-}" == 9.7 ]] || die "Rocky Linux 9.7 is required (detected ${PRETTY_NAME:-unknown})"
  local command
  for command in kubectl curl sed awk grep openssl python3 tar install mktemp; do need_cmd "$command"; done
  [[ -d "$PROJECT_ROOT" ]] || die "project not found: $PROJECT_ROOT"
  [[ -d "$STANDALONE_DIR" ]] || die "standalone directory not found: $STANDALONE_DIR"
  [[ -f "$INGRESS_MANIFEST" ]] || die "ingress manifest not found: $INGRESS_MANIFEST"
  [[ -z "$CP_PORTAL_MANIFEST" || -f "$CP_PORTAL_MANIFEST" ]] || die "CP-Portal manifest not found: $CP_PORTAL_MANIFEST"
  [[ -z "$CP_PORTAL_VALUES_FILE" || -f "$CP_PORTAL_VALUES_FILE" ]] || die "CP-Portal values file not found: $CP_PORTAL_VALUES_FILE"
  kubectl cluster-info >/dev/null
  [[ "$(kubectl auth can-i '*' '*' --all-namespaces)" == yes ]] || die "current kubeconfig requires cluster-admin-equivalent access"
  local not_ready provisioner owner
  not_ready="$(kubectl get nodes --no-headers | awk '$2 != "Ready" {print $1":"$2}' || true)"
  [[ -z "$not_ready" ]] || die "NotReady nodes detected: $not_ready"
  kubectl get crd ipaddresspools.metallb.io >/dev/null 2>&1 || die "existing MetalLB CRD not found"
  kubectl get storageclass "$SOURCE_SC" >/dev/null 2>&1 || die "source StorageClass not found: $SOURCE_SC"
  provisioner="$(kubectl get storageclass "$SOURCE_SC" -o jsonpath='{.provisioner}')"
  [[ "$provisioner" == k8s-sigs.io/nfs-subdir-external-provisioner ]] || die "${SOURCE_SC} provisioner is unexpected: ${provisioner}"
  owner="$(kubectl get service -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,IP:.status.loadBalancer.ingress[0].ip' --no-headers | awk -v ip="$INGRESS_LB_IP" '$3==ip {print $1"/"$2}')"
  [[ -z "$owner" || "$owner" == "${INGRESS_NAMESPACE}/${INGRESS_SERVICE}" ]] || die "LoadBalancer IP ${INGRESS_LB_IP} is already used by ${owner}"
  ok "Existing Kubernetes, MetalLB, and ${SOURCE_SC} passed validation"
}

create_compat_link() {
  log "Creating K-PaaS compatibility path"
  [[ ! -e "$COMPAT_LINK" || -L "$COMPAT_LINK" ]] || die "${COMPAT_LINK} exists and is not a symlink"
  ln -sfn "$PROJECT_ROOT" "$COMPAT_LINK"
  ok "${COMPAT_LINK} -> ${PROJECT_ROOT}"
}

create_storageclass() {
  log "Ensuring StorageClass ${CP_SC}"
  if kubectl get storageclass "$CP_SC" >/dev/null 2>&1; then
    [[ "$(kubectl get storageclass "$CP_SC" -o jsonpath='{.provisioner}')" == k8s-sigs.io/nfs-subdir-external-provisioner ]] || die "${CP_SC} has an unexpected provisioner"
    ok "${CP_SC} already exists"
    return
  fi
  cat <<EOF_SC | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${CP_SC}
provisioner: k8s-sigs.io/nfs-subdir-external-provisioner
parameters:
  archiveOnDelete: "false"
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
EOF_SC
}

test_storageclass() {
  log "Testing ${CP_SC} dynamic provisioning"
  local pvc="cp-storage-test-$$" elapsed phase=""
  cat <<EOF_PVC | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc}
spec:
  storageClassName: ${CP_SC}
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 100Mi
EOF_PVC
  for ((elapsed=0; elapsed<60; elapsed+=2)); do
    phase="$(kubectl get pvc "$pvc" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "$phase" == Bound ]]; then
      kubectl delete pvc "$pvc" --wait=false >/dev/null
      ok "${CP_SC} PVC test passed"
      return
    fi
    sleep 2
  done
  kubectl describe pvc "$pvc" || true
  kubectl delete pvc "$pvc" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  die "${CP_SC} PVC test failed (phase=${phase:-unknown})"
}

install_ingress() {
  log "Installing ingress-nginx from bundled manifest"
  kubectl apply -f "$INGRESS_MANIFEST"
  if kubectl -n "$INGRESS_NAMESPACE" get deployment ingress-nginx-controller >/dev/null 2>&1; then
    kubectl -n "$INGRESS_NAMESPACE" rollout status deployment/ingress-nginx-controller --timeout=300s
  else
    kubectl -n "$INGRESS_NAMESPACE" wait --for=condition=Ready pod -l app.kubernetes.io/component=controller --timeout=300s
  fi
  kubectl -n "$INGRESS_NAMESPACE" get service "$INGRESS_SERVICE" >/dev/null 2>&1 || die "ingress service not found"
  kubectl -n "$INGRESS_NAMESPACE" patch service "$INGRESS_SERVICE" --type merge -p "{\"spec\":{\"type\":\"LoadBalancer\",\"loadBalancerIP\":\"${INGRESS_LB_IP}\"}}"
  wait_external_ip "$INGRESS_NAMESPACE" "$INGRESS_SERVICE" "$INGRESS_LB_IP" || die "MetalLB did not assign ${INGRESS_LB_IP}"
  ok "ingress-nginx External IP: ${INGRESS_LB_IP}"
}

install_openbao_chart() {
  log "Ensuring OpenBao ${OPENBAO_CHART_VERSION}"
  kubectl create namespace "$OPENBAO_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  if ! helm status "$OPENBAO_RELEASE" -n "$OPENBAO_NAMESPACE" >/dev/null 2>&1; then
    helm install "$OPENBAO_RELEASE" "$OPENBAO_CHART" --version "$OPENBAO_CHART_VERSION" --namespace "$OPENBAO_NAMESPACE" --set fullnameOverride="$OPENBAO_RELEASE" -f - <<EOF_VALUES
injector:
  enabled: false
server:
  image:
    registry: registry.k-paas.org
    repository: openbao/openbao
  ingress:
    enabled: false
  dataStorage:
    storageClass: ${CP_SC}
  statefulSet:
    securityContext:
      pod: {runAsUser: 1000, fsGroup: 1000}
      container:
        allowPrivilegeEscalation: false
        capabilities: {drop: [ALL]}
        runAsNonRoot: true
        seccompProfile: {type: RuntimeDefault}
  affinity: |
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              app.kubernetes.io/name: {{ template "openbao.name" . }}
              app.kubernetes.io/instance: "{{ .Release.Name }}"
              component: server
          topologyKey: kubernetes.io/hostname
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - {key: node-role.kubernetes.io/edge, operator: DoesNotExist}
csi:
  daemonSet:
    securityContext:
      pod: {runAsUser: 1000, fsGroup: 1000}
      container:
        allowPrivilegeEscalation: false
        capabilities: {drop: [ALL]}
        runAsNonRoot: true
        seccompProfile: {type: RuntimeDefault}
  pod:
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
                - {key: node-role.kubernetes.io/edge, operator: DoesNotExist}
EOF_VALUES
  fi
  wait_pod_running "$OPENBAO_NAMESPACE" "$OPENBAO_POD" || die "OpenBao pod did not reach Running"
  ok "OpenBao pod is Running"
}

bao_exec() { kubectl -n "$OPENBAO_NAMESPACE" exec "$OPENBAO_POD" -- sh -c "$1"; }
bao_health_json() { bao_exec "wget -qO- http://127.0.0.1:8200/v1/sys/health 2>/dev/null || true"; }
openbao_initialized() { bao_health_json | grep -Eq '"initialized"[[:space:]]*:[[:space:]]*true'; }
openbao_sealed() { bao_health_json | grep -Eq '"sealed"[[:space:]]*:[[:space:]]*true'; }
json_value() {
  python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    value = json.load(stream)
for part in sys.argv[2].split("."):
    value = value[part]
print(*value, sep="\n") if isinstance(value, list) else print(value)
PY
}

initialize_openbao() {
  log "Checking OpenBao initialization state"
  if openbao_initialized; then
    ok "OpenBao is already initialized"
    [[ -s "$KEY_FILE" ]] || warn "${KEY_FILE} is missing; automatic unseal is unavailable"
    return
  fi
  local init_json
  init_json="$(bao_exec "wget -qO- --header='Content-Type: application/json' --post-data='{\"secret_shares\":3,\"secret_threshold\":2}' http://127.0.0.1:8200/v1/sys/init")"
  printf '%s' "$init_json" | grep -q '"root_token"' || die "invalid OpenBao initialization response"
  mkdir -p "$(dirname "$KEY_FILE")"
  printf '%s\n' "$init_json" > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  warn "SECURE BACKUP REQUIRED: ${KEY_FILE}"
}

unseal_openbao() {
  log "Checking OpenBao seal state"
  openbao_sealed || { ok "OpenBao is already unsealed"; return; }
  [[ -s "$KEY_FILE" ]] || die "OpenBao is sealed and ${KEY_FILE} is missing"
  local count=0 key
  while IFS= read -r key; do
    bao_exec "wget -qO- --header='Content-Type: application/json' --post-data='{\"key\":\"${key}\"}' http://127.0.0.1:8200/v1/sys/unseal >/dev/null"
    ((++count >= 2)) && break
  done < <(json_value "$KEY_FILE" keys_base64)
  openbao_sealed && die "OpenBao remains sealed"
  ok "OpenBao unsealed"
}

bao_api() {
  local method="$1" path="$2" token="$3" data="${4:-}"
  if [[ -n "$data" ]]; then
    bao_exec "wget -qO- --method='${method}' --header='X-Vault-Token: ${token}' --header='Content-Type: application/json' --body-data='${data}' 'http://127.0.0.1:8200${path}' 2>/dev/null || true"
  else
    bao_exec "wget -qO- --method='${method}' --header='X-Vault-Token: ${token}' 'http://127.0.0.1:8200${path}' 2>/dev/null || true"
  fi
}

configure_openbao() {
  log "Configuring OpenBao AppRole, KV, and Kubernetes metadata"
  [[ -s "$KEY_FILE" ]] || die "OpenBao root token file is missing: ${KEY_FILE}"
  local root_token auths mounts cluster_token cluster_api metadata role_json role_resp secret_resp role_id secret_id
  root_token="$(json_value "$KEY_FILE" root_token)"
  auths="$(bao_api GET /v1/sys/auth "$root_token")"
  grep -q '"approle/"' <<<"$auths" || bao_api POST /v1/sys/auth/approle "$root_token" '{"type":"approle"}' >/dev/null
  mounts="$(bao_api GET /v1/sys/mounts "$root_token")"
  grep -q '"secret/"' <<<"$mounts" || bao_api POST /v1/sys/mounts/secret "$root_token" '{"type":"kv","options":{"version":"2"}}' >/dev/null
  [[ "$CREATE_COMPAT_SA" == Y ]] || die "CREATE_COMPAT_SA=N requires a separate controller authentication design"
  kubectl -n kube-system create serviceaccount controller-vault --dry-run=client -o yaml | kubectl apply -f -
  kubectl create clusterrolebinding controller-vault --clusterrole=cluster-admin --serviceaccount=kube-system:controller-vault --dry-run=client -o yaml | kubectl apply -f -
  warn "controller-vault uses cluster-admin and a long-lived token for K-PaaS compatibility"
  cluster_token="$(kubectl create token controller-vault --duration="$COMPAT_TOKEN_DURATION" -n kube-system)"
  cluster_api="$(kubectl config view --minify -o jsonpath='{.clusters[].cluster.server}')"
  metadata="$(python3 -c 'import json,sys; print(json.dumps({"data":{"clusterId":"cp-cluster","clusterApiUrl":sys.argv[1],"clusterToken":sys.argv[2]}},separators=(",",":")))' "$cluster_api" "$cluster_token")"
  bao_api POST /v1/secret/data/cluster/cp-cluster "$root_token" "$metadata" >/dev/null
  bao_api POST /v1/sys/policy/cluster_policy "$root_token" '{"policy":"path \"secret/*\" { capabilities = [\"create\", \"update\", \"delete\", \"read\"] }"}' >/dev/null
  role_json="$(python3 -c 'import json,sys; c=sys.argv[1]; print(json.dumps({"secret_id_ttl":0,"token_num_uses":0,"token_ttl":"1m","token_max_ttl":"10m","token_explicit_max_ttl":"10m","secret_id_num_uses":0,"secret_id_bound_cidrs":["127.0.0.6/16",c],"token_bound_cidrs":["127.0.0.6/16",c],"token_policies":"cluster_policy"},separators=(",",":")))' "$POD_NETWORK")"
  bao_api POST /v1/auth/approle/role/cluster_role "$root_token" "$role_json" >/dev/null
  role_resp="$(bao_api GET /v1/auth/approle/role/cluster_role/role-id "$root_token")"
  secret_resp="$(bao_api POST /v1/auth/approle/role/cluster_role/secret-id "$root_token" '{}')"
  role_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["role_id"])' <<<"$role_resp")"
  secret_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["secret_id"])' <<<"$secret_resp")"
  kubectl -n "$OPENBAO_NAMESPACE" create secret generic controller-manager --from-literal=VAULT_ROLE_NAME=cluster_role --from-literal=VAULT_ROLE_ID="$role_id" --from-literal=VAULT_SECRET_ID="$secret_id" --dry-run=client -o yaml | kubectl apply -f -
  ok "OpenBao controller configuration completed"
}

install_cp_portal() {
  log "Deploying CP-Portal"
  kubectl create namespace "$CP_PORTAL_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  if [[ -n "$CP_PORTAL_MANIFEST" ]]; then
    log "Applying CP-Portal manifest ${CP_PORTAL_MANIFEST}"
    kubectl -n "$CP_PORTAL_NAMESPACE" apply -f "$CP_PORTAL_MANIFEST"
  else
    local helm_args=(upgrade --install "$CP_PORTAL_RELEASE" "$CP_PORTAL_CHART"
      --namespace "$CP_PORTAL_NAMESPACE" --create-namespace
      --wait --timeout "$CP_PORTAL_TIMEOUT")
    [[ -z "$CP_PORTAL_CHART_VERSION" ]] || helm_args+=(--version "$CP_PORTAL_CHART_VERSION")
    [[ -z "$CP_PORTAL_VALUES_FILE" ]] || helm_args+=(-f "$CP_PORTAL_VALUES_FILE")
    helm "${helm_args[@]}"
  fi

  local workloads
  workloads="$(kubectl -n "$CP_PORTAL_NAMESPACE" get deployment,statefulset -o name 2>/dev/null || true)"
  [[ -n "$workloads" ]] || die "CP-Portal deployment created no Deployment or StatefulSet in ${CP_PORTAL_NAMESPACE}"
  while IFS= read -r workload; do
    [[ -z "$workload" ]] || kubectl -n "$CP_PORTAL_NAMESPACE" rollout status "$workload" --timeout="$CP_PORTAL_TIMEOUT"
  done <<<"$workloads"
  kubectl -n "$CP_PORTAL_NAMESPACE" get pods,service,ingress -o wide
  ok "CP-Portal deployment completed"
}

final_check() {
  log "Final status"
  kubectl get nodes -o wide
  kubectl get storageclass "$SOURCE_SC" "$CP_SC" -o wide
  kubectl -n "$INGRESS_NAMESPACE" get pods,service -o wide
  kubectl -n "$OPENBAO_NAMESPACE" get pods,pvc,service -o wide
  kubectl -n "$CP_PORTAL_NAMESPACE" get pods,service,ingress -o wide
  helm list -n "$OPENBAO_NAMESPACE"
  openbao_initialized && ok "OpenBao initialized" || warn "OpenBao is not initialized"
  openbao_sealed && warn "OpenBao is sealed" || ok "OpenBao unsealed"
  ok "K-PaaS foundation installation on existing Kubernetes completed"
  echo "[INFO] ingress external IP: ${INGRESS_LB_IP}"
  echo "[INFO] storage class: ${CP_SC}"
  echo "[INFO] sensitive key file: ${KEY_FILE}"
  echo "[INFO] installation log: ${LOG_FILE}"
  echo "[INFO] CP-Portal namespace: ${CP_PORTAL_NAMESPACE}"
}

main() {
  log "K-PaaS installation on existing Kubernetes started"
  preflight
  install_helm
  create_compat_link
  create_storageclass
  test_storageclass
  install_ingress
  install_openbao_chart
  initialize_openbao
  unseal_openbao
  configure_openbao
  install_cp_portal
  final_check
}
main "$@"
