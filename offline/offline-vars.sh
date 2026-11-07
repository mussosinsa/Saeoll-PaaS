# Closed-network installation (docs/install-offline.md): settings shared by the offline scripts.

# Bootstrap VM inside the closed network (separate VM, Rocky Linux 9.7): local dnf repositories + file server
# (HTTP) and an image registry (HTTP) that mirrors docker.io, quay.io, registry.k8s.io, registry.k-paas.org, ...
BOOTSTRAP_HOST=${BOOTSTRAP_HOST:-"bootstrap.kpaas.example.co.kr"}   # DNS name or IP of the bootstrap VM
BOOTSTRAP_HTTP_PORT=${BOOTSTRAP_HTTP_PORT:-8080}                    # dnf repositories and files: http://<host>:8080/
BOOTSTRAP_REGISTRY_PORT=${BOOTSTRAP_REGISTRY_PORT:-5000}            # registry: <host>:5000/<original registry>/<path>
BOOTSTRAP_DATA=${BOOTSTRAP_DATA:-/srv/offline}                     # data directory on the bootstrap VM

# Registries mirrored by the bootstrap registry. Images keep their names: docker.io/library/mariadb:11.4 is stored
# as <host>:5000/docker.io/library/mariadb:11.4 and the nodes' containerd / podman pull it through the mirror
# configuration (node-setup.sh), so no chart or manifest has to be changed.
MIRRORED_REGISTRIES=${MIRRORED_REGISTRIES:-"docker.io quay.io registry.k8s.io k8s.gcr.io registry.k-paas.org gcr.io ghcr.io mcr.microsoft.com registry.gitlab.com public.ecr.aws"}

# Rocky Linux 9 repositories copied with dnf reposync (complete: kubespray and the K-PaaS scripts install
# packages from them). About 15 GB. RPM_EXTRA_REPOS: e.g. "epel" if it was enabled on the online nodes.
RPM_REPOS=${RPM_REPOS:-"baseos appstream extras"}
RPM_EXTRA_REPOS=${RPM_EXTRA_REPOS:-""}

# Images not running in the online cluster but pulled later (build pods, tools). Added to the images of the
# running cluster by collect-bundle.sh. {CICD_DOCKERHUB} images of the starters are added automatically.
NEXUS_IMAGE=${NEXUS_IMAGE:-"docker.io/sonatype/nexus3:3.70.1"}       # pin the current Nexus 3 release before collecting
NEXUS_PORT=${NEXUS_PORT:-8081}                                         # http://<bootstrap>:8081 (company repositories)
EXTRA_IMAGES=${EXTRA_IMAGES:-"
$NEXUS_IMAGE
docker.io/library/registry:2.8.3
docker.io/library/nginx:1.27-alpine
docker.io/library/busybox:1.36
docker.io/library/alpine:3.20
docker.io/library/python:3.12-slim
"}

# Base images of the application Dockerfiles (FROM \${BASE_REGISTRY}/...): pushed into Harbor base-images.
# The FROM lines of cicd-portal-deployment/starters/*/Dockerfile are added automatically.
EXTRA_BASE_IMAGES=${EXTRA_BASE_IMAGES:-""}
