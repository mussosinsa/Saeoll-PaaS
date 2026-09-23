#!/bin/bash

#############################################
# ANSI Colors
#############################################
RED='\033[31m'
GREEN='\033[32m'
BLUE='\033[34m'
YELLOW='\033[33m'
BOLD='\033[1m'
RESET='\033[0m'

#############################################
# Load member-cluster config
#############################################
MEMBER_CLUSTER_CONFIG_MISSING=false
if [ -f "./member-cluster-config.sh" ]; then
  source ./member-cluster-config.sh
else
  MEMBER_CLUSTER_CONFIG_MISSING=true
fi

# External scripts
source ../script/deploy-cp-portal.sh
source ./fed-vars.sh

#############################################
# Global config
#############################################
RB_NAMESPACE="kube-system"
CP_PORTAL_API="${CP_PORTAL_URL}/cpapi"

CP_PORTAL_ADMIN_ID="admin"
CP_PORTAL_ADMIN_AUTH_ID="${KEYCLOAK_CP_ADMIN_ID}"
CP_PORTAL_IS_SUPER_ADMIN="true"

SUCCESS_CLUSTERS_BY_CTX=()
SUCCESS_CLUSTERS_BY_NAME=()
FAILED_CLUSTERS=()
FAILED_REASON=()

#############################################
# Unified API wrapper
#############################################
call_api() {
  local method="$1"
  local url="$2"
  local token="$3"
  local data="${4:-}"

  if [ -n "$data" ]; then
    curl -sS -X "$method" "$url" \
      -H "Content-Type: application/json" \
      ${token:+-H "Authorization: Bearer $token"} \
      -d "$data"
  else
    curl -sS -X "$method" "$url" \
      -H "Content-Type: application/json" \
      ${token:+-H "Authorization: Bearer $token"}
  fi
}

#############################################
# JSON parsing helpers
#############################################
parse_result_fields() {
  local resp="$1"
  PARSED_RESULT_CODE=$(echo "$resp" | sed -n 's/.*"resultCode"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
  PARSED_RESULT_MESSAGE=$(echo "$resp" | sed -n 's/.*"resultMessage"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
}

#############################################
# Wait core services
#############################################
wait_core_ready() {
  local ns="$1"
  local selector="$2"
  local label="$3"
  local interval="$4"

  while :; do
    pods=$(kubectl --request-timeout=5s get pods -n "$ns" -l "$selector" --no-headers 2>/dev/null)
    [[ -z "$pods" ]] && sleep "$interval" && continue

    total=$(echo "$pods" | wc -l)
    ready=$(echo "$pods" | awk '{print $2}' | grep -Eo '[0-9]+/[0-9]+' | awk -F/ '$1==$2' | wc -l)

    echo "    → ${label}: ${ready}/${total}"

    [[ "$ready" -eq "$total" ]] && break
    sleep "$interval"
  done
}

wait_core() {
  echo -e "${BOLD}${BLUE}▶ Wait services...${RESET}"

  local pairs=(
    "${NAMESPACE[0]}|app.kubernetes.io/name=${CHART_NAME[0]}|openbao|3"
    "${NAMESPACE[1]}|app.kubernetes.io/name=${CHART_NAME[1]}|mariadb|3"
    "${NAMESPACE[3]}|app.kubernetes.io/name=${CHART_NAME[3]}|keycloak|25"
    "${NAMESPACE[4]}|app=cp-portal-api|cp-portal-api|3"
    "${NAMESPACE[4]}|app=cp-portal-common-api|cp-portal-common-api|3"
    "${NAMESPACE[4]}|app=cp-portal-federation-api|cp-portal-federation-api|3"
  )

  for item in "${pairs[@]}"; do
    IFS="|" read -r ns selector label interval <<< "$item"
    echo "  - Waiting for ${label}..."

    if [[ "$label" == "keycloak" ]]; then
      echo "    (Keycloak may take a few minutes to reach Ready state. Please wait...)"
    fi

    wait_core_ready "$ns" "$selector" "$label" "$interval"
  done
}
#############################################
# Admin signup
#############################################
admin_signup() {
  echo -e "${BOLD}${BLUE}▶ Admin signUp...${RESET}"

  payload=$(printf '{"userId":"%s","userAuthId":"%s","isSuperAdmin":%s}' \
    "$CP_PORTAL_ADMIN_ID" "$CP_PORTAL_ADMIN_AUTH_ID" "$CP_PORTAL_IS_SUPER_ADMIN")

  resp=$(call_api POST "${CP_PORTAL_API}/signUp" "" "$payload")
  parse_result_fields "$resp"

  case "$PARSED_RESULT_MESSAGE" in
    SUPER_ADMIN_ALREADY_REGISTERED)
      echo -e "  ${GREEN}✔ already registered${RESET}"
      return 0
      ;;
  esac

  if [ "$PARSED_RESULT_CODE" = "SUCCESS" ]; then
    echo -e "  ${GREEN}✔ signUp OK${RESET}"
    return 0
  fi

  echo -e "  ${RED}✘ signUp failed:${RESET} $PARSED_RESULT_MESSAGE"
  return 1
}

#############################################
# Admin login
#############################################
admin_login() {
  echo -e "${BOLD}${BLUE}▶ Admin login...${RESET}"

  payload=$(printf '{"userId":"%s","userAuthId":"%s","isSuperAdmin":%s}' \
    "$CP_PORTAL_ADMIN_ID" "$CP_PORTAL_ADMIN_AUTH_ID" "$CP_PORTAL_IS_SUPER_ADMIN")

  resp=$(call_api POST "${CP_PORTAL_API}/login" "" "$payload")
  parse_result_fields "$resp"

  if [ "$PARSED_RESULT_CODE" != "SUCCESS" ]; then
    echo -e "  ${RED}✘ login failed:${RESET} $PARSED_RESULT_MESSAGE"
    return 1
  fi

  CP_PORTAL_ADMIN_TOKEN=$(echo "$resp" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  if [ -z "$CP_PORTAL_ADMIN_TOKEN" ]; then
    echo -e "  ${RED}✘ token parse failed${RESET}"
    return 1
  fi

  export CP_PORTAL_ADMIN_TOKEN
  echo -e "  ${GREEN}✔ token OK${RESET}"
}

#############################################
# Detect cluster count
#############################################
detect_cluster_max_index() {
  local max=0 var idx
  while IFS= read -r var; do
    if [[ "$var" =~ ^CLUSTER([0-9]+)_CTX$ ]]; then
      idx="${BASH_REMATCH[1]}"
      (( idx > max )) && max="$idx"
    fi
  done < <(compgen -v)
  echo "$max"
}

#############################################
# Apply federation SA
#############################################
apply_fed_sa() {
  local ctx="$1"
  TG_NAMESPACE="$RB_NAMESPACE" \
    envsubst < "../values/cp-portal-fed-sa.yaml" \
    | kubectl --context "$ctx" apply -f - >/dev/null 2>&1
}

#############################################
# Token polling
#############################################
get_cluster_token() {
  local ctx="$1" token=""
  for _ in {1..6}; do
    token=$(kubectl --context "$ctx" -n "$RB_NAMESPACE" \
      get secret/cp-portal-federation-sa \
      -o go-template="{{.data.token | base64decode}}" 2>/dev/null || true)

    [ -n "$token" ] && echo "$token" && return 0
    sleep 0.5
  done
  echo ""
  return 1
}

#############################################
# Register cluster to portal
#############################################
register_cluster_to_portal() {
  local name apiserver iaas token payload resp

  name="$1"
  apiserver="$2"
  iaas="$3"
  token="$4"

  payload=$(printf \
    '{"cluster":"%s","resourceName":"%s","clusterApiUrl":"%s","providerType":"%s","clusterToken":"%s","description":"","isClusterRegister":true}' \
    "$name" "$name" "$apiserver" "$iaas" "$token")

  resp=$(call_api POST "${CP_PORTAL_API}/clusters" "$CP_PORTAL_ADMIN_TOKEN" "$payload")
  parse_result_fields "$resp"

  if [ "$PARSED_RESULT_CODE" = "SUCCESS" ]; then
    return 0
  fi

  FAILED_REASON+=("$PARSED_RESULT_MESSAGE")
  return 1
}

#############################################
# Register member clusters
#############################################
register_member_clusters() {
  echo -e "${BOLD}${BLUE}▶ Register member clusters${RESET}"

  local count
  count=$(detect_cluster_max_index)

  for i in $(seq 1 "$count"); do
    echo ""
    echo -e "${BOLD}Cluster $i${RESET}"

    eval "ctx=\${CLUSTER${i}_CTX:-}"
    eval "apiserver=\${CLUSTER${i}_API_SERVER:-}"
    eval "name=\${CLUSTER${i}_NAME:-}"
    eval "iaas=\${CLUSTER${i}_IAAS_TYPE:-}"

    if [ -z "$ctx" ] || [ -z "$apiserver" ] || [ -z "$name" ] || [ -z "$iaas" ]; then
      echo -e "  ${RED}✘ Missing required fields${RESET}"
      FAILED_CLUSTERS+=("$name")
      FAILED_REASON+=("Missing required fields")
      continue
    fi

    [[ "$iaas" =~ ^[0-9]+$ ]] && idx=$((iaas - 1)) || idx=0
    (( idx < 0 || idx >= ${#MEMBER_IAAS_TYPE[@]} )) && idx=0
    iaas_type="${MEMBER_IAAS_TYPE[$idx]}"

    apply_fed_sa "$ctx"

    token=$(get_cluster_token "$ctx")
    if [ -z "$token" ]; then
      echo -e "  ${RED}✘ Failed:${RESET} Token not found"
      FAILED_CLUSTERS+=("$name")
      FAILED_REASON+=("Token not found")
      continue
    fi

    if ! register_cluster_to_portal "$name" "$apiserver" "$iaas_type" "$token"; then
      echo -e "  ${RED}✘ Failed:${RESET} ${FAILED_REASON[-1]}"
      FAILED_CLUSTERS+=("$name")
      continue
    fi

    echo -e "  ${GREEN}✔ OK${RESET}"
    SUCCESS_CLUSTERS_BY_CTX+=("$ctx")
    SUCCESS_CLUSTERS_BY_NAME+=("$name")
  done

  echo ""
  echo -e "${BOLD}${BLUE}▶ Portal Registration Summary${RESET}"

  if [ "${#SUCCESS_CLUSTERS_BY_NAME[@]}" -gt 0 ]; then
    echo -e "${GREEN}✔ Successful clusters:${RESET}"
    printf '  - %s\n' "${SUCCESS_CLUSTERS_BY_NAME[@]}"
  else
    echo -e "${RED}✘ No successful clusters.${RESET}"
  fi

  if [ "${#FAILED_CLUSTERS[@]}" -gt 0 ]; then
    echo ""
    echo -e "${RED}✘ Failed clusters:${RESET}"
    for i in "${!FAILED_CLUSTERS[@]}"; do
      echo -e "  - ${FAILED_CLUSTERS[$i]} : ${FAILED_REASON[$i]}"
    done
  fi
}

#############################################
# Federation registration
#############################################
register_federation_members() {
  echo ""
  echo -e "${BOLD}${BLUE}▶ Register federation members${RESET}"

  resp=$(call_api GET "${CP_PORTAL_URL}/cpfed/api/v1/registrable-clusters" "$CP_PORTAL_ADMIN_TOKEN")

  REG_NAMES=($(echo "$resp" | grep -o '"name"[ ]*:[ ]*"[^"]*"' | sed 's/"name"[ ]*:[ ]*"//;s/"//'))
  REG_IDS=($(echo "$resp" | grep -o '"clusterId"[ ]*:[ ]*"[^"]*"' | sed 's/"clusterId"[ ]*:[ ]*"//;s/"//'))

  local target_ids=()

  for name in "${SUCCESS_CLUSTERS_BY_NAME[@]}"; do
    local idx=0 found=""
    for rn in "${REG_NAMES[@]}"; do
      if [ "$rn" = "$name" ]; then
        found="${REG_IDS[$idx]}"
        break
      fi
      idx=$((idx+1))
    done

    if [ -n "$found" ]; then
      echo -e "  ${GREEN}✔ target:${RESET} $name ($found)"
      target_ids+=("$found")
    else
      echo -e "  ${YELLOW}• skip:${RESET} $name (not registrable)"
    fi
  done

  if [ "${#target_ids[@]}" -eq 0 ]; then
    echo -e "${YELLOW}• No federation candidates.${RESET}"
    return 0
  fi

  list="["; for id in "${target_ids[@]}"; do list="${list}\"${id}\","; done
  list="${list%,}]"

  payload="{\"clusterIds\": $list}"

  resp=$(call_api POST "${CP_PORTAL_URL}/cpfed/api/v1/cluster" "$CP_PORTAL_ADMIN_TOKEN" "$payload")

  echo ""
  echo -e "${BOLD}${BLUE}▶ Federation registration result${RESET}"

  mapfile -t RESP_CLUSTER_IDS < <(echo "$resp" | grep -o '"clusterId":[ ]*"[^"]*"' | sed 's/"clusterId":[ ]*"//;s/"$//')
  mapfile -t RESP_CLUSTER_NAMES < <(echo "$resp" | grep -o '"name":[ ]*"[^"]*"' | sed 's/"name":[ ]*"//;s/"$//')
  mapfile -t RESP_CODES < <(echo "$resp" | grep -o '"code":[ ]*[0-9]*' | sed 's/"code":[ ]*//')
  mapfile -t RESP_MSGS < <(echo "$resp" | grep -o '"message":[ ]*"[^"]*"' | sed 's/"message":[ ]*"//;s/"$//')

  local len="${#RESP_CLUSTER_IDS[@]}"
  (( ${#RESP_CLUSTER_NAMES[@]} < len )) && len="${#RESP_CLUSTER_NAMES[@]}"
  (( ${#RESP_CODES[@]} < len )) && len="${#RESP_CODES[@]}"
  (( ${#RESP_MSGS[@]} < len )) && len="${#RESP_MSGS[@]}"

  for ((i=0; i<len; i++)); do
    cid="${RESP_CLUSTER_IDS[$i]}"
    name="${RESP_CLUSTER_NAMES[$i]}"
    code="${RESP_CODES[$i]}"
    msg="${RESP_MSGS[$i]}"

    if [ "$code" = "201" ]; then
      echo -e "  ${GREEN}✔ $name${RESET} ($cid): $msg"
    else
      echo -e "  ${RED}✘ $name${RESET} ($cid): $msg"
    fi
  done
}

#############################################
# Main
#############################################
main() {
  if [ "$MEMBER_CLUSTER_CONFIG_MISSING" = true ]; then
    echo "member-cluster-config.sh not found. Exit."
    exit 0
  fi

  count=$(detect_cluster_max_index)
  if ! [[ "$count" =~ ^[0-9]+$ ]]; then
    echo "Invalid cluster count. Exit."
    exit 1
  fi

  if [ "$count" -eq 0 ]; then
    echo "No member clusters defined. Exit."
    exit 0
  fi

  wait_core          || exit 1
  admin_signup       || exit 1
  admin_login        || exit 1

  register_member_clusters
  register_federation_members

  echo ""
  echo -e "${GREEN}✔ Done.${RESET}"
}

main