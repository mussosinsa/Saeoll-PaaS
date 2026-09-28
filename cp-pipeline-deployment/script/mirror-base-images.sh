#!/bin/bash
# Mirror approved base images into the Harbor public project "base-images" so
# vendor builds do not depend on Docker Hub (rate limits, closed networks).
#
# Usage: ./mirror-base-images.sh [image ...]
#   default images: php:8.3-apache composer:2
#   e.g. ./mirror-base-images.sh php:8.2-apache php:8.3-fpm nginx:1.27-alpine
# Env: BASE_PROJECT (default base-images), SOURCE_REGISTRY (default docker.io/library)
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
source cp-pipeline-vars.sh
PORTAL_VARS=${PORTAL_VARS:-"$SCRIPT_DIR/../../cp-portal-deployment/script/cp-portal-vars.sh"}
eval "$(sed -n '/^load_portal_vars()/,/^}/p' deploy-cp-pipeline.sh)"
load_portal_vars

BASE_PROJECT=${BASE_PROJECT:-base-images}
SOURCE_REGISTRY=${SOURCE_REGISTRY:-docker.io/library}
HARBOR_HOST=$(echo "$REPOSITORY_URL" | awk -F[/:] '{print $4}')
IMAGES=("$@")
((${#IMAGES[@]})) || IMAGES=(php:8.3-apache composer:2)

code=$(curl -k -s -o /dev/null -w '%{http_code}' -u "$REPOSITORY_USERNAME:$REPOSITORY_PASSWORD" \
  -H 'Content-Type: application/json' -X POST "$REPOSITORY_URL/api/v2.0/projects" \
  --data "{\"project_name\":\"$BASE_PROJECT\",\"public\":true}")
case "$code" in
  201) echo "[OK] Harbor project created: $BASE_PROJECT (public)" ;;
  409) echo "[INFO] Harbor project exists: $BASE_PROJECT" ;;
  *) echo "[ERROR] Cannot create Harbor project $BASE_PROJECT (HTTP $code)" >&2; exit 1 ;;
esac

printf '%s' "$REPOSITORY_PASSWORD" | sudo podman login "$HARBOR_HOST" \
  --username "$REPOSITORY_USERNAME" --password-stdin

for image in "${IMAGES[@]}"; do
  src="$SOURCE_REGISTRY/$image"
  [[ "$image" == */* ]] && src="$image"          # full reference given
  dst="$HARBOR_HOST/$BASE_PROJECT/${image##*/}"
  echo "[INFO] $src -> $dst"
  sudo podman pull "$src"
  sudo podman tag "$src" "$dst"
  sudo podman push "$dst"
  digest=$(sudo podman image inspect --format '{{.Digest}}' "$src")
  echo "[OK] $dst ($digest)"
done

echo
echo "Registered base images: $REPOSITORY_URL/harbor/projects (project $BASE_PROJECT)"
