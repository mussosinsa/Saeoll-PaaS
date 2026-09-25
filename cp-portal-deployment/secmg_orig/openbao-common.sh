#!/usr/bin/env bash

OPENBAO_INIT_FILE=${OPENBAO_INIT_FILE:-../secmg/unseal-key}
OPENBAO_WAIT_ATTEMPTS=${OPENBAO_WAIT_ATTEMPTS:-120}
OPENBAO_WAIT_INTERVAL=${OPENBAO_WAIT_INTERVAL:-5}
OPENBAO_PORT_FORWARD_RESTARTS=${OPENBAO_PORT_FORWARD_RESTARTS:-5}
OPENBAO_PORT_FORWARD_PID=
OPENBAO_EXTERNAL_URL=
OPENBAO_PORT_FORWARD_LOG=

openbao_json_scalar() {
  local field=$1
  python3 -c 'import json,sys; value=json.load(sys.stdin).get(sys.argv[1]); print("" if value is None else str(value).lower() if isinstance(value, bool) else value)' "$field"
}

openbao_json_array() {
  local field=$1
  python3 -c 'import json,sys; [print(value) for value in (json.load(sys.stdin).get(sys.argv[1]) or [])]' "$field"
}

openbao_pod_status() {
  local kubectl_cmd=${OPENBAO_KUBECTL_CMD:-kubectl}
  local namespace=${OPENBAO_NAMESPACE:-openbao}
  local selector=${OPENBAO_SERVER_SELECTOR:-app.kubernetes.io/name=openbao,component=server}

  # Prints one line per server pod: <name> <phase> <running:true|false> <detail>
  $kubectl_cmd -n "$namespace" --request-timeout=10s get pods -l "$selector" -o json 2>/dev/null | \
    python3 -c '
import json, sys
for pod in json.load(sys.stdin).get("items", []):
    status = pod.get("status", {})
    phase = status.get("phase", "Unknown")
    running = False
    detail = ""
    for cs in status.get("containerStatuses") or []:
        state = cs.get("state", {})
        if "running" in state:
            running = True
        elif "waiting" in state:
            detail = state["waiting"].get("reason", "") + ": " + state["waiting"].get("message", "")
        elif "terminated" in state:
            detail = "Terminated: " + state["terminated"].get("reason", "")
    if not detail:
        for cond in status.get("conditions") or []:
            if cond.get("status") != "True" and cond.get("reason"):
                detail = cond.get("reason", "") + ": " + cond.get("message", "")
                break
    print(pod["metadata"]["name"], phase, str(running).lower(), " ".join(detail.split())[:300])
'
}

diagnose_openbao_pod() {
  local kubectl_cmd=${OPENBAO_KUBECTL_CMD:-kubectl}
  local namespace=${OPENBAO_NAMESPACE:-openbao}
  local selector=${OPENBAO_SERVER_SELECTOR:-app.kubernetes.io/name=openbao,component=server}

  echo "[ERROR] ===== OpenBao diagnostics (namespace: $namespace) =====" >&2
  $kubectl_cmd -n "$namespace" get pods,pvc -o wide >&2 || true
  $kubectl_cmd get storageclass >&2 || true
  $kubectl_cmd -n "$namespace" describe pods -l "$selector" >&2 || true
  $kubectl_cmd -n "$namespace" describe pvc >&2 || true
  $kubectl_cmd -n "$namespace" get events --sort-by=.lastTimestamp 2>/dev/null | tail -n 30 >&2 || true
  $kubectl_cmd -n "$namespace" logs -l "$selector" --tail=50 --prefix >&2 2>/dev/null || true
  cat >&2 <<'HINT'
[HINT] Pending 원인별 확인 사항
  - PVC Pending / "unbound immediate PersistentVolumeClaims":
      K8S_STORAGECLASS의 provisioner 동작 여부(NFS 서버 접근, nfs-utils 설치)를 확인한다.
  - ErrImagePull / ImagePullBackOff:
      각 노드에서 K_PAAS_REGISTRY 이미지 pull(DNS, 프록시, CA)을 확인한다.
  - Unschedulable / didn't match pod anti-affinity / taint:
      control-plane taint가 없는 일반 worker 노드가 있는지, edge 라벨 노드만 있는지 확인한다.
HINT
}

wait_for_openbao_pod_running() {
  local attempts=${OPENBAO_POD_WAIT_ATTEMPTS:-$OPENBAO_WAIT_ATTEMPTS}
  local attempt line name phase running detail

  for ((attempt=1; attempt<=attempts; attempt++)); do
    line=$(openbao_pod_status | head -n 1)
    read -r name phase running detail <<<"$line"
    if [[ "$phase" == "Running" && "$running" == "true" ]]; then
      echo "[OK] OpenBao pod $name is Running (sealed pods stay 0/1 until unsealed)."
      return 0
    fi
    case "$detail" in
      ErrImagePull*|ImagePullBackOff*|InvalidImageName*|CreateContainerConfigError*)
        if ((attempt >= 24)); then
          echo "[ERROR] OpenBao pod $name cannot start: $detail" >&2
          diagnose_openbao_pod
          return 1
        fi
        ;;
    esac
    echo "[INFO] Waiting for OpenBao pod (${attempt}/${attempts}): ${name:-<none>} ${phase:-NotFound} ${detail}"
    sleep "$OPENBAO_WAIT_INTERVAL"
  done
  echo "[ERROR] OpenBao pod did not reach Running state." >&2
  diagnose_openbao_pod
  return 1
}

open_openbao_tunnel() {
  local kubectl_cmd=${OPENBAO_KUBECTL_CMD:-kubectl}
  local namespace=${OPENBAO_NAMESPACE:-openbao}
  local service=${OPENBAO_SERVICE:-openbao}
  local port

  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()') || return 1
  [[ -n "${OPENBAO_PORT_FORWARD_LOG:-}" ]] || OPENBAO_PORT_FORWARD_LOG=$(mktemp)
  : >"$OPENBAO_PORT_FORWARD_LOG"

  # The management host may not resolve or route the external Ingress yet.
  # Reach the ClusterIP service through the Kubernetes API instead.
  $kubectl_cmd -n "$namespace" port-forward "service/$service" \
    --address 127.0.0.1 "$port:8200" >"$OPENBAO_PORT_FORWARD_LOG" 2>&1 &
  OPENBAO_PORT_FORWARD_PID=$!
  SECMG_URL="http://127.0.0.1:$port"

  sleep 2
  if ! kill -0 "$OPENBAO_PORT_FORWARD_PID" 2>/dev/null; then
    echo "[ERROR] Failed to start OpenBao port-forward." >&2
    cat "$OPENBAO_PORT_FORWARD_LOG" >&2
    OPENBAO_PORT_FORWARD_PID=
    return 1
  fi
  echo "[INFO] OpenBao API tunnel: $SECMG_URL -> service/$service.$namespace:8200"
}

start_openbao_port_forward() {
  OPENBAO_EXTERNAL_URL=$SECMG_URL
  # kubectl port-forward exits immediately while the backing pod is Pending,
  # so wait for the server container to run before opening the tunnel.
  wait_for_openbao_pod_running || return 1
  open_openbao_tunnel || { stop_openbao_port_forward; return 1; }
}

restart_openbao_port_forward() {
  if [[ -n "${OPENBAO_PORT_FORWARD_PID:-}" ]]; then
    kill "$OPENBAO_PORT_FORWARD_PID" 2>/dev/null || true
    wait "$OPENBAO_PORT_FORWARD_PID" 2>/dev/null || true
    OPENBAO_PORT_FORWARD_PID=
  fi
  wait_for_openbao_pod_running || return 1
  open_openbao_tunnel
}

stop_openbao_port_forward() {
  if [[ -n "${OPENBAO_PORT_FORWARD_PID:-}" ]]; then
    kill "$OPENBAO_PORT_FORWARD_PID" 2>/dev/null || true
    wait "$OPENBAO_PORT_FORWARD_PID" 2>/dev/null || true
    OPENBAO_PORT_FORWARD_PID=
  fi
  [[ -n "${OPENBAO_PORT_FORWARD_LOG:-}" ]] && rm -f "$OPENBAO_PORT_FORWARD_LOG"
  OPENBAO_PORT_FORWARD_LOG=
  [[ -n "${OPENBAO_EXTERNAL_URL:-}" ]] && SECMG_URL=$OPENBAO_EXTERNAL_URL
  OPENBAO_EXTERNAL_URL=
  return 0
}

wait_for_openbao_api() {
  local attempt response restarts=0
  for ((attempt=1; attempt<=OPENBAO_WAIT_ATTEMPTS; attempt++)); do
    if [[ -n "${OPENBAO_EXTERNAL_URL:-}" ]] && \
      { [[ -z "${OPENBAO_PORT_FORWARD_PID:-}" ]] || ! kill -0 "$OPENBAO_PORT_FORWARD_PID" 2>/dev/null; }; then
      echo "[WARN] OpenBao port-forward stopped:" >&2
      cat "$OPENBAO_PORT_FORWARD_LOG" >&2 2>/dev/null
      if ((restarts >= OPENBAO_PORT_FORWARD_RESTARTS)); then
        echo "[ERROR] OpenBao port-forward failed $restarts times." >&2
        diagnose_openbao_pod
        return 1
      fi
      restarts=$((restarts + 1))
      echo "[INFO] Restarting OpenBao port-forward (${restarts}/${OPENBAO_PORT_FORWARD_RESTARTS})..."
      restart_openbao_port_forward || return 1
    fi
    if response=$(curl --fail --silent --show-error --insecure \
      "${SECMG_URL}/v1/sys/init" 2>/dev/null); then
      if [[ -n "$response" ]]; then
        echo "[OK] OpenBao API is ready."
        return 0
      fi
    fi
    echo "[INFO] Waiting for OpenBao API (${attempt}/${OPENBAO_WAIT_ATTEMPTS})..."
    sleep "$OPENBAO_WAIT_INTERVAL"
  done
  echo "[ERROR] OpenBao API did not become ready: $SECMG_URL" >&2
  return 1
}

initialize_openbao() {
  local status initialized init_response
  status=$(curl --fail --silent --show-error --insecure "${SECMG_URL}/v1/sys/init") || return 1
  initialized=$(printf '%s' "$status" | openbao_json_scalar initialized) || return 1

  if [[ "$initialized" == "true" ]]; then
    echo "[INFO] OpenBao is already initialized."
    if [[ ! -s "$OPENBAO_INIT_FILE" ]]; then
      echo "[ERROR] OpenBao is initialized, but $OPENBAO_INIT_FILE is missing." >&2
      echo "[ERROR] Restore the original initialization JSON; OpenBao cannot regenerate unseal keys." >&2
      return 1
    fi
    if ! python3 -m json.tool "$OPENBAO_INIT_FILE" >/dev/null 2>&1; then
      echo "[ERROR] $OPENBAO_INIT_FILE is not the complete OpenBao initialization JSON." >&2
      echo "[ERROR] Restore a backup containing keys_base64, secret_threshold, and root_token." >&2
      return 1
    fi
    return 0
  fi

  echo "[INFO] Initializing OpenBao with 3 key shares and threshold 2..."
  init_response=$(curl --fail --silent --show-error --insecure \
    --header 'Content-Type: application/json' \
    --request POST \
    --data '{"secret_shares":3,"secret_threshold":2}' \
    "${SECMG_URL}/v1/sys/init") || return 1

  if ! printf '%s' "$init_response" | python3 -m json.tool >/dev/null 2>&1; then
    echo "[ERROR] OpenBao initialization returned invalid JSON." >&2
    return 1
  fi

  umask 077
  if [[ -s "$OPENBAO_INIT_FILE" ]]; then
    # A stale file from an earlier OpenBao data volume must not be lost silently.
    cp -p "$OPENBAO_INIT_FILE" "${OPENBAO_INIT_FILE}.$(date +%Y%m%d%H%M%S).bak"
    echo "[WARN] Previous $OPENBAO_INIT_FILE was backed up before re-initialization." >&2
  fi
  printf '%s\n' "$init_response" > "$OPENBAO_INIT_FILE"
  chmod 600 "$OPENBAO_INIT_FILE"
  echo "[OK] OpenBao initialized. Initialization material saved to $OPENBAO_INIT_FILE (mode 600)."
}

unseal_openbao() {
  local init_json seal_status sealed threshold key response
  local -a unseal_keys

  init_json=$(cat "$OPENBAO_INIT_FILE") || return 1
  SECMG_ROOT_TOKEN=$(printf '%s' "$init_json" | openbao_json_scalar root_token) || return 1
  threshold=$(printf '%s' "$init_json" | openbao_json_scalar secret_threshold) || return 1
  mapfile -t unseal_keys < <(printf '%s' "$init_json" | openbao_json_array keys_base64)

  [[ -n "$SECMG_ROOT_TOKEN" ]] || { echo "[ERROR] root_token is missing from $OPENBAO_INIT_FILE" >&2; return 1; }
  [[ "$threshold" =~ ^[1-9][0-9]*$ ]] || { echo "[ERROR] Invalid secret_threshold in $OPENBAO_INIT_FILE" >&2; return 1; }
  ((${#unseal_keys[@]} >= threshold)) || {
    echo "[ERROR] Only ${#unseal_keys[@]} unseal keys are available; $threshold are required." >&2
    return 1
  }

  seal_status=$(curl --fail --silent --show-error --insecure "${SECMG_URL}/v1/sys/seal-status") || return 1
  sealed=$(printf '%s' "$seal_status" | openbao_json_scalar sealed) || return 1
  if [[ "$sealed" == "false" ]]; then
    echo "[OK] OpenBao is already unsealed."
    return 0
  fi

  echo "[INFO] Unsealing OpenBao with $threshold key shares..."
  for ((index=0; index<threshold; index++)); do
    key=${unseal_keys[$index]}
    response=$(OPENBAO_UNSEAL_KEY="$key" python3 - <<'PY' | \
      curl --fail --silent --show-error --insecure \
        --header 'Content-Type: application/json' --request POST --data @- \
        "${SECMG_URL}/v1/sys/unseal"
import json
import os
print(json.dumps({"key": os.environ["OPENBAO_UNSEAL_KEY"]}))
PY
    ) || return 1
    sealed=$(printf '%s' "$response" | openbao_json_scalar sealed) || return 1
    echo "[INFO] Submitted unseal key $((index + 1))/$threshold."
    [[ "$sealed" == "false" ]] && break
  done

  seal_status=$(curl --fail --silent --show-error --insecure "${SECMG_URL}/v1/sys/seal-status") || return 1
  sealed=$(printf '%s' "$seal_status" | openbao_json_scalar sealed) || return 1
  if [[ "$sealed" != "false" ]]; then
    echo "[ERROR] OpenBao remains sealed after submitting $threshold keys." >&2
    return 1
  fi
  echo "[OK] OpenBao is unsealed."
}

prepare_openbao() {
  wait_for_openbao_api || return 1
  initialize_openbao || return 1
  unseal_openbao || return 1
}
