#!/bin/bash
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/rocky-linux.sh
source "$SCRIPT_DIR/../lib/rocky-linux.sh"
require_rocky_linux_9_7 || exit 1
source cp-portal-vars-mc.sh
declare -A DEPLOY_CONFIG
DEPLOY_CONFIG[IPV6_ENABLED]=true
DEPLOY_CONFIG[INGRESS_ENABLED]=false
DEPLOY_CONFIG[EXPOSE_TYPE]="clusterIP"
CMD_KCTL_ORIG="kubectl --context={TG_CTX}"
CMD_HELM_ORIG="helm --kube-context={TG_CTX}"
CMD_ISTIO_INJECTION="istio-injection=enabled --overwrite"
APP_UI="cp-portal-ui"
APP_TERRAMAN="cp-portal-terraman"
# -----------------------------------------------------------------------------
# helm_install <index> [release_name] [namespace] [additional helm install args...]
# Examples:
#   helm_install 0
#   helm_install 1 "my-release" "default" --set key=value --wait
#   helm_install 4 "$RELEASE_NAME" "" --set key=value
# -----------------------------------------------------------------------------
helm_install() {
  local index=$1
  local chart_name="${CHART_NAME[$index]}"
  local release_name="${2:-$chart_name}"
  local namespace="${3:-${NAMESPACE[$index]}}"
  local version="${CHART_VERSION[$chart_name]}"
  local value_path="../values/${release_name}.yaml"
  local chart_path="../charts/${chart_name}-${version}.tgz"

  shift $(( $# < 3 ? $# : 3 ))
  $CMD_HELM install -f "$value_path" "$release_name" "$chart_path" -n "$namespace" "$@"
}
chart_pull(){
  mkdir -p ../charts
  for CHART in ${CHART_NAME[@]}; do
    FILE="../charts/${CHART}-${CHART_VERSION[$CHART]}.tgz"
    [ -f "$FILE" ] || $CMD_HELM pull -d ../charts "$K_PAAS_HELM_OCI_REPO/$CHART" --version "${CHART_VERSION[$CHART]}"
  done
}
chart_path_for() {
  echo "../charts/${CHART_NAME[$1]}-${CHART_VERSION[${CHART_NAME[$1]}]}.tgz"
}
wait_for_pod_ready() {
  local ns="$1" label="$2" interval="${3:-5}"
  echo "Waiting for all pods [$label] in namespace [$ns]..."
  while :; do
    pods=$($CMD_KCTL --request-timeout=5s get pods -n "$ns" -l "$label" --no-headers 2>/dev/null)
    [[ -z "$pods" ]] && echo "[NotFound] No pods found for [$label]" && sleep "$interval" && continue
    total=$(echo "$pods" | wc -l)
    ready=$(echo "$pods" | awk '{print $2}' | grep -Eo '[0-9]+/[0-9]+' | awk -F/ '$1==$2' | wc -l)
    echo "Ready: [$ready/$total] $label"
    [[ "$ready" -eq "$total" ]] && break
    sleep "$interval"
  done
  echo "All pods [$label] are ready."
}
inject_cert_and_build_image() {
  BUILD_APPS=(
    "cp-portal-ui"
    "cp-portal-migration-ui"
  )

  TEMPLATE="../values/ui/Dockerfile.template"
  OUTPUT="../values/ui/Dockerfile"
  CRT_FILE="ca.crt"

  cp ../certs/ca.crt ../values/ui
  for APP_NAME in "${BUILD_APPS[@]}"; do
    sed -e "s|{APP_NAME}|${APP_NAME}|g" \
        -e "s|{CRT_FILE}|${CRT_FILE}|g" \
        "$TEMPLATE" > "$OUTPUT"

    sudo podman build -t "$REPOSITORY_HOST/$REPOSITORY_PROJECT_NAME/$APP_NAME:$IMAGE_TAGS" ../values/ui
    sudo podman push "$REPOSITORY_HOST/$REPOSITORY_PROJECT_NAME/$APP_NAME:$IMAGE_TAGS"

    rm -f "$OUTPUT"
  done

}
### EXECUTION ########################################
for IDX in 1 2; do
  echo "[Create resources in cluster${IDX}]..."
  TARGET_CTX="CLUSTER${IDX}_CONFIG[CTX]"
  TARGET_IAAS_TYPE="CLUSTER${IDX}_CONFIG[IAAS_TYPE]"
  CMD_KCTL=$(echo "$CMD_KCTL_ORIG" | sed "s/{TG_CTX}/${!TARGET_CTX}/")
  $CMD_KCTL create sa $K8S_CLUSTER_ADMIN -n $K8S_CLUSTER_ADMIN_NAMESPACE
  $CMD_KCTL create clusterrolebinding $K8S_CLUSTER_ADMIN --clusterrole=cluster-admin --serviceaccount=$K8S_CLUSTER_ADMIN_NAMESPACE:$K8S_CLUSTER_ADMIN
  declare CLUSTER${IDX}_CONFIG[CLUSTER_TOKEN]=$($CMD_KCTL create token $K8S_CLUSTER_ADMIN --duration=999999h -n $K8S_CLUSTER_ADMIN_NAMESPACE)
  declare CLUSTER${IDX}_CONFIG[CLUSTER_ID]=$(uuidgen)
  declare CLUSTER${IDX}_CONFIG[CLUSTER_NAME]="cluster-${IDX}"
  if [[ ${!TARGET_IAAS_TYPE} -lt 1 ]] || [[ ${!TARGET_IAAS_TYPE} -gt ${#IAAS_TYPE[@]} ]]
  then
    declare CLUSTER${IDX}_CONFIG[IAAS_TYPE]="1"
  fi
done

# ipv6Enabled set to false if cluster1's iaas type is NAVER
if [[ $((CLUSTER1_CONFIG[IAAS_TYPE] -1)) -eq 2 ]]
then
  DEPLOY_CONFIG[IPV6_ENABLED]=false
fi

CMD_KCTL=$(echo "$CMD_KCTL_ORIG" | sed "s/{TG_CTX}/${CLUSTER1_CONFIG[CTX]}/")
CMD_HELM=$(echo "$CMD_HELM_ORIG" | sed "s/{TG_CTX}/${CLUSTER1_CONFIG[CTX]}/")

# Create a secrets mgmt bound cidr
SECMG_BOUND_CIDR_ARR=($($CMD_KCTL get pods -n $ISTIO_NAMESPACE --selector=$ISTIO_INGRESSGATEWAY_SELECTOR --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{@.status.podIP}{"/16"}{"\t"}{end}'))
printf -v SECMG_BOUND_CIDR '"%s",' "${SECMG_BOUND_CIDR_ARR[@]}"
SECMG_BOUND_CIDR="${SECMG_BOUND_CIDR%,}"

# Copy the directory
cp -r ../secmg_orig ../secmg
cp -r ../values_orig ../values

# Replace values
REPOSITORY_HOST=$(echo $REPOSITORY_URL | awk -F[/:] '{print $4}')
find ../secmg -name "payload.json" -exec sed -i "s@{SECMG_BOUND_CIDR}@$SECMG_BOUND_CIDR@g" {} +
find ../values -type f -exec sed -i "s@{K_PAAS_REGISTRY}@$K_PAAS_REGISTRY@g" {} +
find ../values -type f -exec sed -i "s/{K_PAAS_REPO}/$K_PAAS_REPO/g" {} +
find ../values -type f -exec sed -i "s@{CP_PORTAL_URL}@$CP_PORTAL_URL@g" {} +
find ../values -type f -exec sed -i "s@{CP_SERVICE_PIPELINE_URL}@$CP_SERVICE_PIPELINE_URL@g" {} +
find ../values -type f -exec sed -i "s@{CP_SERVICE_SOURCE_CONTROL_URL}@$CP_SERVICE_SOURCE_CONTROL_URL@g" {} +
find ../values -type f -exec sed -i "s/{K8S_MASTER_NODE_IP}/${CLUSTER1_CONFIG[MASTER_NODE_IP]}/g" {} +
find ../values -type f -exec sed -i "s/{HOST_DOMAIN}/$HOST_DOMAIN/g" {} +
find ../values -type f -exec sed -i "s/{CLUSTER1_ID}/${CLUSTER1_CONFIG[CLUSTER_ID]}/g" {} +
find ../values -type f -exec sed -i "s/{CLUSTER1_NAME}/${CLUSTER1_CONFIG[CLUSTER_NAME]}/g" {} +
find ../values -type f -exec sed -i "s/{CLUSTER1_IAAS_TYPE}/${IAAS_TYPE[${CLUSTER1_CONFIG[IAAS_TYPE]} -1]}/g" {} +
find ../values -type f -exec sed -i "s/{CLUSTER2_ID}/${CLUSTER2_CONFIG[CLUSTER_ID]}/g" {} +
find ../values -type f -exec sed -i "s/{CLUSTER2_NAME}/${CLUSTER2_CONFIG[CLUSTER_NAME]}/g" {} +
find ../values -type f -exec sed -i "s/{CLUSTER2_IAAS_TYPE}/${IAAS_TYPE[${CLUSTER2_CONFIG[IAAS_TYPE]} -1]}/g" {} +
find ../values -type f -exec sed -i "s/{IMAGE_TAGS}/$IMAGE_TAGS/g" {} +
find ../values -type f -exec sed -i "s/{IMAGE_PULL_POLICY}/$IMAGE_PULL_POLICY/g" {} +
find ../values -type f -exec sed -i "s/{IMAGE_PULL_SECRET}/$IMAGE_PULL_SECRET/g" {} +
find ../values -type f -exec sed -i "s/{TLS_SECRET}/$TLS_SECRET/g" {} +
find ../values -type f -exec sed -i "s/{SERVICE_TYPE}/$SERVICE_TYPE/g" {} +
find ../values -type f -exec sed -i "s/{SERVICE_PROTOCOL}/$SERVICE_PROTOCOL/g" {} +
find ../values -type f -exec sed -i "s/{ISTIO_NAMESPACE}/$ISTIO_NAMESPACE/g" {} +
find ../values -type f -exec sed -i "s/{SECMG_NAMESPACE}/${NAMESPACE[0]}/g" {} +
find ../values -type f -exec sed -i "s/{SECMG_HOST}/$(echo $SECMG_URL | awk -F[/:] '{print $4}')/g" {} +
find ../values -type f -exec sed -i "s/{SECMG_ROLE_NAME}/$SECMG_ROLE_NAME/g" {} +
find ../values -type f -exec sed -i "s/{SECMG_STORAGECLASS}/${CLUSTER1_CONFIG[STORAGECLASS]}/g" {} +
find ../values -type f -exec sed -i "s/{REPOSITORY_NAMESPACE}/${NAMESPACE[2]}/g" {} +
find ../values -type f -exec sed -i "s@{REPOSITORY_URL}@$REPOSITORY_URL@g" {} +
find ../values -type f -exec sed -i "s/{REPOSITORY_HOST}/$REPOSITORY_HOST/g" {} +
find ../values -type f -exec sed -i "s/{REPOSITORY_USERNAME}/$REPOSITORY_USERNAME/g" {} +
find ../values -type f -exec sed -i "s/{REPOSITORY_PASSWORD}/$REPOSITORY_PASSWORD/g" {} +
find ../values -type f -exec sed -i "s/{REPOSITORY_PROJECT_NAME}/$REPOSITORY_PROJECT_NAME/g" {} +
find ../values -type f -exec sed -i "s/{REPOSITORY_STORAGECLASS}/${CLUSTER1_CONFIG[STORAGECLASS]}/g" {} +
find ../values -type f -exec sed -i "s/{DATABASE_URL}/$DATABASE_URL/g" {} +
find ../values -type f -exec sed -i "s/{DATABASE_HOST}/$(echo "${DATABASE_URL%:*}")/g" {} +
find ../values -type f -exec sed -i "s/{DATABASE_PORT}/$(echo "${DATABASE_URL#*:}")/g" {} +
find ../values -type f -exec sed -i "s/{DATABASE_USER_ID}/$DATABASE_USER_ID/g" {} +
find ../values -type f -exec sed -i "s/{DATABASE_USER_PASSWORD}/$DATABASE_USER_PASSWORD/g" {} +
find ../values -type f -exec sed -i "s/{DATABASE_TERRAMAN_ID}/$DATABASE_TERRAMAN_ID/g" {} +
find ../values -type f -exec sed -i "s/{DATABASE_TERRAMAN_PASSWORD}/$DATABASE_TERRAMAN_PASSWORD/g" {} +
find ../values -type f -exec sed -i "s/{DATABASE_STORAGECLASS}/${CLUSTER2_CONFIG[STORAGECLASS]}/g" {} +
find ../values -type f -exec sed -i "s/{KEYCLOAK_NAMESPACE}/${NAMESPACE[3]}/g" {} +
find ../values -type f -exec sed -i "s@{KEYCLOAK_URL}@$KEYCLOAK_URL@g" {} +
find ../values -type f -exec sed -i "s/{KEYCLOAK_DB_VENDOR}/$KEYCLOAK_DB_VENDOR/g" {} +
find ../values -type f -exec sed -i "s/{KEYCLOAK_DB_SCHEMA}/$KEYCLOAK_DB_SCHEMA/g" {} +
find ../values -type f -exec sed -i "s/{KEYCLOAK_ADMIN_USERNAME}/$KEYCLOAK_ADMIN_USERNAME/g" {} +
find ../values -type f -exec sed -i "s/{KEYCLOAK_ADMIN_PASSWORD}/$KEYCLOAK_ADMIN_PASSWORD/g" {} +
find ../values -type f -exec sed -i "s/{KEYCLOAK_SESSIONS_COUNT}/$KEYCLOAK_SESSIONS_COUNT/g" {} +
find ../values -type f -exec sed -i "s/{KEYCLOAK_CP_REALM}/$KEYCLOAK_CP_REALM/g" {} +
find ../values -type f -exec sed -i "s/{KEYCLOAK_CP_REALM_ID}/$KEYCLOAK_CP_REALM_ID/g" {} +
find ../values -type f -exec sed -i "s/{KEYCLOAK_CP_CLIENT_ID}/$KEYCLOAK_CP_CLIENT_ID/g" {} +
find ../values -type f -exec sed -i "s/{KEYCLOAK_CP_CLIENT_SECRET}/$KEYCLOAK_CP_CLIENT_SECRET/g" {} +
find ../values -type f -exec sed -i "s/{KEYCLOAK_HOST}/$(echo $KEYCLOAK_URL | awk -F[/:] '{print $4}')/g" {} +
find ../values -type f -exec sed -i "s/{CHART_REPOSITORY_NAMESPACE}/${NAMESPACE[5]}/g" {} +
find ../values -type f -exec sed -i "s/{CHART_REPOSITORY_STORAGECLASS}/${CLUSTER1_CONFIG[STORAGECLASS]}/g" {} +
find ../values -type f -exec sed -i "s/{CHART_REPOSITORY_NAME}/$CHART_REPOSITORY_NAME/g" {} +
find ../values -type f -exec sed -i "s@{CHART_REPOSITORY_URL}@$CHART_REPOSITORY_URL@g" {} +
find ../values -type f -exec sed -i "s/{CHART_REPOSITORY_HOST}/$(echo $CHART_REPOSITORY_URL | awk -F[/:] '{print $4}')/g" {} +
find ../values -type f -exec sed -i "s/{CHAOS_MESH_NAMESPACE}/${NAMESPACE[6]}/g" {} +
find ../values -type f -exec sed -i "s/{NAMESPACE}/${NAMESPACE[4]}/g" {} +
find ../values -type f -exec sed -i "s@{CP_PORTAL_URL}@$CP_PORTAL_URL@g" {} +
find ../values -type f -exec sed -i "s/{CP_PORTAL_HOST}/$(echo $CP_PORTAL_URL | awk -F[/:] '{print $4}')/g" {} +
find ../values -type f -exec sed -i "s/{CP_PORTAL_STORAGECLASS}/${CLUSTER1_CONFIG[STORAGECLASS]}/g" {} +
find ../values -type f -exec sed -i "s/{CP_CERT_SETUP_NAME}/${CHART_NAME[7]}/g" {} +
find ../values -type f -exec sed -i "s/{CP_CERT_SETUP_NAMESPACE}/$CP_CERT_SETUP_NAMESPACE/g" {} +
find ../values -type f -exec sed -i "s/{IPV6_ENABLED}/${DEPLOY_CONFIG[IPV6_ENABLED]}/g" {} +
find ../values -type f -exec sed -i "s/{INGRESS_ENABLED}/${DEPLOY_CONFIG[INGRESS_ENABLED]}/g" {} +
find ../values -type f -exec sed -i "s/{EXPOSE_TYPE}/${DEPLOY_CONFIG[EXPOSE_TYPE]}/g" {} +
find ../values -type f -exec sed -i "s/{INGRESS_CLASS_NAME}//g" {} +
# Pull the chart to prepare for installation
chart_pull

# Generate cert and enc_keys
for f in gen-cert.sh gen-enc-keys.sh; do
  chmod +x "../script/$f" && . "../script/$f"
done

# Deploy istio resources
$CMD_HELM install -f ../values/$ISTIO_RESOURCE_NAME.yaml $ISTIO_RESOURCE_NAME $(chart_path_for 4) -n $ISTIO_NAMESPACE \
          --set-string tlsSecret.tls.crt=$(base64 -w 0 < ../certs/${HOST_DOMAIN}.crt) \
          --set-string tlsSecret.tls.key=$(base64 -w 0 < ../certs/${HOST_DOMAIN}.key)

for IDX in 1 2; do
  echo "[Adding certificates in cluster${IDX}]..."
  TARGET_CTX="CLUSTER${IDX}_CONFIG[CTX]"
  CMD_KCTL=$(echo "$CMD_KCTL_ORIG" | sed "s/{TG_CTX}/${!TARGET_CTX}/")
  CMD_HELM=$(echo "$CMD_HELM_ORIG" | sed "s/{TG_CTX}/${!TARGET_CTX}/")
  # Setup the cert to each node
  helm_install 7 "" $CP_CERT_SETUP_NAMESPACE --set data.target.cert="$(cat ../certs/ca.crt)"
  while :
  do
    POD_COUNT=$(($CMD_KCTL get pods -n $CP_CERT_SETUP_NAMESPACE -l $CP_CERT_SETUP_SELECTOR --field-selector status.phase!=Running --no-headers | wc -l) 2> /dev/null)
    echo "[remaining: $POD_COUNT] Adding certificates to each node’s container runtime..."
    if [[ $POD_COUNT -lt 1 ]]; then
      echo "Completed..."
      break
    fi
    sleep 5
  done
done
install_host_ca "../certs/ca.crt" "${HOST_DOMAIN}-ca.crt"

# Deploy the secrets management
chmod +x ../secmg/deploy-secmg-mc.sh
. ../secmg/deploy-secmg-mc.sh
find ../values -type f -exec sed -i "s/{SECMG_ROLE_ID}/$SECMG_ROLE_ID/g" {} +
find ../values -type f -exec sed -i "s/{SECMG_SECRET_ID}/$SECMG_SECRET_ID/g" {} +

# Deploy the mariadb
for IDX in 2 1; do
  echo "[Deploy resources in cluster${IDX}]..."
  TARGET_CTX="CLUSTER${IDX}_CONFIG[CTX]"
  CMD_KCTL=$(echo "$CMD_KCTL_ORIG" | sed "s/{TG_CTX}/${!TARGET_CTX}/")
  CMD_HELM=$(echo "$CMD_HELM_ORIG" | sed "s/{TG_CTX}/${!TARGET_CTX}/")
  $CMD_KCTL create namespace ${NAMESPACE[1]}
  $CMD_KCTL label namespace ${NAMESPACE[1]} $CMD_ISTIO_INJECTION
  if [ ${IDX} -eq 1 ]
  then
    $CMD_HELM template -f ../values/${CHART_NAME[1]}.yaml ${CHART_NAME[1]} $(chart_path_for 1) \
              -s templates/primary/svc.yaml -n ${NAMESPACE[1]} | $CMD_KCTL apply -f -
  else
    $CMD_KCTL apply -f ../values/${CHART_NAME[1]}-configmap-mc.yaml -n ${NAMESPACE[1]}
    helm_install 1
  fi
done

# Deploy the harbor
$CMD_KCTL create namespace ${NAMESPACE[2]}
helm_install 2
while :
do
  REPOSITORY_HTTP_CODE=$(curl -L -k -s -o /dev/null -w "%{http_code}\n" $REPOSITORY_URL/api/v2.0/projects)
  echo "[$REPOSITORY_HTTP_CODE] Please wait a few minutes until Harbor is deployed..."
  if [ $REPOSITORY_HTTP_CODE -eq 200 ]; then
    break
  fi
  sleep 10
done
curl -u $REPOSITORY_USERNAME:$REPOSITORY_PASSWORD -k $REPOSITORY_URL/api/v2.0/projects -XPOST --data-binary "{\"project_name\": \"$REPOSITORY_PROJECT_NAME\", \"public\": false}" -H "Content-Type: application/json" -i
sudo podman login $REPOSITORY_HOST --username $REPOSITORY_USERNAME --password $REPOSITORY_PASSWORD

# Build ui image by adding generated self-signed certificate into keystore
inject_cert_and_build_image

# Deploy the keycloak
$CMD_KCTL create namespace ${NAMESPACE[3]}
$CMD_KCTL label namespace ${NAMESPACE[3]} $CMD_ISTIO_INJECTION
$CMD_KCTL create configmap $KEYCLOAK_CP_REALM --from-file=../values/$KEYCLOAK_CP_REALM-realm.json -n ${NAMESPACE[3]}
helm_install 3

# Deploy the chartmuseum
$CMD_KCTL create namespace ${NAMESPACE[5]}
helm_install 5
while :
do
  CHART_REPOSITORY_HTTP_CODE=$(curl -L -k -s -o /dev/null -w "%{http_code}\n" $CHART_REPOSITORY_URL/index.yaml)
  echo "[$CHART_REPOSITORY_HTTP_CODE] Check the status of ChartMuseum..."
  if [ $CHART_REPOSITORY_HTTP_CODE -eq 200 ]; then
    break
  fi
  sleep 5
done

$CMD_HELM plugin install https://github.com/chartmuseum/helm-push.git
$CMD_HELM repo add $CHART_REPOSITORY_NAME $CHART_REPOSITORY_URL

# Deploy the chaos-mesh
$CMD_KCTL create namespace ${NAMESPACE[6]}
helm_install 6

# Deploy the cp-portal
for IDX in 2 1; do
  echo "[Deploy resources in cluster${IDX}]..."
  TARGET_CTX="CLUSTER${IDX}_CONFIG[CTX]"
  CMD_KCTL=$(echo "$CMD_KCTL_ORIG" | sed "s/{TG_CTX}/${!TARGET_CTX}/")
  CMD_HELM=$(echo "$CMD_HELM_ORIG" | sed "s/{TG_CTX}/${!TARGET_CTX}/")
  $CMD_KCTL create namespace ${NAMESPACE[4]}
  $CMD_KCTL label namespace ${NAMESPACE[4]} $CMD_ISTIO_INJECTION
  if [ ${IDX} -eq 1 ]
  then
    # ui,api,chaos-api,chaos-collector,terraman,catalog-api
    $CMD_HELM install -f ../values/${RELEASE_NAME}-mc1.yaml -f ../values/cp-portal-migration-secret.yaml \
              ${RELEASE_NAME} $(chart_path_for 4) -n ${NAMESPACE[4]} \
              --set-string secret[0].data.CHART_REPO_CRT=$(base64 -w 0 < ../certs/ca.crt)
    # common-api-svc,metric-api-svc
    $CMD_HELM template -f ../values/${RELEASE_NAME}-mc2.yaml -f ../values/cp-portal-migration-secret.yaml \
              ${RELEASE_NAME} $(chart_path_for 4) -n ${NAMESPACE[4]} \
              -s templates/service.yaml -n ${NAMESPACE[4]} | $CMD_KCTL apply -f -
  else
    # common-api,metric-api
    $CMD_HELM install -f ../values/${RELEASE_NAME}-mc2.yaml -f ../values/cp-portal-migration-secret.yaml \
              ${RELEASE_NAME} $(chart_path_for 4) -n ${NAMESPACE[4]} \
              --set-string secret[0].data.CHART_REPO_CRT=$(base64 -w 0 < ../certs/ca.crt)
  fi
  # Uninstall cp-cert-setup
  $CMD_HELM uninstall ${CHART_NAME[7]} -n $CP_CERT_SETUP_NAMESPACE
done

wait_for_pod_ready ${NAMESPACE[4]} "app=$APP_TERRAMAN" 10
CP_PORTAL_TERRAMAN_POD="$($CMD_KCTL get pods -n ${NAMESPACE[4]} -l app=$APP_TERRAMAN -o=jsonpath='{.items[0].metadata.name}')"
SSH_KEY_FILE=$HOME/.ssh/id_rsa
if [ ! -e "$SSH_KEY_FILE" ]; then
    ssh-keygen -q -t rsa -N '' -f $SSH_KEY_FILE <<<y >/dev/null 2>&1
    GEN_SSH_KEY=$(cat "$SSH_KEY_FILE.pub")
    echo $GEN_SSH_KEY >> $HOME/.ssh/authorized_keys
fi
$CMD_KCTL cp $SSH_KEY_FILE ${NAMESPACE[4]}/${CP_PORTAL_TERRAMAN_POD}:/home/1000/.ssh/master-key
