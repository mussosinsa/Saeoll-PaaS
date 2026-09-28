#!/bin/bash
source cp-pipeline-vars.sh
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
# Copy values directory
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
# Pull the chart to prepare for installation
chart_pull

# Deploy the cp-pipeline
kubectl create namespace $NAMESPACE
if [[ "$IS_MULTI_CLUSTER" == "N" ]] ; then
    # single
    helm install -f ../values/${RELEASE_NAME}.yaml ${RELEASE_NAME} $(chart_path_for 3) -n $NAMESPACE \
         --set-literal tlsSecret.tls.crt=$(kubectl get secret $TLS_SECRET -n $CP_PORTAL_NAMESPACE --template='{{index .data "tls.crt"}}') \
         --set-literal tlsSecret.tls.key=$(kubectl get secret $TLS_SECRET -n $CP_PORTAL_NAMESPACE --template='{{index .data "tls.key"}}')
else
    # multi
    helm install -f ../values/$ISTIO_RESOURCE_NAME.yaml $ISTIO_RESOURCE_NAME $(chart_path_for 3) -n $ISTIO_NAMESPACE
    helm install -f ../values/${RELEASE_NAME}-mc.yaml ${RELEASE_NAME} $(chart_path_for 3) -n $NAMESPACE
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
  helm install -f ../values/$release_name.yaml $release_name $(chart_path_for $IDX) -n $NAMESPACE
done

echo ""
helm list -n $NAMESPACE
kubectl get all -n $NAMESPACE