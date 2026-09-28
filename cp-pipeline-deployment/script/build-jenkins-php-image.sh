#!/bin/bash
# Build the PHP-enabled Jenkins image and push it to the internal Harbor.
# Afterwards deploy/upgrade the pipeline with the printed JENKINS_IMAGE_* values.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
source cp-pipeline-vars.sh
eval "$(sed -n '/^load_portal_vars()/,/^}/p' deploy-cp-pipeline.sh)"
PORTAL_VARS=${PORTAL_VARS:-"$SCRIPT_DIR/../../cp-portal-deployment/script/cp-portal-vars.sh"}
load_portal_vars

BASE_IMAGE=${BASE_IMAGE:-"$K_PAAS_REGISTRY/$K_PAAS_REPO/cp-pipeline-jenkins:$IMAGE_TAGS"}
HARBOR_HOST=$(echo "$REPOSITORY_URL" | awk -F[/:] '{print $4}')
HARBOR_PROJECT=${HARBOR_PROJECT:-cp-pipeline}
TARGET_NAME=${TARGET_NAME:-cp-pipeline-jenkins-php}
TARGET_IMAGE="$HARBOR_HOST/$HARBOR_PROJECT/$TARGET_NAME:$IMAGE_TAGS"

echo "[INFO] Pulling base image $BASE_IMAGE"
sudo podman pull "$BASE_IMAGE"
ORIGINAL_USER=$(sudo podman image inspect --format '{{.Config.User}}' "$BASE_IMAGE")
ORIGINAL_USER=${ORIGINAL_USER:-root}
echo "[INFO] Base image runs as user: $ORIGINAL_USER"

echo "[INFO] Building $TARGET_IMAGE"
sudo podman build \
  --build-arg BASE_IMAGE="$BASE_IMAGE" \
  --build-arg ORIGINAL_USER="$ORIGINAL_USER" \
  -t "$TARGET_IMAGE" ../jenkins-php

# A public project lets the nodes pull the Jenkins image without a pull secret.
code=$(curl -k -s -o /dev/null -w '%{http_code}' -u "$REPOSITORY_USERNAME:$REPOSITORY_PASSWORD" \
  -H 'Content-Type: application/json' -X POST "$REPOSITORY_URL/api/v2.0/projects" \
  --data "{\"project_name\":\"$HARBOR_PROJECT\",\"public\":true}")
case "$code" in
  201) echo "[OK] Harbor project $HARBOR_PROJECT created" ;;
  409) echo "[INFO] Harbor project $HARBOR_PROJECT already exists" ;;
  *) echo "[ERROR] Cannot create Harbor project $HARBOR_PROJECT (HTTP $code)" >&2; exit 1 ;;
esac

printf '%s' "$REPOSITORY_PASSWORD" | sudo podman login "$HARBOR_HOST" \
  --username "$REPOSITORY_USERNAME" --password-stdin
sudo podman push "$TARGET_IMAGE"

cat <<MSG

[OK] Pushed $TARGET_IMAGE

New installation:
  JENKINS_IMAGE_REGISTRY=$HARBOR_HOST/$HARBOR_PROJECT JENKINS_IMAGE_NAME=$TARGET_NAME ./deploy-cp-pipeline.sh

Existing installation (switch only the Jenkins image):
  helm upgrade cp-pipeline-jenkins ../charts/cp-pipeline-jenkins-${CHART_VERSION[cp-pipeline-jenkins]}.tgz \\
    -n $NAMESPACE -f ../values/cp-pipeline-jenkins.yaml \\
    --set image.registry=$HARBOR_HOST/$HARBOR_PROJECT --set image.name=$TARGET_NAME
MSG
