#!/bin/bash
# Register an uploaded container image file (CI/CD console: 컨테이너 이미지 등록) for an image application.
#
# Usage: ./upload-image.sh <vendor> <app> <tag> <image-file>
#   image-file : docker save / podman save output (.tar, docker-archive or oci-archive, optionally gzip).
#                It is deleted when the script ends (the console stores uploads in an emptyDir).
#   NEW_APP=1  : first add the application (./add-app.sh <vendor> <app> image <APP_HEALTH>), with
#                APP_PORT (default: the image's EXPOSE port, else 8080) and APP_MEMORY_LIMIT
#   DEPLOY_DEV=1 (default): deploy the pushed image to dev (Jenkins <vendor>/<app>-deploy: security gate ->
#                gitops overlays/dev -> Argo CD auto sync). prod stays: 이미지 prod 승격 + prod Sync by cicd-admins.
#   UPLOAD_MAX_BYTES : limit of the decompressed size of a .tar.gz
#
# Steps: inspect (linux/amd64, one image) -> [add-app] -> skopeo copy to Harbor <vendor>/<app>:<tag> with a
# robot account of the vendor's project only (robot$<vendor>+upload, fresh secret in a 0600 auth file)
# -> [dev deploy]. A tag v* that already exists in Harbor is refused (release tags are immutable).
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
# shellcheck source=lib.sh
source ./lib.sh

VENDOR=${1:-}
APP=${2:-}
TAG=${3:-}
FILE=${4:-}
NAME_RE='^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$'
TAG_RE='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
WORK=""
cleanup() {
  [[ -n "$FILE" ]] && rm -f -- "$FILE" "$FILE.tar"
  [[ -n "$WORK" ]] && rm -rf -- "$WORK"
  return 0
}
trap cleanup EXIT
if [[ ! "$VENDOR" =~ $NAME_RE || ! "$APP" =~ $NAME_RE || "$APP" == gitops || ! "$TAG" =~ $TAG_RE || ! -f "$FILE" ]]; then
  echo "Usage: $0 <vendor> <app> <tag> <image-file>" >&2
  exit 2
fi

load_portal_vars
require_cmds kubectl python3 skopeo
SOURCE=$(vendor_source "$VENDOR")
[[ "$SOURCE" == scm ]] || die "Image applications need an scm vendor (K-PaaS SCM + Jenkins); $VENDOR uses '${SOURCE:-?}'."
HARBOR_REGISTRY=${HARBOR_HOST:-$(python3 -c 'import sys,urllib.parse;print(urllib.parse.urlparse(sys.argv[1]).netloc)' "$HARBOR_URL")}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/upload-image.XXXXXX")

# 1. Inspect ---------------------------------------------------------------------------------------------
info "Image file: $(du -h "$FILE" | cut -f1) (uploaded by ${UPLOAD_USER:-?})"
python3 image_archive.py prepare "$FILE" --max-bytes "${UPLOAD_MAX_BYTES:-0}" > "$WORK/image.json" || \
  die "Not a usable image file (see the message above)."
field() { python3 -c 'import json,sys;v=json.load(open(sys.argv[1]))[sys.argv[2]];print(" ".join(map(str,v)) if isinstance(v,list) else v)' "$WORK/image.json" "$1"; }
IMAGE_PATH=$(field path)
TRANSPORT=$(field transport)
PORTS=$(field ports)
ok "Image: $TRANSPORT, $(field os)/$(field arch), user '$(field user)', ports ${PORTS:-none}"
python3 -c 'import json,sys;[print("[WARN] "+w) for w in json.load(open(sys.argv[1]))["warnings"]]' "$WORK/image.json"

# 2. Tag ------------------------------------------------------------------------------------------------
existing=$($API harbor-tag-digest "$VENDOR" "$APP" "$TAG" 2>/dev/null || true)
if [[ -n "$existing" ]]; then
  [[ "$TAG" == v* ]] && die "Harbor $VENDOR/$APP:$TAG already exists ($existing). Release tags v* cannot be overwritten: use a new version."
  warn "Harbor $VENDOR/$APP:$TAG already exists ($existing): the tag moves to the uploaded image."
fi

# 3. Application (new) ----------------------------------------------------------------------------------
if [[ "${NEW_APP:-0}" == 1 ]]; then
  port=${APP_PORT:-}
  if [[ -z "$port" ]]; then
    port=${PORTS%% *}
    port=${port:-8080}
    info "Container port $port (from the image)"
  fi
  APP_PORT="$port" bash ./add-app.sh "$VENDOR" "$APP" image ${APP_HEALTH:+"$APP_HEALTH"} || die "앱 추가 failed."
fi

# 4. Push to Harbor ---------------------------------------------------------------------------------------
mkdir -m 700 "$WORK/certs"
[[ -f "${CA_FILE:-}" ]] && cp "$CA_FILE" "$WORK/certs/ca.crt"
robot=$($API harbor-authfile "$VENDOR" upload --file "$WORK/auth.json") || die "Cannot create the Harbor upload account."
echo '{"default":[{"type":"insecureAcceptAnything"}]}' > "$WORK/policy.json"
DEST="$HARBOR_REGISTRY/$VENDOR/$APP:$TAG"
info "Pushing to $DEST as $robot"
TMPDIR="$WORK" skopeo --policy "$WORK/policy.json" --override-os linux --override-arch amd64 \
  copy --retry-times 2 \
  --dest-authfile "$WORK/auth.json" --dest-cert-dir "$WORK/certs" \
  --digestfile "$WORK/digest" \
  "$TRANSPORT:$IMAGE_PATH" "docker://$DEST" || die "Push to Harbor failed."
rm -f -- "$IMAGE_PATH"
DIGEST=$(cat "$WORK/digest")
[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || die "Unexpected digest from skopeo: $DIGEST"
ok "Harbor $DEST ($DIGEST)"

# 5. dev deployment ---------------------------------------------------------------------------------------
if [[ "${DEPLOY_DEV:-1}" == 1 ]]; then
  $API jenkins-trigger "$VENDOR" "$APP-deploy" "IMAGE_TAG=$TAG" "IMAGE_DIGEST=$DIGEST" TARGET=dev || \
    die "Image pushed, but the dev deployment could not be started: CI/CD console > $VENDOR/$APP > 이미지 배포."
  ok "dev deployment started: security gate -> gitops dev -> Argo CD $VENDOR-$APP-dev (auto sync)"
fi

echo
echo "Image $VENDOR/$APP:$TAG registered."
echo "  Harbor   : $DEST"
echo "  Digest   : $DIGEST"
echo "  Jenkins  : https://$JENKINS_HOST/job/$VENDOR/job/$APP-deploy/"
echo "  Dev URL  : https://$APP-$VENDOR-dev.$HOST_DOMAIN"
if [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "After testing dev: CI/CD console > $VENDOR/$APP > prod 승격 ($TAG), then prod Sync by cicd-admins."
else
  echo "prod accepts vX.Y.Z tags only: upload a release tag for production."
fi
