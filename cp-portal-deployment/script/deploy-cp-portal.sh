#!/bin/bash
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/rocky-linux.sh
source "$SCRIPT_DIR/../lib/rocky-linux.sh"
require_rocky_linux_9_7 || return 1 2>/dev/null || exit 1
source ../script/cp-portal-vars.sh

configure_portal_vars_if_needed() {
  local cluster_env=${CLUSTER_ENV_FILE:-}
  local -a candidates=()

  if [[ "$HOST_DOMAIN" != *'{'* && "$K8S_MASTER_NODE_IP" != *'{'* ]]; then
    return 0
  fi

  if [[ -n "$cluster_env" ]]; then
    [[ -r "$cluster_env" ]] || {
      echo "[ERROR] CLUSTER_ENV_FILE is not readable: $cluster_env" >&2
      return 1
    }
  else
    while IFS= read -r file; do
      candidates+=("$file")
    done < <(find "$HOME" -maxdepth 5 -type f -name cluster.env 2>/dev/null | sort)

    if ((${#candidates[@]} == 1)); then
      cluster_env=${candidates[0]}
    elif ((${#candidates[@]} > 1)); then
      echo "[ERROR] Multiple cluster.env files were found:" >&2
      printf '  %s\n' "${candidates[@]}" >&2
      echo "[ERROR] Select one with: CLUSTER_ENV_FILE=/path/to/cluster.env ./deploy-cp-portal.sh" >&2
      return 1
    else
      echo "[ERROR] cp-portal-vars.sh still contains placeholders and cluster.env was not found under $HOME." >&2
      echo "[ERROR] Run: CLUSTER_ENV_FILE=/path/to/cluster.env ./deploy-cp-portal.sh" >&2
      return 1
    fi
  fi

  echo "[INFO] Configuring CP-Portal variables from: $cluster_env"
  CP_PORTAL_VARS_FILE="$SCRIPT_DIR/cp-portal-vars.sh" \
    "$SCRIPT_DIR/configure-from-cluster-env.sh" "$cluster_env" || return 1
  # Reload the values written by the configurator into this process.
  # shellcheck source=cp-portal-vars.sh
  source "$SCRIPT_DIR/cp-portal-vars.sh"
}

configure_portal_vars_if_needed || return 1 2>/dev/null || exit 1
declare -A DEPLOY_CONFIG
DEPLOY_CONFIG[IPV6_ENABLED]=true
DEPLOY_CONFIG[INGRESS_ENABLED]=true
DEPLOY_CONFIG[EXPOSE_TYPE]="ingress"
APP_TERRAMAN="cp-portal-terraman"

create_tls_secret() {
  local namespace=$1
  kubectl create secret tls "$TLS_SECRET" \
    --cert="../certs/${HOST_DOMAIN}.crt" \
    --key="../certs/${HOST_DOMAIN}.key" \
    --namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -
}

validate_portal_configuration() {
  local invalid=0

  if [[ ! "$HOST_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
    echo "[ERROR] HOST_DOMAIN is not configured: '$HOST_DOMAIN'" >&2
    invalid=1
  fi
  if [[ ! "$K8S_MASTER_NODE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "[ERROR] K8S_MASTER_NODE_IP is not configured: '$K8S_MASTER_NODE_IP'" >&2
    invalid=1
  fi
  if [[ ! "$K8S_CLUSTER_API_SERVER" =~ ^https://[^[:space:]{}]+:[0-9]+$ ]]; then
    echo "[ERROR] K8S_CLUSTER_API_SERVER is invalid: '$K8S_CLUSTER_API_SERVER'" >&2
    invalid=1
  fi
  if [[ -z "$K8S_STORAGECLASS" || "$K8S_STORAGECLASS" == *'{'* ]]; then
    echo "[ERROR] K8S_STORAGECLASS is not configured: '$K8S_STORAGECLASS'" >&2
    invalid=1
  fi

  if ((invalid)); then
    echo "[ERROR] Run configure-from-cluster-env.sh or edit cp-portal-vars.sh before deployment." >&2
    return 1
  fi
  if ! kubectl get storageclass "$K8S_STORAGECLASS" >/dev/null 2>&1; then
    echo "[ERROR] StorageClass does not exist in the current cluster: $K8S_STORAGECLASS" >&2
    return 1
  fi
}
ingress_controller_running() {
  kubectl -n "$INGRESS_NAMESPACE" get pods -l "$INGRESS_CONTROLLER_SELECTOR" \
    --field-selector=status.phase=Running -o name 2>/dev/null | grep -q .
}

# ingress-nginx must exist before OpenBao/Harbor/Keycloak Ingresses are created
# and before SECMG_BOUND_CIDR is derived from the controller pod IPs.
ensure_ingress_controller() {
  local manifest=${INGRESS_MANIFEST:-"$SCRIPT_DIR/../../applications/ingress-nginx-1.13.3/deploy.yaml"}
  local service=${INGRESS_SERVICE:-ingress-nginx-controller}
  local lb_ip=${INGRESS_LB_IP:-}
  local ip attempt

  # HOST_DOMAIN such as 192.168.40.216.nip.io must resolve to the ingress LB IP.
  if [[ -z "$lb_ip" && "$HOST_DOMAIN" =~ ^(([0-9]{1,3}\.){3}[0-9]{1,3})\.nip\.io$ ]]; then
    lb_ip=${BASH_REMATCH[1]}
  fi

  if ! ingress_controller_running; then
    if [[ "${INSTALL_INGRESS_NGINX:-true}" != "true" ]]; then
      echo "[ERROR] No running ingress controller in namespace $INGRESS_NAMESPACE ($INGRESS_CONTROLLER_SELECTOR)." >&2
      echo "[ERROR] Install ingress-nginx or unset INSTALL_INGRESS_NGINX=false." >&2
      return 1
    fi
    [[ -f "$manifest" ]] || {
      echo "[ERROR] ingress-nginx manifest not found: $manifest (set INGRESS_MANIFEST)" >&2
      return 1
    }
    echo "[INFO] ingress-nginx is not running. Installing from $manifest"
    kubectl apply -f "$manifest" || return 1
  fi

  if ! kubectl -n "$INGRESS_NAMESPACE" rollout status "deployment/$service" --timeout=300s; then
    echo "[ERROR] ingress-nginx controller did not become ready." >&2
    kubectl -n "$INGRESS_NAMESPACE" get pods -o wide >&2 || true
    kubectl -n "$INGRESS_NAMESPACE" describe pods -l "$INGRESS_CONTROLLER_SELECTOR" >&2 || true
    return 1
  fi
  kubectl get ingressclass "$INGRESS_CLASS_NAME" >/dev/null 2>&1 || {
    echo "[ERROR] IngressClass does not exist: $INGRESS_CLASS_NAME" >&2
    return 1
  }

  if [[ -n "$lb_ip" ]]; then
    ip=$(kubectl -n "$INGRESS_NAMESPACE" get service "$service" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [[ "$ip" != "$lb_ip" ]]; then
      echo "[INFO] Requesting MetalLB address $lb_ip for $INGRESS_NAMESPACE/$service"
      kubectl -n "$INGRESS_NAMESPACE" annotate service "$service" --overwrite \
        "metallb.universe.tf/loadBalancerIPs=$lb_ip" || return 1
    fi
  fi

  for ((attempt=1; attempt<=60; attempt++)); do
    ip=$(kubectl -n "$INGRESS_NAMESPACE" get service "$service" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [[ -n "$ip" && ( -z "$lb_ip" || "$ip" == "$lb_ip" ) ]]; then
      echo "[OK] ingress-nginx External IP: $ip"
      return 0
    fi
    echo "[INFO] Waiting for ingress-nginx External IP (${attempt}/60): current='${ip:-<pending>}' expected='${lb_ip:-any}'"
    sleep 5
  done
  echo "[ERROR] MetalLB did not assign ${lb_ip:-an address} to $INGRESS_NAMESPACE/$service." >&2
  echo "[ERROR] Check that the IP is inside a MetalLB IPAddressPool and not used by another Service." >&2
  kubectl -n "$INGRESS_NAMESPACE" describe service "$service" >&2 || true
  kubectl get ipaddresspools.metallb.io -A >&2 2>/dev/null || true
  kubectl get service -A --field-selector spec.type=LoadBalancer >&2 || true
  return 1
}
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
  helm upgrade --install -f "$value_path" "$release_name" "$chart_path" -n "$namespace" "$@"
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

push_image_with_retry() {
  local image=$1 attempt attempts=${IMAGE_PUSH_ATTEMPTS:-3}
  for ((attempt=1; attempt<=attempts; attempt++)); do
    if sudo podman push --help 2>/dev/null | grep -q -- '--retry'; then
      sudo podman push --retry 3 "$image" && return 0
    else
      sudo podman push "$image" && return 0
    fi
    echo "[WARN] Image push failed (${attempt}/${attempts}): $image" >&2
    ((attempt < attempts)) || break
    wait_for_harbor_ready || return 1
    sleep 10
  done
  return 1
}

# /api/v2.0/projects answers as soon as harbor-core is up, but blob uploads
# also need harbor-registry (and its storage) to be ready.
wait_for_harbor_ready() {
  local ns=${NAMESPACE[2]} code attempt
  echo "[INFO] Waiting for all Harbor pods in namespace $ns to be Ready..."
  if kubectl -n "$ns" get pods -l app=harbor -o name | grep -q . && \
    ! kubectl -n "$ns" wait --for=condition=Ready pod -l app=harbor --timeout=600s; then
    echo "[ERROR] Harbor pods are not Ready." >&2
    kubectl -n "$ns" get pods,pvc -o wide >&2 || true
    return 1
  fi
  for ((attempt=1; attempt<=60; attempt++)); do
    # The registry API answers 401 (auth required) once it can serve pushes.
    code=$(curl -k -s -o /dev/null -w '%{http_code}' "$REPOSITORY_URL/v2/")
    [[ "$code" == "401" || "$code" == "200" ]] && { echo "[OK] Harbor registry API is ready."; return 0; }
    echo "[INFO] Waiting for Harbor registry API (${attempt}/60): HTTP $code"
    sleep 5
  done
  echo "[ERROR] Harbor registry API did not become ready: $REPOSITORY_URL/v2/" >&2
  return 1
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
    if ! push_image_with_retry "$IMAGE_REF"; then
      echo "[ERROR] Failed to push UI image to Harbor: $IMAGE_REF" >&2
      echo "[ERROR] Check: kubectl -n ${NAMESPACE[2]} get pods; kubectl -n ${NAMESPACE[2]} logs deploy/harbor-registry -c registry --tail=50" >&2
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

wait_for_cert_setup() {
  local daemonset="${CHART_NAME[7]}-daemonset"
  echo "[INFO] Waiting for $daemonset to install the Harbor CA on every node..."
  if kubectl -n "$CP_CERT_SETUP_NAMESPACE" rollout status \
    "daemonset/$daemonset" --timeout=5m; then
    return 0
  fi

  echo "[ERROR] Certificate setup failed. Pod status and init-container logs follow." >&2
  kubectl -n "$CP_CERT_SETUP_NAMESPACE" get pods -l "$CP_CERT_SETUP_SELECTOR" -o wide >&2 || true
  kubectl -n "$CP_CERT_SETUP_NAMESPACE" describe pods -l "$CP_CERT_SETUP_SELECTOR" >&2 || true
  kubectl -n "$CP_CERT_SETUP_NAMESPACE" logs -l "$CP_CERT_SETUP_SELECTOR" \
    -c setup --prefix --tail=100 >&2 || true
  kubectl -n "$CP_CERT_SETUP_NAMESPACE" logs -l "$CP_CERT_SETUP_SELECTOR" \
    -c setup --previous --prefix --tail=100 >&2 || true
  return 1
}

main_pre_cp_portal() {
  ### EXECUTION ########################################
  validate_portal_configuration || return 1
  ensure_ingress_controller || return 1

  # Create cluster-admin token
  kubectl create sa $K8S_CLUSTER_ADMIN -n $K8S_CLUSTER_ADMIN_NAMESPACE \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl create clusterrolebinding $K8S_CLUSTER_ADMIN --clusterrole=cluster-admin \
    --serviceaccount=$K8S_CLUSTER_ADMIN_NAMESPACE:$K8S_CLUSTER_ADMIN \
    --dry-run=client -o yaml | kubectl apply -f -
  K8S_CLUSTER_ADMIN_TOKEN=$(kubectl create token $K8S_CLUSTER_ADMIN --duration=999999h -n $K8S_CLUSTER_ADMIN_NAMESPACE)

  # Create a secrets mgmt bound cidr
  SECMG_BOUND_CIDR_ARR=($(kubectl get pods -n $INGRESS_NAMESPACE --selector=$INGRESS_CONTROLLER_SELECTOR --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{@.status.podIP}{"/16"}{"\t"}{end}'))
  if ((${#SECMG_BOUND_CIDR_ARR[@]} == 0)); then
    echo "[ERROR] No running ingress controller pod IPs found for SECMG_BOUND_CIDR." >&2
    return 1
  fi
  printf -v SECMG_BOUND_CIDR '"%s",' "${SECMG_BOUND_CIDR_ARR[@]}"
  SECMG_BOUND_CIDR="${SECMG_BOUND_CIDR%,}"

  # Copy the directory
  # Refresh generated templates on retry, but preserve OpenBao initialization
  # material such as ../secmg/unseal-key.
  mkdir -p ../secmg
  cp -r ../secmg_orig/. ../secmg/
  rm -rf ../values
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
    chmod +x "../script/$f" && . "../script/$f" || return 1
  done

  # Setup the certificate in cluster
  helm_install 7 "" $CP_CERT_SETUP_NAMESPACE --set data.target.cert="$(cat ../certs/ca.crt)"
  wait_for_cert_setup || return 1
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
  create_tls_secret "${NAMESPACE[2]}"
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
  wait_for_harbor_ready || return 1
  inject_cert_and_build_image || return 1

  # Deploy the keycloak
  kubectl create namespace ${NAMESPACE[3]}
  create_tls_secret "${NAMESPACE[3]}"
  kubectl create configmap $KEYCLOAK_CP_REALM --from-file=../values/$KEYCLOAK_CP_REALM-realm.json -n ${NAMESPACE[3]}
  helm_install 3

  # Deploy the chartmuseum
  kubectl create namespace ${NAMESPACE[5]}
  create_tls_secret "${NAMESPACE[5]}"
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
