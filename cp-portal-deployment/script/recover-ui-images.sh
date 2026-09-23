#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

# Reuse the release variables and the certificate-aware UI build function.
# shellcheck source=deploy-cp-portal.sh
source ./deploy-cp-portal.sh

REPOSITORY_HOST=${REPOSITORY_URL#*://}
REPOSITORY_HOST=${REPOSITORY_HOST%%/*}
CERT_FILE="../certs/${HOST_DOMAIN}.crt"

[[ -f "$CERT_FILE" ]] || {
  echo "[ERROR] Generated portal certificate not found: $CERT_FILE" >&2
  exit 1
}
[[ -f ../values/ui/Dockerfile.template ]] || {
  echo "[ERROR] Generated values directory not found. Run the portal deployment preparation first." >&2
  exit 1
}

echo "[INFO] Checking Harbor: $REPOSITORY_URL"
curl --fail --silent --show-error --insecure \
  --user "$REPOSITORY_USERNAME:$REPOSITORY_PASSWORD" \
  "$REPOSITORY_URL/api/v2.0/projects/$REPOSITORY_PROJECT_NAME" >/dev/null

printf '%s' "$REPOSITORY_PASSWORD" | sudo podman login "$REPOSITORY_HOST" \
  --username "$REPOSITORY_USERNAME" --password-stdin

inject_cert_and_build_image

for app in cp-portal-ui cp-portal-migration-ui; do
  echo "[INFO] Verifying $app:$IMAGE_TAGS in Harbor..."
  tags=$(curl --fail --silent --show-error --insecure \
    --user "$REPOSITORY_USERNAME:$REPOSITORY_PASSWORD" \
    "$REPOSITORY_URL/v2/$REPOSITORY_PROJECT_NAME/$app/tags/list")
  TAGS_JSON="$tags" IMAGE_TAG="$IMAGE_TAGS" python3 - <<'PY'
import json
import os
import sys

payload = json.loads(os.environ["TAGS_JSON"])
tag = os.environ["IMAGE_TAG"]
if tag not in (payload.get("tags") or []):
    print(f"[ERROR] Harbor does not contain expected tag: {tag}", file=sys.stderr)
    raise SystemExit(1)
PY
done

echo "[INFO] Recreating the Harbor pull secret..."
kubectl -n "${NAMESPACE[4]}" create secret docker-registry "$IMAGE_PULL_SECRET" \
  --docker-server="$REPOSITORY_HOST" \
  --docker-username="$REPOSITORY_USERNAME" \
  --docker-password="$REPOSITORY_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

for app in cp-portal-ui cp-portal-migration-ui; do
  deployment="${app}-deployment"
  kubectl -n "${NAMESPACE[4]}" rollout restart "deployment/$deployment"
  kubectl -n "${NAMESPACE[4]}" rollout status "deployment/$deployment" --timeout=5m
done

echo "[OK] UI images were pushed and both deployments are ready."
