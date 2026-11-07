#!/bin/bash
# After CP-Portal (Harbor) is installed in the closed network: push the portal's own images from the offline
# bundle into Harbor and print the CI/CD portal settings for the closed network (docs/install-offline.md, 5).
# Run on the admin node (Harbor reachable, cp-portal-vars.sh configured):
#
#   ./load-to-harbor.sh <bundle-dir>
#
#   cicd-portal/cicd-console, cicd-portal/security-scanner  (private; the console and the scanner pull them with
#                                                           the robot accounts the CI/CD portal creates)
#   cicd-mirror/jenkins:<version>-plugins                    (public; Jenkins controller with its plugins)
#   base-images/<image>                                      (public; FROM images of the application Dockerfiles)
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/.." && pwd)
BUNDLE=${1:-}
[[ -n "$BUNDLE" && -f "$BUNDLE/images/harbor-images.txt" ]] || { echo "Usage: $0 <bundle-dir>" >&2; exit 2; }
BUNDLE=$(cd "$BUNDLE" && pwd)
ok() { echo "[OK]   $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }
command -v skopeo >/dev/null || die "skopeo is not installed (dnf install -y skopeo)"

mapfile -t V < <(set +u; source "$REPO/cp-portal-deployment/script/cp-portal-vars.sh" >/dev/null 2>&1
                 echo "$HOST_DOMAIN"; echo "$REPOSITORY_USERNAME"; echo "$REPOSITORY_PASSWORD")
HARBOR="harbor.${V[0]}"
CA_DIR=$(mktemp -d); AUTH="$CA_DIR/auth.json"
trap 'rm -rf "$CA_DIR"' EXIT
cp "$REPO/cp-portal-deployment/certs/ca.crt" "$CA_DIR/ca.crt" 2>/dev/null || warn "cp-portal-deployment/certs/ca.crt not found: system CAs only"
python3 -c 'import base64,json,sys;json.dump({"auths":{sys.argv[1]:{"auth":base64.b64encode((sys.argv[2]+":"+sys.argv[3]).encode()).decode()}}},open(sys.argv[4],"w"))' \
  "$HARBOR" "${V[1]}" "${V[2]}" "$AUTH"
chmod 600 "$AUTH"
api() { # method path [json]  (credentials through a curl config file, not the command line)
  printf 'user = "%s:%s"\n' "${V[1]}" "${V[2]}" > "$CA_DIR/curl.cfg"
  curl -s -o /dev/null -w '%{http_code}' -K "$CA_DIR/curl.cfg" --cacert "$CA_DIR/ca.crt" -X "$1" \
    -H 'Content-Type: application/json' ${3:+--data "$3"} "https://$HARBOR/api/v2.0$2"
}
project() { # name public
  case "$(api POST /projects "{\"project_name\":\"$1\",\"metadata\":{\"public\":\"$2\"}}")" in
    201) ok "Harbor project $1 created (public: $2)" ;;
    409) ok "Harbor project $1 exists" ;;
    *) die "Cannot create Harbor project $1 (https://$HARBOR, admin account of cp-portal-vars.sh)" ;;
  esac
}

declare -A done_project
failed=0
while IFS=$'\t' read -r dest name visibility; do
  p=${dest%%/*}
  if [[ -z "${done_project[$p]:-}" ]]; then
    project "$p" "$([[ "$visibility" == public ]] && echo true || echo false)"; done_project[$p]=1
  fi
  if skopeo copy --quiet --authfile "$AUTH" --dest-cert-dir "$CA_DIR" "oci:$BUNDLE/images/oci:$name" "docker://$HARBOR/$dest"; then
    ok "$HARBOR/$dest"
  else
    failed=$((failed + 1)); warn "$HARBOR/$dest: push failed"
  fi
done < "$BUNDLE/images/harbor-images.txt"

console_tag=$(awk -F'\t' '$1 ~ /\/cicd-console:/{sub(/.*:/,"",$1); print $1}' "$BUNDLE/images/harbor-images.txt")
scanner_tag=$(awk -F'\t' '$1 ~ /\/security-scanner:/{sub(/.*:/,"",$1); print $1}' "$BUNDLE/images/harbor-images.txt")
jenkins=$(awk -F'\t' '$1 ~ /^cicd-mirror\/jenkins:/{print $1}' "$BUNDLE/images/harbor-images.txt")
echo
echo "CI/CD portal settings for the closed network - put them in cicd-portal-deployment/script/cicd-vars.sh:"
echo "  CICD_CHART_DIR=\"$BUNDLE/charts\""
[[ -f "$BUNDLE/charts/versions.env" ]] && sed 's/^/  /' "$BUNDLE/charts/versions.env"
[[ -n "$jenkins" ]] && echo "  JENKINS_IMAGE=\"$HARBOR/$jenkins\""
echo "  CICD_BASE_REGISTRY=\"$HARBOR/base-images\""
[[ -n "$console_tag" ]] && echo "  CONSOLE_IMAGE_TAG=\"$console_tag\""
[[ -n "$scanner_tag" ]] && echo "  SECURITY_IMAGE_TAG=\"$scanner_tag\""
echo "and skip the image builds: ./deploy-cicd-portal.sh <steps without console-image / security-image>"
((failed == 0)) || exit 3
