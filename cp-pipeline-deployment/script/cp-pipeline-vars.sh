# COMMON VARIABLE (Please change the value of the variables below.)
HOST_DOMAIN="{host domain}"                               # Host Domain (e.g. xx.xxx.xxx.xx.nip.io)
K8S_STORAGECLASS="cp-storageclass"                        # Kubernetes StorageClass Name (e.g. cp-storageclass)
IS_MULTI_CLUSTER="N"                                      # Please enter "Y" if deploy in a multi-cluster environment

# The belows are the default values.
# If you change the values below, there will be a problem with the deploy. Please keep the values.
CHART_NAME=(
"postgresql"
"sonarqube"
"cp-pipeline-jenkins"
"cp-app"
)

declare -A CHART_VERSION=(
  ["postgresql"]="10.13.11"
  ["sonarqube"]="9.9.0"
  ["cp-pipeline-jenkins"]="1.6.2"
  ["cp-app"]="1.6.2"
)

MC_APP_NAME=(
"cp-pipeline-common-api"
"cp-pipeline-ui"
"cp-pipeline-config-server"
)

K_PAAS_REGISTRY="registry.k-paas.org"
K_PAAS_REPO="kpaas"
K_PAAS_HELM_OCI_REPO="oci://${K_PAAS_REGISTRY}/${K_PAAS_REPO}"
NAMESPACE="cp-pipeline"
SERVICE_TYPE="ClusterIP"
SERVICE_PROTOCOL="TCP"
IMAGE_TAGS="v1.6.0"
IMAGE_PULL_POLICY="IfNotPresent"

#cp
CP_PIPELINE_URL="https://pipeline.${HOST_DOMAIN}"
CP_PORTAL_NAMESPACE="cp-portal"
RELEASE_NAME="cp-pipeline"
INGRESS_CLASS_NAME="nginx"
TLS_SECRET="${HOST_DOMAIN}-tls"

#keycloak
KEYCLOAK_URL="https://keycloak.${HOST_DOMAIN}"
KEYCLOAK_ADMIN_ID="admin"
KEYCLOAK_ADMIN_PASSWORD="admin"
KEYCLOAK_CP_REALM="cp-realm"
KEYCLOAK_CLUSTER_ADMIN_ROLE="cp-cluster-admin-role"
KEYCLOAK_CP_CLIENT_ID="cp-client"
KEYCLOAK_CP_CLIENT_SECRET="nddzVVGW9OC6ccy6ULrSMrzdIlqTdv5h"

#database
DATABASE_URL="mariadb.mariadb.svc.cluster.local:3306"
DATABASE_USER_ID="cp-admin"
DATABASE_USER_PASSWORD="cpAdmin!12345"

#repository
REPOSITORY_URL="https://harbor.${HOST_DOMAIN}"
REPOSITORY_USERNAME="admin"
REPOSITORY_PASSWORD="Harbor12345"

#inspection
INSPECTION_ADMIN_ID="admin"
INSPECTION_ADMIN_PASSWORD="admin"
INSPECTION_DATABASE_ADMIN_ID="sonar"
INSPECTION_DATABASE_ADMIN_PASSWORD="sonar@2020"
INSPECTION_DATABASE_NAME="inspection"

# ISTIO
ISTIO_NAMESPACE="istio-system"
ISTIO_RESOURCE_NAME="cp-pipeline-istio"