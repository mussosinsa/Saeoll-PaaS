# CI/CD console image. Build context (prepared by ./deploy-cicd-portal.sh console-image):
#   console/  script/  starters/  gitops-template/  db-template/  ci-templates/  kubectl
# Closed network: BASE_IMAGE from the Harbor mirror, APT_MIRROR / PIP_INDEX_URL for packages.
ARG BASE_IMAGE=docker.io/library/python:3.12-slim
FROM ${BASE_IMAGE}

ARG APT_MIRROR=""
ARG PIP_INDEX_URL=""
RUN if [ -n "$APT_MIRROR" ]; then sed -i "s|http://deb.debian.org|$APT_MIRROR|g" /etc/apt/sources.list.d/*.sources 2>/dev/null || true; fi \
 && apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY console/requirements.txt /opt/cicd/console/requirements.txt
RUN pip install --no-cache-dir ${PIP_INDEX_URL:+--index-url "$PIP_INDEX_URL"} -r /opt/cicd/console/requirements.txt

# kubectl of the master node (same version as the cluster)
COPY kubectl /usr/local/bin/kubectl
# The portal scripts and templates the console runs (cicd-vars.sh is replaced by a ConfigMap)
COPY script/ /opt/cicd/script/
COPY starters/ /opt/cicd/starters/
COPY gitops-template/ /opt/cicd/gitops-template/
COPY db-template/ /opt/cicd/db-template/
COPY ci-templates/ /opt/cicd/ci-templates/
COPY console/cicd_console/ /opt/cicd/console/cicd_console/
RUN chmod 755 /usr/local/bin/kubectl /opt/cicd/script/*.sh

ENV CICD_SCRIPT_DIR=/opt/cicd/script \
    HOME=/tmp \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
WORKDIR /opt/cicd/console
USER 10001
EXPOSE 8080
# One process: script jobs and their logs are kept in memory (threads serve the pages)
CMD ["gunicorn", "--workers", "1", "--threads", "8", "--timeout", "120", "--bind", "0.0.0.0:8080", \
     "--access-logfile", "-", "cicd_console:create_app()"]
