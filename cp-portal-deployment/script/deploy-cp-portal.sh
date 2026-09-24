#!/bin/bash
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/rocky-linux.sh
source "$SCRIPT_DIR/../lib/rocky-linux.sh"
require_rocky_linux_9_7 || return 1 2>/dev/null || exit 1
source ../script/cp-portal-vars.sh
declare -A DEPLOY_CONFIG
DEPLOY_CONFIG[IPV6_ENABLED]=true
DEPLOY_CONFIG[INGRESS_ENABLED]=true
DEPLOY_CONFIG[EXPOSE_TYPE]="ingress"
CMD_CREATE_TLS_SECRET="kubectl create secret tls $TLS_SECRET --cert=../certs/${HOST_DOMAIN}.crt  --key=../certs/${HOST_DOMAIN}.key"
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
  helm install -f "$value_path" "$release_name" "$chart_path" -n "$namespace" "$@"
}
chart_pull(){
  mkdir -p ../charts
  for CHART in ${CHART_NAME[@]}; do
    FILE="../charts/${CHART}-${CHART_VERSION[$CHART]}.tgz"
    [ -f "$FILE" ] || helm pull -d ../charts "$K_PAAS_HELM_OCI_REPO/$CHART" --version "${CHART_VERSION[$CHART]}"
  done
}
wait_for_pod_ready() {
  local ns="$1" label="$2" interval="${3:-5}"
  echo "Waiting for all pods [$label] in namespace [$ns]..."
  while :; do
    pods=$(kubectl --request-timeout=5s get pods -n "$ns" -l "$label" --no-headers 2>/dev/null)
    [[ -z "$pods" ]] && echo "[NotFound] No pods found for [$label]" && sleep "$interval" && continue
    total=$(echo "$pods" | wc -l)
    ready=$(echo "$pods" | awk '{print $2}' | grep -Eo '[0-9]+/[0-9]+' | awk -F/ '$1==$2' | wc -l)
    echo "Ready: [$ready/$total] $label"
    [[ "$ready" -eq "$total" ]] && break
    sleep "$interval"
  done
  echo "All pods [$label] are ready."
}

terraman_ssh_key_copy() {
  wait_for_pod_ready ${NAMESPACE[4]} "app=$APP_TERRAMAN" 10
  CP_PORTAL_TERRAMAN_POD="$(kubectl get pods -n ${NAMESPACE[4]} -l app=$APP_TERRAMAN -o=jsonpath='{.items[0].metadata.name}')"
  SSH_KEY_FILE=$HOME/.ssh/id_rsa
  if [ ! -e "$SSH_KEY_FILE" ]; then
      ssh-keygen -q -t rsa -N '' -f $SSH_KEY_FILE <<<y >/dev/null 2>&1
      GEN_SSH_KEY=$(cat "$SSH_KEY_FILE.pub")
      echo $GEN_SSH_KEY >> $HOME/.ssh/authorized_keys
  fi
  kubectl cp $SSH_KEY_FILE ${NAMESPACE[4]}/${CP_PORTAL_TERRAMAN_POD}:/home/1000/.ssh/master-key
}

inject_cert_and_build_image() {
  local IMAGE_REF
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

    IMAGE_REF="$REPOSITORY_HOST/$REPOSITORY_PROJECT_NAME/$APP_NAME:$IMAGE_TAGS"
    if ! sudo podman build -t "$IMAGE_REF" ../values/ui; then
      echo "[ERROR] Failed to build UI image: $IMAGE_REF" >&2
      rm -f "$OUTPUT"
      return 1
    fi
    if ! sudo podman push "$IMAGE_REF"; then
      echo "[ERROR] Failed to push UI image to Harbor: $IMAGE_REF" >&2
      rm -f "$OUTPUT"
      return 1
    fi

    rm -f "$OUTPUT"
  done

}

preflight_source_ui_images() {
  local app source_image
  for app in cp-portal-ui cp-portal-migration-ui; do
    source_image="$K_PAAS_REGISTRY/$K_PAAS_REPO/$app:$IMAGE_TAGS"
    echo "[INFO] Pulling source image: $source_image"
    if ! sudo podman pull "$source_image"; then
      echo "[ERROR] Cannot pull $source_image from the K-PaaS registry." >&2
      echo "[ERROR] Check DNS, outbound HTTPS, the system public CA bundle, and the image tag." >&2
      return 1
    fi
  done
}

main_pre_cp_portal() {
  ### EXECUTION ########################################
  # Create cluster-admin token
  kubectl create sa $K8S_CLUSTER_ADMIN -n $K8S_CLUSTER_ADMIN_NAMESPACE
  kubectl create clusterrolebinding $K8S_CLUSTER_ADMIN --clusterrole=cluster-admin --serviceaccount=$K8S_CLUSTER_ADMIN_NAMESPACE:$K8S_CLUSTER_ADMIN
  K8S_CLUSTER_ADMIN_TOKEN=$(kubectl create token $K8S_CLUSTER_ADMIN --duration=999999h -n $K8S_CLUSTER_ADMIN_NAMESPACE)

  # Create a secrets mgmt bound cidr
  SECMG_BOUND_CIDR_ARR=($(kubectl get pods -n $INGRESS_NAMESPACE --selector=$INGRESS_CONTROLLER_SELECTOR --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{@.status.podIP}{"/16"}{"\t"}{end}'))
  printf -v SECMG_BOUND_CIDR '"%s",' "${SECMG_BOUND_CIDR_ARR[@]}"
  SECMG_BOUND_CIDR="${SECMG_BOUND_CIDR%,}"

  # Copy the directory
  cp -r ../secmg_orig ../secmg
  cp -r ../values_orig ../values

  # Set a iaas type
  if [[ $HOST_CLUSTER_IAAS_TYPE -lt 1 ]] || [[ $HOST_CLUSTER_IAAS_TYPE -gt ${#IAAS_TYPE[@]} ]]
  then
    HOST_CLUSTER_IAAS_TYPE="1"
  fi
  # ipv6Enabled set to false if iaas type is NAVER
  if [[ $((HOST_CLUSTER_IAAS_TYPE -1)) -eq 2 ]]
  then
    DEPLOY_CONFIG[IPV6_ENABLED]=false
  fi

  # Replace values
  HOST_CLUSTER_ID=$(uuidgen)
  REPOSITORY_HOST=$(echo $REPOSITORY_URL | awk -F[/:] '{print $4}')
  find ../secmg -name "payload.json" -exec sed -i "s@{SECMG_BOUND_CIDR}@$SECMG_BOUND_CIDR@g" {} +
  find ../values -type f -exec sed -i "s@{K_PAAS_REGISTRY}@$K_PAAS_REGISTRY@g" {} +
  find ../values -type f -exec sed -i "s/{K_PAAS_REPO}/$K_PAAS_REPO/g" {} +
  find ../values -type f -exec sed -i "s@{CP_PORTAL_URL}@$CP_PORTAL_URL@g" {} +
  find ../values -type f -exec sed -i "s@{CP_SERVICE_PIPELINE_URL}@$CP_SERVICE_PIPELINE_URL@g" {} +
  find ../values -type f -exec sed -i "s@{CP_SERVICE_SOURCE_CONTROL_URL}@$CP_SERVICE_SOURCE_CONTROL_URL@g" {} +
  find ../values -type f -exec sed -i "s/{K8S_MASTER_NODE_IP}/$K8S_MASTER_NODE_IP/g" {} +
  find ../values -type f -exec sed -i "s/{HOST_CLUSTER_IAAS_TYPE}/${IAAS_TYPE[$HOST_CLUSTER_IAAS_TYPE -1]}/g" {} +
  find ../values -type f -exec sed -i "s/{HOST_DOMAIN}/$HOST_DOMAIN/g" {} +
  find ../values -type f -exec sed -i "s/{IMAGE_TAGS}/$IMAGE_TAGS/g" {} +
  find ../values -type f -exec sed -i "s/{IMAGE_PULL_POLICY}/$IMAGE_PULL_POLICY/g" {} +
  find ../values -type f -exec sed -i "s/{IMAGE_PULL_SECRET}/$IMAGE_PULL_SECRET/g" {} +
  find ../values -type f -exec sed -i "s/{TLS_SECRET}/$TLS_SECRET/g" {} +
  find ../values -type f -exec sed -i "s/{SERVICE_TYPE}/$SERVICE_TYPE/g" {} +
  find ../values -type f -exec sed -i "s/{SERVICE_PROTOCOL}/$SERVICE_PROTOCOL/g" {} +
  find ../values -type f -exec sed -i "s/{INGRESS_CLASS_NAME}/$INGRESS_CLASS_NAME/g" {} +
  find ../values -type f -exec sed -i "s/{SECMG_NAMESPACE}/${NAMESPACE[0]}/g" {} +
  find ../values -type f -exec sed -i "s/{SECMG_HOST}/$(echo $SECMG_URL | awk -F[/:] '{print $4}')/g" {} +
  find ../values -type f -exec sed -i "s/{SECMG_ROLE_NAME}/$SECMG_ROLE_NAME/g" {} +
  find ../values -type f -exec sed -i "s/{SECMG_STORAGECLASS}/$K8S_STORAGECLASS/g" {} +
  find ../values -type f -exec sed -i "s@{REPOSITORY_URL}@$REPOSITORY_URL@g" {} +
  find ../values -type f -exec sed -i "s/{REPOSITORY_HOST}/$REPOSITORY_HOST/g" {} +
  find ../values -type f -exec sed -i "s/{REPOSITORY_USERNAME}/$REPOSITORY_USERNAME/g" {} +
  find ../values -type f -exec sed -i "s/{REPOSITORY_PASSWORD}/$REPOSITORY_PASSWORD/g" {} +
  find ../values -type f -exec sed -i "s/{REPOSITORY_PROJECT_NAME}/$REPOSITORY_PROJECT_NAME/g" {} +
  find ../values -type f -exec sed -i "s/{REPOSITORY_STORAGECLASS}/$K8S_STORAGECLASS/g" {} +
  find ../values -type f -exec sed -i "s/{DATABASE_URL}/$DATABASE_URL/g" {} +
  find ../values -type f -exec sed -i "s/{DATABASE_HOST}/$(echo "${DATABASE_URL%:*}")/g" {} +
  find ../values -type f -exec sed -i "s/{DATABASE_PORT}/$(echo "${DATABASE_URL#*:}")/g" {} +
  find ../values -type f -exec sed -i "s/{DATABASE_USER_ID}/$DATABASE_USER_ID/g" {} +
  find ../values -type f -exec sed -i "s/{DATABASE_USER_PASSWORD}/$DATABASE_USER_PASSWORD/g" {} +
  find ../values -type f -exec sed -i "s/{DATABASE_TERRAMAN_ID}/$DATABASE_TERRAMAN_ID/g" {} +
  find ../values -type f -exec sed -i "s/{DATABASE_TERRAMAN_PASSWORD}/$DATABASE_TERRAMAN_PASSWORD/g" {} +
  find ../values -type f -exec sed -i "s/{DATABASE_STORAGECLASS}/$K8S_STORAGECLASS/g" {} +
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
  find ../values -type f -exec sed -i "s/{CHART_REPOSITORY_NAME}/$CHART_REPOSITORY_NAME/g" {} +
  find ../values -type f -exec sed -i "s@{CHART_REPOSITORY_URL}@$CHART_REPOSITORY_URL@g" {} +
  find ../values -type f -exec sed -i "s/{CHART_REPOSITORY_HOST}/$(echo $CHART_REPOSITORY_URL | awk -F[/:] '{print $4}')/g" {} +
  find ../values -type f -exec sed -i "s/{CHART_REPOSITORY_STORAGECLASS}/$K8S_STORAGECLASS/g" {} +
  find ../values -type f -exec sed -i "s/{CHAOS_MESH_NAMESPACE}/${NAMESPACE[6]}/g" {} +
  find ../values -type f -exec sed -i "s/{NAMESPACE}/${NAMESPACE[4]}/g" {} +
  find ../values -type f -exec sed -i "s/{HOST_CLUSTER_ID}/$HOST_CLUSTER_ID/g" {} +
  find ../values -type f -exec sed -i "s/{HOST_CLUSTER_NAME}/$HOST_CLUSTER_NAME/g" {} +
  find ../values -type f -exec sed -i "s/{CP_PORTAL_HOST}/$(echo $CP_PORTAL_URL | awk -F[/:] '{print $4}')/g" {} +
  find ../values -type f -exec sed -i "s/{CP_PORTAL_STORAGECLASS}/$K8S_STORAGECLASS/g" {} +
  find ../values -type f -exec sed -i "s/{CP_CERT_SETUP_NAME}/${CHART_NAME[7]}/g" {} +
  find ../values -type f -exec sed -i "s/{CP_CERT_SETUP_NAMESPACE}/$CP_CERT_SETUP_NAMESPACE/g" {} +
  find ../values -type f -exec sed -i "s/{IPV6_ENABLED}/${DEPLOY_CONFIG[IPV6_ENABLED]}/g" {} +
  find ../values -type f -exec sed -i "s/{INGRESS_ENABLED}/${DEPLOY_CONFIG[INGRESS_ENABLED]}/g" {} +
  find ../values -type f -exec sed -i "s/{EXPOSE_TYPE}/${DEPLOY_CONFIG[EXPOSE_TYPE]}/g" {} +
  # Pull the chart to prepare for installation
  chart_pull
  preflight_source_ui_images || return 1

  # Generate cert and enc_keys
  for f in gen-cert.sh gen-enc-keys.sh; do
    chmod +x "../script/$f" && . "../script/$f"
  done

  # Setup the certificate in cluster
  helm_install 7 "" $CP_CERT_SETUP_NAMESPACE --set data.target.cert="$(cat ../certs/ca.crt)"
  while :
  do
    POD_COUNT=$((kubectl get pods -n $CP_CERT_SETUP_NAMESPACE -l $CP_CERT_SETUP_SELECTOR --field-selector status.phase!=Running --no-headers | wc -l) 2> /dev/null)
    echo "[remaining: $POD_COUNT] Adding certificates to each node’s container runtime..."
    if [[ $POD_COUNT -lt 1 ]]; then
      echo "Completed..."
      break
    fi
    sleep 5
  done
  install_host_ca "../certs/ca.crt" "${HOST_DOMAIN}-ca.crt"

  # Deploy the secrets management
  chmod +x ../secmg/deploy-secmg.sh
  . ../secmg/deploy-secmg.sh || return 1
  find ../values -type f -exec sed -i "s/{SECMG_ROLE_ID}/$SECMG_ROLE_ID/g" {} +
  find ../values -type f -exec sed -i "s/{SECMG_SECRET_ID}/$SECMG_SECRET_ID/g" {} +

  # Deploy the mariadb
  kubectl create namespace ${NAMESPACE[1]}
  kubectl apply -f ../values/${CHART_NAME[1]}-configmap.yaml -n ${NAMESPACE[1]}
  helm_install 1

  # Deploy the harbor
  kubectl create namespace ${NAMESPACE[2]}
  $CMD_CREATE_TLS_SECRET -n ${NAMESPACE[2]}
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
  printf '%s' "$REPOSITORY_PASSWORD" | sudo podman login "$REPOSITORY_HOST" \
    --username "$REPOSITORY_USERNAME" --password-stdin || return 1

  # Build ui image by adding generated self-signed certificate into keystore
  inject_cert_and_build_image || return 1

  # Deploy the keycloak
  kubectl create namespace ${NAMESPACE[3]}
  $CMD_CREATE_TLS_SECRET -n ${NAMESPACE[3]}
  kubectl create configmap $KEYCLOAK_CP_REALM --from-file=../values/$KEYCLOAK_CP_REALM-realm.json -n ${NAMESPACE[3]}
  helm_install 3

  # Deploy the chartmuseum
  kubectl create namespace ${NAMESPACE[5]}
  $CMD_CREATE_TLS_SECRET -n ${NAMESPACE[5]}
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
  helm plugin install https://github.com/chartmuseum/helm-push.git
  helm repo add $CHART_REPOSITORY_NAME $CHART_REPOSITORY_URL

  # Deploy the chaos-mesh
  kubectl create namespace ${NAMESPACE[6]}
  helm_install 6
}
main_cp_portal() {
  local chart_path="../charts/${CHART_NAME[4]}-${CHART_VERSION[${CHART_NAME[4]}]}.tgz"
  # Deploy the cp-portal
  kubectl create namespace ${NAMESPACE[4]}
  helm install $RELEASE_NAME \
    -f ../values/cp-portal.yaml \
    -f ../values/cp-portal-migration-secret.yaml \
    "$chart_path" \
    -n ${NAMESPACE[4]} \
    --set-string tlsSecret.tls.crt="$(base64 -w 0 < ../certs/${HOST_DOMAIN}.crt)" \
    --set-string tlsSecret.tls.key="$(base64 -w 0 < ../certs/${HOST_DOMAIN}.key)" \
    --set-string secret[0].data.CHART_REPO_CRT="$(base64 -w 0 < ../certs/ca.crt)" \

  terraman_ssh_key_copy
  # Uninstall cp-cert-setup
  helm uninstall ${CHART_NAME[7]} -n $CP_CERT_SETUP_NAMESPACE
}


main() {
  main_pre_cp_portal || return 1
  main_cp_portal || return 1
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main
