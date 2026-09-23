#!/bin/bash
CURL_CMD="curl --silent --show-error -k"

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

# 2.Check Status
while :
do
  SECMG_STATUS_HTTP_CODE=$(curl -L -k -s -o /dev/null -w "%{http_code}\n" ${SECMG_URL}/v1/sys/init)
  echo "[$SECMG_STATUS_HTTP_CODE] Please wait until the secrets management service is deployed..."
  if [ $SECMG_STATUS_HTTP_CODE -eq 200 ]; then
    break
  fi
  sleep 5
done

# 3.Init
SECMG_INIT_RESP=$(${CURL_CMD} \
    -X POST \
    -d '{"secret_shares": 3, "secret_threshold": 2}' \
    "${SECMG_URL}/v1/sys/init")
echo $SECMG_INIT_RESP | sed 's/.*{//g' | sed 's/,"root_token".*//g' > ../secmg/unseal-key
SECMG_ROOT_TOKEN=`echo $SECMG_INIT_RESP | sed 's/.*root_token":"//g' | sed 's/".*//g'`
SECMG_UNSEAL_KEY_BASE64_STR=(`echo $SECMG_INIT_RESP | sed 's/.*keys_base64":\[//g' | sed 's/],"root_token".*//g' | tr -d '"'`)
declare -a SECMG_UNSEAL_KEY_ARR=($(echo $SECMG_UNSEAL_KEY_BASE64_STR | tr "," " "))

# 4.Unseal
${CURL_CMD} --output /dev/null \
    -X POST \
    -d '{"key":'"\"${SECMG_UNSEAL_KEY_ARR[0]}\""'}' \
    "${SECMG_URL}/v1/sys/unseal"

${CURL_CMD} --output /dev/null \
    -X POST \
    -d '{"key":'"\"${SECMG_UNSEAL_KEY_ARR[1]}\""'}' \
    "${SECMG_URL}/v1/sys/unseal"

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

unset SECMG_INIT_RESP
unset SECMG_UNSEAL_KEY_BASE64_STR
unset SECMG_UNSEAL_KEY_ARR
unset SECMG_ROOT_TOKEN