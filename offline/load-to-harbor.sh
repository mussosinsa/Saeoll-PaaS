#!/bin/bash
# After CP-Portal (Harbor) is installed in the closed network: push the portal's own images from the offline
# bundle into Harbor and print the CI/CD portal settings for the closed network (docs/install-offline.md, 5).
# Run on the admin node (Harbor reachable, cp-portal-vars.sh configured):
#
#   ./load-to-harbor.sh <bundle-dir>     (collect-bundle.sh bundle, or a harbor-export.sh directory)
#   ./load-to-harbor.sh /opt/harbor-export-<date>.tar   (checks the .sha256, unpacks it next to the .tar)
#   env HARBOR_HOST, HARBOR_USER, HARBOR_PASSWORD, CA_FILE, PORTAL_VARS: instead of cp-portal-vars.sh / certs/ca.crt
#
#   cicd-portal/cicd-console, cicd-portal/security-scanner  (private; the console and the scanner pull them with
#                                                           the robot accounts the CI/CD portal creates)
#   cicd-mirror/jenkins:<version>-plugins                    (public; Jenkins controller with its plugins)
#   base-images/<image>                                      (public; FROM images of the application Dockerfiles)
#   mirror/<registry>/<path>                                 (public; Argo CD, GitLab, ... - RKE2 registries.yaml rewrite)
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/.." && pwd)
ok() { echo "[OK]   $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }
BUNDLE=${1:-}
# a harbor-export.sh package: check its .sha256 and unpack it next to it (or into EXTRACT_DIR)
if [[ -f "$BUNDLE" && "$BUNDLE" == *.tar ]]; then
  if [[ -f "$BUNDLE.sha256" ]]; then
    (cd "$(dirname "$BUNDLE")" && sha256sum -c "$(basename "$BUNDLE").sha256") >/dev/null || die "$BUNDLE: sha256 mismatch (copy it again)"
    ok "$(basename "$BUNDLE"): sha256 OK"
  else
    warn "$BUNDLE.sha256 not found: integrity not checked"
  fi
  dir=${EXTRACT_DIR:-$(dirname "$BUNDLE")}
  top=$(tar -tf "$BUNDLE" | head -1 | cut -d/ -f1)
  [[ -n "$top" && "$top" != . && "$top" != .. ]] || die "$BUNDLE: unexpected content"
  [[ -f "$dir/$top/images/harbor-images.txt" ]] || { tar -xf "$BUNDLE" -C "$dir" --no-same-owner; ok "unpacked: $dir/$top"; }
  BUNDLE="$dir/$top"
fi
[[ -n "$BUNDLE" && -f "$BUNDLE/images/harbor-images.txt" ]] || { echo "Usage: $0 <bundle-dir | harbor-export-<date>.tar>" >&2; exit 2; }
BUNDLE=$(cd "$BUNDLE" && pwd)
command -v skopeo >/dev/null || die "skopeo is not installed (dnf install -y skopeo)"

# Harbor of this installation: cp-portal-vars.sh, or the environment (setup-cicd-env.sh passes the values it checked:
# HARBOR_HOST, HARBOR_USER, HARBOR_PASSWORD, CA_FILE)
# shellcheck source=portal-vars.sh
source "$SCRIPT_DIR/portal-vars.sh"
PORTAL_VARS_TMP=""
if [[ -z "${HARBOR_HOST:-}" || -z "${HARBOR_PASSWORD:-}" ]]; then
  resolve_portal_vars "$REPO" || exit 1
fi
PORTAL_VARS=${PORTAL_VARS:-"$REPO/cp-portal-deployment/script/cp-portal-vars.sh"}
mapfile -t V < <(set +u; source "$PORTAL_VARS" >/dev/null 2>&1
                 echo "$HOST_DOMAIN"; echo "$REPOSITORY_USERNAME"; echo "$REPOSITORY_PASSWORD")
HARBOR=${HARBOR_HOST:-"harbor.${V[0]:-}"}
V[1]=${HARBOR_USER:-${V[1]:-admin}}
V[2]=${HARBOR_PASSWORD:-${V[2]:-}}
unset HARBOR_PASSWORD
[[ "$HARBOR" != harbor. && "$HARBOR" != *'{'* ]] || die "Harbor address unknown: configure $PORTAL_VARS or set HARBOR_HOST"
CA_DIR=$(mktemp -d); AUTH="$CA_DIR/auth.json"
trap 'rm -rf "$CA_DIR"; [[ -n "$PORTAL_VARS_TMP" ]] && rm -f "$PORTAL_VARS_TMP"' EXIT
CA_SRC=${CA_FILE:-"$REPO/cp-portal-deployment/certs/ca.crt"}
cp "$CA_SRC" "$CA_DIR/ca.crt" 2>/dev/null || warn "$CA_SRC not found: system CAs only"
# credentials file (0600): the password goes through stdin, not through the command line
printf '%s\n' "${V[2]}" | python3 -c 'import base64,json,sys,os
pw=sys.stdin.readline().rstrip("\n"); fd=os.open(sys.argv[3],os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
os.write(fd,json.dumps({"auths":{sys.argv[1]:{"auth":base64.b64encode((sys.argv[2]+":"+pw).encode()).decode()}}}).encode())' \
  "$HARBOR" "${V[1]}" "$AUTH"
api() { # method path [json]  (credentials through a curl config file, not the command line)
  (umask 077; printf 'user = "%s:%s"\n' "${V[1]}" "${V[2]}" > "$CA_DIR/curl.cfg")
  curl -s -o /dev/null -w '%{http_code}' -K "$CA_DIR/curl.cfg" --cacert "$CA_DIR/ca.crt" -X "$1" \
    -H 'Content-Type: application/json' ${3:+--data "$3"} "https://$HARBOR/api/v2.0$2"
}
project() { # name public
  case "$(api POST /projects "{\"project_name\":\"$1\",\"metadata\":{\"public\":\"$2\"}}")" in
    201) ok "Harbor project $1 created (public: $2)" ;;
    409) ok "Harbor project $1 exists" ;;
    401) die "Harbor login failed (https://$HARBOR, user ${V[1]}): admin password of $PORTAL_VARS (or HARBOR_PASSWORD)" ;;
    *) die "Cannot create Harbor project $1 (https://$HARBOR)" ;;
  esac
}

declare -A done_project
failed=0
total=$(grep -c . "$BUNDLE/images/harbor-images.txt"); n=0
while IFS=$'\t' read -r dest name visibility keep; do
  [[ -n "$dest" ]] || continue
  n=$((n + 1))
  p=${dest%%/*}
  if [[ -z "${done_project[$p]:-}" ]]; then
    project "$p" "$([[ "$visibility" == public ]] && echo true || echo false)"; done_project[$p]=1
  fi
  args=(--quiet --retry-times 2 --authfile "$AUTH" --dest-cert-dir "$CA_DIR")
  [[ "${keep:-}" == all ]] && args+=(--all --preserve-digests)   # pulled by digest: same digest in Harbor
  echo -n "[$n/$total] "
  if skopeo copy "${args[@]}" "oci:$BUNDLE/images/oci:$name" "docker://$HARBOR/$dest"; then
    ok "$HARBOR/$dest"
  else
    failed=$((failed + 1)); warn "$HARBOR/$dest: push failed"
  fi
done < "$BUNDLE/images/harbor-images.txt"

# harbor-export.sh lists the newest tag of a repository first
console_tag=$(awk -F'\t' '$1 ~ /\/cicd-console:/{sub(/.*:/,"",$1); print $1; exit}' "$BUNDLE/images/harbor-images.txt")
scanner_tag=$(awk -F'\t' '$1 ~ /\/security-scanner:/{sub(/.*:/,"",$1); print $1; exit}' "$BUNDLE/images/harbor-images.txt")
jenkins=$(awk -F'\t' '$1 ~ /^cicd-mirror\/jenkins:.*-plugins$/{print $1; exit}' "$BUNDLE/images/harbor-images.txt")
echo
echo "CI/CD portal settings for the closed network - put them in cicd-portal-deployment/script/cicd-vars.sh:"
[[ -d "$BUNDLE/charts" ]] && echo "  CICD_CHART_DIR=\"$BUNDLE/charts\""
[[ -f "$BUNDLE/charts/versions.env" ]] && sed 's/^/  /' "$BUNDLE/charts/versions.env"
[[ -n "$jenkins" ]] && echo "  JENKINS_IMAGE=\"$HARBOR/$jenkins\""
echo "  CICD_BASE_REGISTRY=\"$HARBOR/base-images\""
mariadb=$(awk -F'\t' '$1 ~ /^base-images\/mariadb:/{print $1; exit}' "$BUNDLE/images/harbor-images.txt")
[[ -n "$mariadb" ]] && echo "  MARIADB_IMAGE=\"$HARBOR/$mariadb\""
kaniko=$(awk -F'\t' '$1 ~ /^cicd-mirror\/kaniko-executor:/{print $1; exit}' "$BUNDLE/images/harbor-images.txt")
[[ -n "$kaniko" ]] && echo "  KANIKO_IMAGE=\"$HARBOR/$kaniko\""
jtool=$(awk -F'\t' '$1 ~ /^cicd-mirror\/jenkins:/ && $1 !~ /-plugins$/{print $1; exit}' "$BUNDLE/images/harbor-images.txt")
[[ -n "$jtool" ]] && echo "  JENKINS_TOOL_IMAGE=\"$HARBOR/$jtool\""
grep -q '^base-images/' "$BUNDLE/images/harbor-images.txt" && echo "  CICD_DOCKERHUB=\"$HARBOR/base-images\"   # CI tool images (maven, gradle, node, composer, alpine)"
postgres=$(awk -F'\t' '$1 ~ /^base-images\/postgres:/{print $1; exit}' "$BUNDLE/images/harbor-images.txt")
[[ -n "$postgres" ]] && echo "  (PostgreSQL for the applications: image $HARBOR/$postgres)"
[[ -n "$console_tag" ]] && echo "  CONSOLE_IMAGE_TAG=\"$console_tag\""
[[ -n "$scanner_tag" ]] && echo "  SECURITY_IMAGE_TAG=\"$scanner_tag\""
echo "and skip the image builds: ./deploy-cicd-portal.sh <steps without console-image / security-image>"
mirrors=$(awk -F'\t' '$1 ~ /^mirror\//{split($1, a, "/"); print a[2]}' "$BUNDLE/images/harbor-images.txt" | sort -u | tr '\n' ' ')
if [[ -n "$mirrors" ]]; then
  echo
  echo "Images of other registries are in $HARBOR/mirror/<registry>/...: $mirrors"
  echo "  RKE2 nodes pull them through registries.yaml mirrors (rewrite to mirror/<registry>/): run"
  echo "  cicd-portal-deployment/script/setup-cicd-env.sh, it writes values/rke2-node-ca.sh for every node."
fi
((failed == 0)) || exit 3
