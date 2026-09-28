#!/bin/bash
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || exit 1
source cp-pipeline-vars.sh
PORTAL_VARS=${PORTAL_VARS:-"$SCRIPT_DIR/../../cp-portal-deployment/script/cp-portal-vars.sh"}

# Reuse the values CP-Portal was deployed with so the pipeline talks to the
# same Keycloak client, MariaDB and Harbor credentials.
load_portal_vars() {
  if [[ "$HOST_DOMAIN" != *'{'* ]]; then
    return 0
  fi
  [[ -r "$PORTAL_VARS" ]] || {
    echo "[ERROR] HOST_DOMAIN is not set in cp-pipeline-vars.sh and $PORTAL_VARS was not found." >&2
    return 1
  }
  echo "[INFO] Loading CP-Portal settings from $PORTAL_VARS"
  eval "$(
    source "$PORTAL_VARS" >/dev/null 2>&1
    printf 'HOST_DOMAIN=%q\n' "$HOST_DOMAIN"
    printf 'K8S_STORAGECLASS=%q\n' "$K8S_STORAGECLASS"
    printf 'KEYCLOAK_ADMIN_ID=%q\n' "$KEYCLOAK_ADMIN_USERNAME"
    printf 'KEYCLOAK_ADMIN_PASSWORD=%q\n' "$KEYCLOAK_ADMIN_PASSWORD"
    printf 'KEYCLOAK_CP_REALM=%q\n' "$KEYCLOAK_CP_REALM"
    printf 'KEYCLOAK_CP_CLIENT_ID=%q\n' "$KEYCLOAK_CP_CLIENT_ID"
    printf 'KEYCLOAK_CP_CLIENT_SECRET=%q\n' "$KEYCLOAK_CP_CLIENT_SECRET"
    printf 'DATABASE_URL=%q\n' "$DATABASE_URL"
    printf 'DATABASE_USER_ID=%q\n' "$DATABASE_USER_ID"
    printf 'DATABASE_USER_PASSWORD=%q\n' "$DATABASE_USER_PASSWORD"
    printf 'REPOSITORY_USERNAME=%q\n' "$REPOSITORY_USERNAME"
    printf 'REPOSITORY_PASSWORD=%q\n' "$REPOSITORY_PASSWORD"
  )"
  [[ "$HOST_DOMAIN" != *'{'* ]] || {
    echo "[ERROR] HOST_DOMAIN is not configured in cp-portal-vars.sh either." >&2
    return 1
  }
  CP_PIPELINE_URL="https://pipeline.${HOST_DOMAIN}"
  TLS_SECRET="${HOST_DOMAIN}-tls"
  KEYCLOAK_URL="https://keycloak.${HOST_DOMAIN}"
  REPOSITORY_URL="https://harbor.${HOST_DOMAIN}"
}

preflight() {
  local failed=0
  for cmd in kubectl helm; do
    command -v "$cmd" >/dev/null || { echo "[ERROR] $cmd is not installed." >&2; failed=1; }
  done
  kubectl get storageclass "$K8S_STORAGECLASS" >/dev/null 2>&1 || {
    echo "[ERROR] StorageClass not found: $K8S_STORAGECLASS" >&2; failed=1; }
  kubectl -n "$CP_PORTAL_NAMESPACE" get secret "$TLS_SECRET" >/dev/null 2>&1 || {
    echo "[ERROR] TLS secret $TLS_SECRET not found in $CP_PORTAL_NAMESPACE. Deploy CP-Portal first." >&2; failed=1; }
  kubectl -n mariadb get pods --no-headers 2>/dev/null | grep -q Running || {
    echo "[ERROR] MariaDB (namespace mariadb) is not running. Deploy CP-Portal first." >&2; failed=1; }
  kubectl -n keycloak get pods --no-headers 2>/dev/null | grep -q Running || {
    echo "[ERROR] Keycloak (namespace keycloak) is not running. Deploy CP-Portal first." >&2; failed=1; }
  ((failed == 0))
}

# Optional custom Jenkins image (e.g. the PHP-enabled image built by
# build-jenkins-php-image.sh). The chart composes registry/name:tags.
apply_jenkins_image_override() {
  local values=../values/cp-pipeline-jenkins.yaml
  [[ -n "${JENKINS_IMAGE_REGISTRY:-}${JENKINS_IMAGE_NAME:-}${JENKINS_IMAGE_TAG:-}" ]] || return 0
  # Edit only the image: block (metadata.name also reads cp-pipeline-jenkins).
  [[ -n "${JENKINS_IMAGE_REGISTRY:-}" ]] && sed -i "/^image:/,/^[^ ]/ s@^  registry: .*@  registry: $JENKINS_IMAGE_REGISTRY@" "$values"
  [[ -n "${JENKINS_IMAGE_NAME:-}" ]] && sed -i "/^image:/,/^[^ ]/ s@^  name: .*@  name: $JENKINS_IMAGE_NAME@" "$values"
  [[ -n "${JENKINS_IMAGE_TAG:-}" ]] && sed -i "/^image:/,/^[^ ]/ s@^  tags: .*@  tags: $JENKINS_IMAGE_TAG@" "$values"
  echo "[INFO] Jenkins image override:"
  sed -n '/^image:/,/^[^ ]/p' "$values" | sed '$d'
  return 0
}
chart_pull(){
  mkdir -p ../charts
  for CHART in ${CHART_NAME[@]}; do
    FILE="../charts/${CHART}-${CHART_VERSION[$CHART]}.tgz"
    [ -f "$FILE" ] || helm pull -d ../charts "$K_PAAS_HELM_OCI_REPO/$CHART" --version "${CHART_VERSION[$CHART]}"
  done
}
chart_path_for() {
  echo "../charts/${CHART_NAME[$1]}-${CHART_VERSION[${CHART_NAME[$1]}]}.tgz"
}
### EXECUTION ########################################
load_portal_vars || exit 1
preflight || exit 1

# Copy values directory (refresh on re-run; "cp -r" into an existing
# directory would nest values_orig inside it)
rm -rf ../values
cp -r ../values_orig ../values

# Replace Vars Values
REPOSITORY_HOST=$(echo $REPOSITORY_URL | awk -F[/:] '{print $4}')
find ../values -type f -exec sed -i "s@{K_PAAS_REGISTRY}@$K_PAAS_REGISTRY@g" {} +
find ../values -type f -exec sed -i "s/{K_PAAS_REPO}/$K_PAAS_REPO/g" {} +
find ../values -type f -exec sed -i "s/{K8S_STORAGECLASS}/$K8S_STORAGECLASS/g" {} +
find ../values -type f -exec sed -i "s/{NAMESPACE}/$NAMESPACE/g" {} +
find ../values -type f -exec sed -i "s/{IMAGE_TAGS}/$IMAGE_TAGS/g" {} +
find ../values -type f -exec sed -i "s/{IMAGE_PULL_POLICY}/$IMAGE_PULL_POLICY/g" {} +
find ../values -type f -exec sed -i "s/{TLS_SECRET}/$TLS_SECRET/g" {} +
find ../values -type f -exec sed -i "s/{SERVICE_TYPE}/$SERVICE_TYPE/g" {} +
find ../values -type f -exec sed -i "s/{SERVICE_PROTOCOL}/$SERVICE_PROTOCOL/g" {} +
find ../values -type f -exec sed -i "s@{CP_PIPELINE_URL}@$CP_PIPELINE_URL@g" {} +
find ../values -type f -exec sed -i "s/{CP_PIPELINE_HOST}/$(echo $CP_PIPELINE_URL | awk -F[/:] '{print $4}')/g" {} +
find ../values -type f -exec sed -i "s/{INGRESS_CLASS_NAME}/$INGRESS_CLASS_NAME/g" {} +
find ../values -type f -exec sed -i "s@{KEYCLOAK_URL}@$KEYCLOAK_URL@g" {} +
find ../values -type f -exec sed -i "s/{KEYCLOAK_ADMIN_ID}/$KEYCLOAK_ADMIN_ID/g" {} +
find ../values -type f -exec sed -i "s/{KEYCLOAK_ADMIN_PASSWORD}/$KEYCLOAK_ADMIN_PASSWORD/g" {} +
find ../values -type f -exec sed -i "s/{KEYCLOAK_CP_REALM}/$KEYCLOAK_CP_REALM/g" {} +
find ../values -type f -exec sed -i "s/{KEYCLOAK_CLUSTER_ADMIN_ROLE}/$KEYCLOAK_CLUSTER_ADMIN_ROLE/g" {} +
find ../values -type f -exec sed -i "s/{KEYCLOAK_CP_CLIENT_ID}/$KEYCLOAK_CP_CLIENT_ID/g" {} +
find ../values -type f -exec sed -i "s/{KEYCLOAK_CP_CLIENT_SECRET}/$KEYCLOAK_CP_CLIENT_SECRET/g" {} +
find ../values -type f -exec sed -i "s/{DATABASE_URL}/$DATABASE_URL/g" {} +
find ../values -type f -exec sed -i "s/{DATABASE_USER_ID}/$DATABASE_USER_ID/g" {} +
find ../values -type f -exec sed -i "s/{DATABASE_USER_PASSWORD}/$DATABASE_USER_PASSWORD/g" {} +
find ../values -type f -exec sed -i "s@{REPOSITORY_URL}@$REPOSITORY_URL@g" {} +
find ../values -type f -exec sed -i "s/{REPOSITORY_HOST}/$REPOSITORY_HOST/g" {} +
find ../values -type f -exec sed -i "s/{REPOSITORY_USERNAME}/$REPOSITORY_USERNAME/g" {} +
find ../values -type f -exec sed -i "s/{REPOSITORY_PASSWORD}/$REPOSITORY_PASSWORD/g" {} +
find ../values -type f -exec sed -i "s/{INSPECTION_ADMIN_ID}/$INSPECTION_ADMIN_ID/g" {} +
find ../values -type f -exec sed -i "s/{INSPECTION_ADMIN_PASSWORD}/$INSPECTION_ADMIN_PASSWORD/g" {} +
find ../values -type f -exec sed -i "s/{INSPECTION_DATABASE_ADMIN_ID}/$INSPECTION_DATABASE_ADMIN_ID/g" {} +
find ../values -type f -exec sed -i "s/{INSPECTION_DATABASE_ADMIN_PASSWORD}/$INSPECTION_DATABASE_ADMIN_PASSWORD/g" {} +
find ../values -type f -exec sed -i "s/{INSPECTION_DATABASE_NAME}/$INSPECTION_DATABASE_NAME/g" {} +
find ../values -type f -exec sed -i "s/{ISTIO_NAMESPACE}/$ISTIO_NAMESPACE/g" {} +
apply_jenkins_image_override
# Pull the chart to prepare for installation
chart_pull || exit 1

# Deploy the cp-pipeline
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
if [[ "$IS_MULTI_CLUSTER" == "N" ]] ; then
    # single
    helm upgrade --install -f ../values/${RELEASE_NAME}.yaml ${RELEASE_NAME} $(chart_path_for 3) -n $NAMESPACE \
         --set-literal tlsSecret.tls.crt=$(kubectl get secret $TLS_SECRET -n $CP_PORTAL_NAMESPACE --template='{{index .data "tls.crt"}}') \
         --set-literal tlsSecret.tls.key=$(kubectl get secret $TLS_SECRET -n $CP_PORTAL_NAMESPACE --template='{{index .data "tls.key"}}')
else
    # multi
    helm upgrade --install -f ../values/$ISTIO_RESOURCE_NAME.yaml $ISTIO_RESOURCE_NAME $(chart_path_for 3) -n $ISTIO_NAMESPACE
    helm upgrade --install -f ../values/${RELEASE_NAME}-mc.yaml ${RELEASE_NAME} $(chart_path_for 3) -n $NAMESPACE
    for MC_APP in ${MC_APP_NAME[@]}
    do
       while :
       do
         DP_COUNT=$((kubectl get deployment -n $NAMESPACE -l app=$MC_APP --no-headers | wc -l) 2> /dev/null)
         echo "[$DP_COUNT] Check the $MC_APP-deployment..."
         if [[ $DP_COUNT -gt 0 ]]; then
           echo "injecting the Istio sidecar into a $MC_APP..."
           (kubectl get deployment $MC_APP-deployment -n $NAMESPACE -o yaml | istioctl kube-inject -f - | kubectl apply -f -)  2> /dev/null
           break
         fi
         sleep 1
       done
    done
fi

# Deploy postgresql, sonarqube, jenkins
for IDX in 0 1 2; do
  chart="${CHART_NAME[$IDX]}"
  if [[ $IDX -ne 2 ]]; then
    release_name="$RELEASE_NAME-$chart"
  else
    release_name="$chart"
  fi
  helm upgrade --install -f ../values/$release_name.yaml $release_name $(chart_path_for $IDX) -n $NAMESPACE
done

echo ""
echo "[INFO] Waiting for pipeline pods to become Ready (up to 15 minutes)..."
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod --all --timeout=900s || \
  echo "[WARN] Some pods are not Ready yet. Check: kubectl -n $NAMESPACE get pods" >&2
echo "[INFO] Pipeline URL: $CP_PIPELINE_URL"
helm list -n $NAMESPACE
kubectl get all -n $NAMESPACE