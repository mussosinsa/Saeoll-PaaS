#!/bin/bash
CURL_CMD="curl --silent --show-error -k"
SECMG_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=openbao-common.sh
source "$SECMG_SCRIPT_DIR/openbao-common.sh"

# 1.Deploy Secrets Management
kubectl create namespace ${NAMESPACE[0]}
$CMD_CREATE_TLS_SECRET -n ${NAMESPACE[0]}
helm_install 0
echo

# 2.Wait, initialize, and verify unseal
prepare_openbao || return 1

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
${CURL_CMD} --output /dev/null \
    -H "X-Vault-Token: ${SECMG_ROOT_TOKEN}" \
    -X POST \
    -d '{"data":{"clusterId":'"\"${HOST_CLUSTER_ID}\""', "clusterApiUrl":'"\"${K8S_CLUSTER_API_SERVER}\""', "clusterToken":'"\"${K8S_CLUSTER_ADMIN_TOKEN}\""'}}' \
    "${SECMG_URL}/v1/secret/data/cluster/${HOST_CLUSTER_ID}"

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

unset SECMG_ROOT_TOKEN
