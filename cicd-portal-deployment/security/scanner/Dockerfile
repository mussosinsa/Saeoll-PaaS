# CI/CD portal security scanner: Semgrep + Gitleaks + Trivy + cicd-scan (gate, Korean PII, Presidio, DefectDojo).
# Build context (./deploy-cicd-portal.sh security-image): security/
# Closed network: pull the base images from the Harbor mirror (BASE_IMAGE, GITLEAKS_IMAGE, TRIVY_IMAGE),
# PIP_INDEX_URL for Semgrep, TRIVY_DB_REPOSITORY / TRIVY_JAVA_DB_REPOSITORY for the vulnerability DB baked in.
ARG BASE_IMAGE=docker.io/library/python:3.12-slim
ARG GITLEAKS_IMAGE=docker.io/zricethezav/gitleaks:v8.21.2
ARG TRIVY_IMAGE=docker.io/aquasec/trivy:0.57.1

FROM ${GITLEAKS_IMAGE} AS gitleaks
FROM ${TRIVY_IMAGE} AS trivy

FROM ${BASE_IMAGE}
ARG PIP_INDEX_URL=""
ARG SEMGREP_VERSION=1.183.0
ARG APT_MIRROR=""
ARG TRIVY_DB_REPOSITORY=""
ARG TRIVY_JAVA_DB_REPOSITORY=""

RUN if [ -n "$APT_MIRROR" ]; then sed -i "s|http://deb.debian.org|$APT_MIRROR|g" /etc/apt/sources.list.d/*.sources 2>/dev/null || true; fi \
 && apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir ${PIP_INDEX_URL:+--index-url "$PIP_INDEX_URL"} "semgrep==${SEMGREP_VERSION}"

COPY --from=gitleaks /usr/bin/gitleaks /usr/local/bin/gitleaks
COPY --from=trivy /usr/local/bin/trivy /usr/local/bin/trivy

# Vulnerability DB in the image: used when the pipeline cannot download a newer one (closed network).
# Rebuild the image regularly (e.g. weekly) to refresh it.
ENV TRIVY_CACHE_DIR=/opt/trivy-cache
RUN mkdir -p /opt/trivy-cache \
 && (trivy image --download-db-only --no-progress ${TRIVY_DB_REPOSITORY:+--db-repository "$TRIVY_DB_REPOSITORY"} \
     && trivy image --download-java-db-only --no-progress ${TRIVY_JAVA_DB_REPOSITORY:+--java-db-repository "$TRIVY_JAVA_DB_REPOSITORY"} \
     || echo "WARN: Trivy DB not downloaded - the pipeline downloads it at run time") \
 && chmod -R a+rwX /opt/trivy-cache

COPY scanner/cicd_scan.py /usr/local/bin/cicd-scan
COPY rules/ /opt/cicd-security/rules/
COPY policy/ /opt/cicd-security/policy/
RUN chmod 755 /usr/local/bin/cicd-scan \
 && semgrep --version && gitleaks version && trivy --version | head -1

ENV SEMGREP_SEND_METRICS=off \
    SEMGREP_ENABLE_VERSION_CHECK=0 \
    PYTHONDONTWRITEBYTECODE=1
WORKDIR /workspace
CMD ["cicd-scan", "--help"]
