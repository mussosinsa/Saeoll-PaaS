# CI/CD portal settings (K-PaaS SCM + Jenkins + Argo CD, or GitLab CE + Runner + Argo CD).
# HOST_DOMAIN, StorageClass, Keycloak, Harbor and TLS values are read from
# cp-portal-deployment/script/cp-portal-vars.sh unless set here.

# COMMON VARIABLE
HOST_DOMAIN="{host domain}"                     # leave as-is to reuse the CP-Portal value
K8S_STORAGECLASS=""                             # empty: CP-Portal value (e.g. cp-storageclass)

# SOURCES TO INSTALL (Argo CD is shared). Each vendor picks one at onboarding:
#   ./onboard-vendor.sh --source scm|gitlab <vendor> ...
#   scm    : K-PaaS source control (SCM-Manager, scm.<domain>) + Jenkins   - trusted/internal teams only:
#            the SCM web UI shows every repository to every signed-in user
#   gitlab : GitLab CE (repositories + CI) + GitLab Runner                 - external vendors (isolated groups)
CICD_SOURCES=${CICD_SOURCES:-${CICD_SOURCE:-"scm gitlab"}}   # env overrides, e.g. CICD_SOURCES=gitlab

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

# CI/CD CONSOLE (web UI, optional: ./deploy-cicd-portal.sh console-image console)
CONSOLE_NAMESPACE="cicd-console"
CONSOLE_HOST_PREFIX="cicd"                      # https://cicd.<domain>
KEYCLOAK_CONSOLE_CLIENT_ID="cicd-console"
CONSOLE_HARBOR_PROJECT="cicd-portal"            # Harbor project of the console image
CONSOLE_IMAGE_TAG="1.0.0"
CONSOLE_BASE_IMAGE="${CICD_DOCKERHUB}/python:3.12-slim"
CONSOLE_PIP_INDEX_URL=""                        # closed network: PyPI mirror (e.g. Nexus) for the image build
CONSOLE_APT_MIRROR=""                           # closed network: Debian mirror, e.g. http://mirror.example/debian
# API addresses used by the console pod (empty: https://jenkins|gitlab|scm-manager.<domain> like the scripts).
# The K-PaaS default NetworkPolicy blocks pod-to-pod traffic into cicd-jenkins, so keep Jenkins on the ingress.
CONSOLE_JENKINS_API_URL=""
CONSOLE_GITLAB_API_URL=""                       # e.g. http://gitlab.cicd-gitlab.svc.cluster.local (cp-role: shared)
CONSOLE_SCM_API_URL=""                          # e.g. http://cp-source-control-manager-service.cp-source-control.svc.cluster.local:8080/scm

# SECURITY SCAN + 품질 관리 (optional: ./deploy-cicd-portal.sh security-image security)
# Pipelines run Semgrep, Gitleaks, Trivy and the personal information check; the gate policy is edited in the console.
SECURITY_IMAGE_TAG="1.0.0"                      # Harbor <CONSOLE_HARBOR_PROJECT>/security-scanner:<tag>
SECURITY_BASE_IMAGE="${CICD_DOCKERHUB}/python:3.12-slim"
SECURITY_GITLEAKS_IMAGE="docker.io/zricethezav/gitleaks:v8.21.2"
SECURITY_TRIVY_IMAGE="docker.io/aquasec/trivy:0.57.1"
SECURITY_SEMGREP_VERSION="1.183.0"              # pip package (CONSOLE_PIP_INDEX_URL / CONSOLE_APT_MIRROR also apply)
SECURITY_TRIVY_DB_REPOSITORY=""                 # closed network: OCI mirror of the Trivy DB, e.g. harbor.<domain>/mirror/trivy-db
SECURITY_TRIVY_JAVA_DB_REPOSITORY=""            #   and of the Java DB, e.g. harbor.<domain>/mirror/trivy-java-db
SECURITY_HARBOR_PREVENT=""                      # e.g. critical: Harbor refuses pulls of images with critical CVEs
                                                #   (also restarts of running pods - enable after a review)
SECURITY_NAMESPACE="cicd-security"              # Presidio analyzer (phase 4)
SECURITY_PRESIDIO=${SECURITY_PRESIDIO:-false}   # true: deploy Presidio and use it for personal information
PRESIDIO_IMAGE="mcr.microsoft.com/presidio-analyzer:2.2.355"

# Application databases (add-db.sh)
MARIADB_IMAGE="docker.io/library/mariadb:11.4"  # dedicated MariaDB per app/env (LTS); Harbor mirror in a closed network
DB_SIZE=${DB_SIZE:-2Gi}                          # dedicated MariaDB volume

# The belows are the default values.
INGRESS_CLASS_NAME="nginx"
CP_PORTAL_NAMESPACE="cp-portal"
SECRET_NAME="cicd-portal-secrets"               # generated passwords/tokens (namespace GITLAB_NAMESPACE)
CA_SECRET_NAME="cicd-ca"                        # K-PaaS CA certificate for build pods
TEMPLATES_GROUP="cicd"
TEMPLATES_PROJECT="ci-templates"
