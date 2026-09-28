#!/bin/bash
CURL_CMD="curl --silent --show-error -k"
SECMG_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=openbao-common.sh
source "$SECMG_SCRIPT_DIR/openbao-common.sh"

# 1.Deploy Secrets Management
for IDX in 2 1; do
  echo "[Deploy resources in cluster${IDX}]..."
  TARGET_CTX="CLUSTER${IDX}_CONFIG[CTX]"
  CMD_KCTL=$(echo "$CMD_KCTL_ORIG" | sed "s/{TG_CTX}/${!TARGET_CTX}/")
  CMD_HELM=$(echo "$CMD_HELM_ORIG" | sed "s/{TG_CTX}/${!TARGET_CTX}/")
  $CMD_KCTL create namespace ${NAMESPACE[0]}
  $CMD_KCTL label namespace ${NAMESPACE[0]} $CMD_ISTIO_INJECTION
  if [ ${IDX} -eq 1 ]
  then
    helm_install 0
  else
    $CMD_HELM template -f ../values/${CHART_NAME[0]}.yaml ${CHART_NAME[0]} $(chart_path_for 0) -s templates/server-service.yaml -n ${NAMESPACE[0]} | $CMD_KCTL apply -f -
  fi
done

# 2.Wait, initialize, and verify unseal
OPENBAO_NAMESPACE=${NAMESPACE[0]}
OPENBAO_KUBECTL_CMD=$CMD_KCTL
start_openbao_port_forward || return 1
prepare_openbao || { stop_openbao_port_forward; return 1; }

# 5.Enable AppRole
${CURL_CMD} \
    -H "X-Vault-Token: ${SECMG_ROOT_TOKEN}" \
    -X POST \
    -d '{"type": "approle"}' \
    "${SECMG_URL}/v1/sys/auth/approle"

# 6.Enable Secrets Engine
${CURL_CMD} \
    -H "X-Vault-Token: ${SECMG_ROOT_TOKEN}" \
    -X POST \
    -d '{"type":"kv-v2", "options": {"version": "2"}}' \
    "${SECMG_URL}/v1/sys/mounts/secret"

# 7.Create Secrets
## cluster1 config
${CURL_CMD} --output /dev/null \
    -H "X-Vault-Token: ${SECMG_ROOT_TOKEN}" \
    -X POST \
    -d '{"data":{"clusterId":'"\"${CLUSTER1_CONFIG[CLUSTER_ID]}\""', "clusterApiUrl":'"\"${CLUSTER1_CONFIG[API_SERVER]}\""', "clusterToken":'"\"${CLUSTER1_CONFIG[CLUSTER_TOKEN]}\""'}}' \
    "${SECMG_URL}/v1/secret/data/cluster/${CLUSTER1_CONFIG[CLUSTER_ID]}"

## cluster2 config
${CURL_CMD} --output /dev/null \
    -H "X-Vault-Token: ${SECMG_ROOT_TOKEN}" \
    -X POST \
    -d '{"data":{"clusterId":'"\"${CLUSTER2_CONFIG[CLUSTER_ID]}\""', "clusterApiUrl":'"\"${CLUSTER2_CONFIG[API_SERVER]}\""', "clusterToken":'"\"${CLUSTER2_CONFIG[CLUSTER_TOKEN]}\""'}}' \
    "${SECMG_URL}/v1/secret/data/cluster/${CLUSTER2_CONFIG[CLUSTER_ID]}"

# 8.Create Policy
${CURL_CMD} \
    -H "X-Vault-Token: ${SECMG_ROOT_TOKEN}" \
    -X POST \
    -d '{"policy":"path \"secret/*\" { capabilities = [\"create\", \"update\", \"delete\", \"read\", \"list\"] } "}' \
    "${SECMG_URL}/v1/sys/policy/cp_policy"

# 9.Create AppRole
${CURL_CMD} \
    -H "X-Vault-Token: ${SECMG_ROOT_TOKEN}" \
    -X POST \
    -d @../secmg/payload.json \
    "${SECMG_URL}/v1/auth/approle/role/${SECMG_ROLE_NAME}"

# 10.Get Role ID
SECMG_GET_ROLE_ID_RESP=$(${CURL_CMD} \
    -H "X-Vault-Token: ${SECMG_ROOT_TOKEN}" \
    -X GET \
    "${SECMG_URL}/v1/auth/approle/role/${SECMG_ROLE_NAME}/role-id")
SECMG_ROLE_ID=`echo $SECMG_GET_ROLE_ID_RESP | sed 's/.*role_id":"//g' | sed 's/".*//g'`

# 11.Get Secret ID
SECMG_GET_SECRET_ID_RESP=$(${CURL_CMD} \
    -H "X-Vault-Token: ${SECMG_ROOT_TOKEN}" \
    -X POST \
    "${SECMG_URL}/v1/auth/approle/role/${SECMG_ROLE_NAME}/secret-id")
SECMG_SECRET_ID=`echo $SECMG_GET_SECRET_ID_RESP | sed 's/.*secret_id":"//g' | sed 's/".*//g'`

stop_openbao_port_forward
unset SECMG_ROOT_TOKEN
