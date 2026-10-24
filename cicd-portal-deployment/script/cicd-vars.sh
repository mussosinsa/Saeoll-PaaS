# CI/CD portal settings (K-PaaS SCM + Jenkins + Argo CD, or GitLab CE + Runner + Argo CD).
# HOST_DOMAIN, StorageClass, Keycloak, Harbor and TLS values are read from
# cp-portal-deployment/script/cp-portal-vars.sh unless set here.

# COMMON VARIABLE
HOST_DOMAIN="{host domain}"                     # leave as-is to reuse the CP-Portal value
K8S_STORAGECLASS=""                             # empty: CP-Portal value (e.g. cp-storageclass)

# SOURCE REPOSITORY
#   scm    : K-PaaS source control (SCM-Manager, scm.<domain>) + new Jenkins (CI) + Argo CD (CD)
#   gitlab : GitLab CE (repositories + CI) + GitLab Runner + Argo CD
CICD_SOURCE=${CICD_SOURCE:-scm}                 # env CICD_SOURCE=gitlab ./... to override

# K-PaaS SCM (CICD_SOURCE=scm). Repositories/accounts are managed in scm.<domain>;
# the scripts only check them and push starter/gitops files.
SCM_NAMESPACE="cp-source-control"
SCM_INTERNAL_URL="http://cp-source-control-manager-service.cp-source-control.svc.cluster.local:8080/scm"
SCM_ADMIN_USER=${SCM_ADMIN_USER:-scmadmin}      # SCM-Manager admin used by K-PaaS; password: env SCM_ADMIN_PASSWORD

# JENKINS (CICD_SOURCE=scm), official jenkins/jenkins Helm chart
JENKINS_NAMESPACE="cicd-jenkins"
JENKINS_CHART_VERSION=""                        # empty: latest chart; pin after the first install
JENKINS_SSO="true"                              # false: chart default local admin (for troubleshooting)
JENKINS_DATA_SIZE="20Gi"
JENKINS_TOOL_IMAGE="jenkins/jenkins:lts-jdk17"  # init container (keytool) for the JVM truststore
KEYCLOAK_JENKINS_CLIENT_ID="cicd-jenkins"

# NAMESPACES (new; the K-PaaS cp-pipeline / cp-source-control are not touched)
GITLAB_NAMESPACE="cicd-gitlab"
RUNNER_NAMESPACE="cicd-runner"
ARGOCD_NAMESPACE="cicd-argocd"

# GITLAB CE (Omnibus image, single pod)
GITLAB_IMAGE="gitlab/gitlab-ce:17.11.1-ce.0"    # pin to the latest patch of your chosen version
GITLAB_DATA_SIZE="50Gi"
GITLAB_CONFIG_SIZE="1Gi"
GITLAB_LOGS_SIZE="5Gi"
GITLAB_CPU_REQUEST="2"
GITLAB_MEMORY_REQUEST="4Gi"
GITLAB_MEMORY_LIMIT="8Gi"

# GITLAB RUNNER (Kubernetes executor)
GITLAB_RUNNER_CHART_VERSION="0.76.0"            # gitlab-runner 17.11
RUNNER_CONCURRENT="4"
RUNNER_BUILD_MEMORY_LIMIT="4Gi"

# ARGO CD
ARGOCD_CHART_VERSION="7.8.0"                    # Argo CD 2.14

# KEYCLOAK (clients/groups added to the existing realm; existing clients are not changed)
KEYCLOAK_GITLAB_CLIENT_ID="cicd-gitlab"
KEYCLOAK_ARGOCD_CLIENT_ID="cicd-argocd"
KEYCLOAK_ADMIN_GROUP="cicd-admins"              # Argo CD admin group (add operators to it)

# CI defaults (instance-level CI/CD variables)
CICD_DOCKERHUB="docker.io/library"              # CI tool images (gradle, maven, composer, node, alpine)
CICD_BASE_REGISTRY="docker.io/library"          # Dockerfile BASE_REGISTRY (e.g. harbor.<domain>/base-images)
KANIKO_IMAGE="gcr.io/kaniko-project/executor:v1.23.2-debug"

# The belows are the default values.
INGRESS_CLASS_NAME="nginx"
CP_PORTAL_NAMESPACE="cp-portal"
SECRET_NAME="cicd-portal-secrets"               # generated passwords/tokens (namespace GITLAB_NAMESPACE)
CA_SECRET_NAME="cicd-ca"                        # K-PaaS CA certificate for build pods
TEMPLATES_GROUP="cicd"
TEMPLATES_PROJECT="ci-templates"
