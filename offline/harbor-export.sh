#!/bin/bash
# Back up the CI/CD portal images of the CURRENT Harbor (and the language / DB base images) into a directory that
# load-to-harbor.sh pushes into the Harbor of another K-PaaS (closed network). docs/harbor-image-migration.md
#
# Run on the admin node of the current installation (cp-portal-vars.sh configured, Harbor reachable):
#
#   ./harbor-export.sh [out-dir]          (default: ../harbor-export-<date>)
#
#   1. Harbor projects HARBOR_PROJECTS (default "cicd-portal cicd-mirror base-images"): the newest KEEP_TAGS tags
#      of every repository (cicd-console, security-scanner, jenkins:<ver>-plugins, base-images/...)
#   2. base images of the starters' Dockerfiles (php, java, node.js, vue: composer, php-apache, maven, gradle,
#      eclipse-temurin, node, nginx) + DB_IMAGES (mariadb, postgres) + EXTRA_BASE_IMAGES -> base-images/<image>:
#      taken from the current Harbor base-images, else from docker.io (FROM_DOCKERHUB=0: Harbor only)
#      + CI tool images: kaniko (KANIKO_IMAGE), Jenkins init image (JENKINS_TOOL_IMAGE), alpine -> cicd-mirror / base-images
#   3. JENKINS_PLUGINS=1 (default) and no cicd-mirror/jenkins in Harbor: Jenkins controller image + the plugins of
#      the running Jenkins (podman build, base image from docker.io) -> cicd-mirror/jenkins:<ver>-plugins
#   PACK=1 (default): <out-dir>.tar + .sha256 to carry into the closed network
#
# Output: <out-dir>/images/oci (OCI layout, shared layers), images/harbor-images.txt (<dest>\t<oci name>\t<public|
# private>), images/sources.txt (where each image came from). Passwords never go to the command line or the logs.
# Needs: skopeo, python3, curl (podman + kubectl for 3).
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/.." && pwd)
OUT=${1:-"$REPO/../harbor-export-$(date +%Y%m%d)"}
HARBOR_PROJECTS=${HARBOR_PROJECTS-"cicd-portal cicd-mirror base-images"}   # "" : none
KEEP_TAGS=${KEEP_TAGS:-3}
DB_IMAGES=${DB_IMAGES:-"mariadb:11.4 postgres:16-alpine"}
EXTRA_BASE_IMAGES=${EXTRA_BASE_IMAGES:-""}
FROM_DOCKERHUB=${FROM_DOCKERHUB:-1}
JENKINS_PLUGINS=${JENKINS_PLUGINS:-1}
PACK=${PACK:-1}
PUBLIC_PROJECTS=" cicd-mirror base-images "     # pulled without credentials in the target (nodes, Jenkins agents)

info() { echo "[INFO] $*"; }
ok() { echo "[OK]   $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }
for c in skopeo python3; do command -v "$c" >/dev/null || die "$c is not installed (dnf install -y $c)"; done
[[ "$KEEP_TAGS" =~ ^[1-9][0-9]*$ ]] || die "KEEP_TAGS must be a number >= 1"

mapfile -t V < <(set +u; source "$REPO/cp-portal-deployment/script/cp-portal-vars.sh" >/dev/null 2>&1
                 echo "$HOST_DOMAIN"; echo "$REPOSITORY_USERNAME")
[[ -n "${V[0]:-}" && "${V[0]}" != *'{'* ]] || die "HOST_DOMAIN is not configured in cp-portal-deployment/script/cp-portal-vars.sh"
HARBOR="harbor.${V[0]}"
harbor_password() { (set +u; source "$REPO/cp-portal-deployment/script/cp-portal-vars.sh" >/dev/null 2>&1
                     printf '%s\n' "$REPOSITORY_PASSWORD"); }
cicd_var() { (set +u; source "$REPO/cicd-portal-deployment/script/cicd-vars.sh" >/dev/null 2>&1; echo "${!1}"); }

mkdir -p "$OUT/images"
OUT=$(cd "$OUT" && pwd)
TMP=$(mktemp -d); chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT
CERTS="$TMP/certs"; mkdir -p "$CERTS"
cp "$REPO/cp-portal-deployment/certs/ca.crt" "$CERTS/ca.crt" 2>/dev/null || warn "cp-portal-deployment/certs/ca.crt not found: system CAs only"
AUTH="$TMP/auth.json"
# registry credentials file (0600) - the password goes through stdin, never through arguments
harbor_password | python3 -c 'import base64,json,sys,os
pw=sys.stdin.readline().rstrip("\n"); fd=os.open(sys.argv[3],os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
os.write(fd,json.dumps({"auths":{sys.argv[1]:{"auth":base64.b64encode((sys.argv[2]+":"+pw).encode()).decode()}}}).encode())' \
  "$HARBOR" "${V[1]}" "$AUTH"

LIST="$OUT/images/harbor-images.txt"
SOURCES="$OUT/images/sources.txt"
: > "$LIST"; : > "$SOURCES"
declare -A DONE
FAILED=()
oci_name() { echo "harbor_$1" | tr '/:@' '___'; }

# export <source docker ref> <destination project/repo:tag> [auth: harbor|none]
export_image() {
  local src=$1 dest=$2 how=${3:-harbor} name project visibility
  [[ -z "${DONE[$dest]:-}" ]] || return 0
  name=$(oci_name "$dest")
  project=${dest%%/*}
  visibility=$([[ "$PUBLIC_PROJECTS" == *" $project "* ]] && echo public || echo private)
  local args=(--quiet --retry-times 2)
  [[ "$how" == harbor ]] && args+=(--authfile "$AUTH" --src-cert-dir "$CERTS")
  if skopeo copy "${args[@]}" "docker://$src" "oci:$OUT/images/oci:$name"; then
    printf '%s\t%s\t%s\n' "$dest" "$name" "$visibility" >> "$LIST"
    printf '%s\t%s\n' "$dest" "$src" >> "$SOURCES"
    DONE[$dest]=1
    ok "$dest  <- $src"
    return 0
  fi
  return 1
}

# Harbor API: tags of a project (newest KEEP_TAGS artifacts per repository), "project/repo:tag" per line
harbor_tags() {
  harbor_password | python3 - "$HARBOR" "${V[1]}" "$1" "$KEEP_TAGS" "$CERTS/ca.crt" <<'PY'
import base64, json, os, ssl, sys, urllib.error, urllib.parse, urllib.request
host, user, project, keep, ca = sys.argv[1:6]
pw = sys.stdin.readline().rstrip("\n")
ctx = ssl.create_default_context(cafile=ca if os.path.exists(ca) else None)
hdr = {"Authorization": "Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode()}
def get(path):
    out, page = [], 1
    while True:
        sep = "&" if "?" in path else "?"
        req = urllib.request.Request(f"https://{host}/api/v2.0{path}{sep}page={page}&page_size=100", headers=hdr)
        with urllib.request.urlopen(req, context=ctx, timeout=60) as r:
            items = json.loads(r.read() or b"[]")
        out += items
        if len(items) < 100:
            return out
        page += 1
try:
    repos = get(f"/projects/{urllib.parse.quote(project)}/repositories")
except urllib.error.HTTPError as e:
    sys.exit(0 if e.code == 404 else f"[ERROR] Harbor {project}: HTTP {e.code} (admin account of cp-portal-vars.sh?)")
except (urllib.error.URLError, OSError) as e:
    sys.exit(f"[ERROR] https://{host}: {getattr(e, 'reason', e)}")
for repo in repos:
    name = repo["name"].split("/", 1)[1]
    arts = get(f"/projects/{urllib.parse.quote(project)}/repositories/"
               f"{urllib.parse.quote(urllib.parse.quote(name, safe=''), safe='')}/artifacts?with_tag=true")
    arts = sorted((a for a in arts if a.get("tags")), key=lambda a: a.get("push_time") or "", reverse=True)
    for a in arts[:int(keep)]:
        for t in a["tags"]:
            print(f"{project}/{name}:{t['name']}")
PY
}

# 1. Harbor projects ------------------------------------------------------------------------------------------------
for project in $HARBOR_PROJECTS; do
  harbor_tags "$project" > "$TMP/tags" || { FAILED+=("Harbor project $project (list)"); continue; }
  mapfile -t refs < "$TMP/tags"
  ((${#refs[@]})) || { info "Harbor project $project: no tagged images (or the project does not exist)"; continue; }
  info "Harbor project $project: ${#refs[@]} images"
  for ref in "${refs[@]}"; do
    export_image "$HARBOR/$ref" "$ref" || { FAILED+=("$ref"); warn "$ref: copy failed"; }
  done
done

# 2. base images: starters (php, java, node.js, vue) + DB + extra ----------------------------------------------------
mariadb=$(cicd_var MARIADB_IMAGE); mariadb=${mariadb##*/}
mapfile -t BASES < <({ grep -rhoE '^FROM \$\{BASE_REGISTRY\}/[^ ]+' "$REPO/cicd-portal-deployment/starters" 2>/dev/null |
                       sed 's|^FROM ${BASE_REGISTRY}/||'
                       printf '%s\n' $DB_IMAGES $EXTRA_BASE_IMAGES ${mariadb:+"$mariadb"}; } | sed '/^$/d' | sort -u)
for b in "${BASES[@]}"; do
  dest="base-images/$b"
  [[ -z "${DONE[$dest]:-}" ]] || continue
  if export_image "$HARBOR/$dest" "$dest" harbor 2>/dev/null; then continue; fi
  if [[ "$FROM_DOCKERHUB" == 1 ]] && export_image "docker.io/library/$b" "$dest" none; then continue; fi
  FAILED+=("$dest"); warn "$dest: not in $HARBOR/base-images$([[ "$FROM_DOCKERHUB" == 1 ]] && echo " nor docker.io")"
done

# 2b. CI tool images: kaniko (image builds in Jenkins), Jenkins keytool init image, alpine -----------------------------
kaniko=$(cicd_var KANIKO_IMAGE); jtool=$(cicd_var JENKINS_TOOL_IMAGE)
declare -A TOOLS=()
[[ -n "$kaniko" ]] && TOOLS["cicd-mirror/kaniko-executor:${kaniko##*:}"]=$kaniko
[[ -n "$jtool" ]] && TOOLS["cicd-mirror/jenkins:${jtool##*:}"]="docker.io/${jtool#docker.io/}"
TOOLS["base-images/alpine:3.20"]="docker.io/library/alpine:3.20"
for dest in "${!TOOLS[@]}"; do
  [[ -z "${DONE[$dest]:-}" ]] || continue
  if export_image "$HARBOR/$dest" "$dest" harbor 2>/dev/null; then continue; fi
  if [[ "$FROM_DOCKERHUB" == 1 ]] && export_image "${TOOLS[$dest]}" "$dest" none; then continue; fi
  FAILED+=("$dest"); warn "$dest: not in $HARBOR nor ${TOOLS[$dest]}"
done

# 3. Jenkins with its plugins (only when Harbor has none yet) ----------------------------------------------------------
if [[ "$JENKINS_PLUGINS" == 1 ]] && ! grep -q '^cicd-mirror/jenkins:.*-plugins' "$LIST"; then
  jns=$(cicd_var JENKINS_NAMESPACE); jns=${jns:-cicd-jenkins}
  if command -v podman >/dev/null && command -v kubectl >/dev/null && kubectl -n "$jns" get pod jenkins-0 >/dev/null 2>&1; then
    jimg=$(kubectl -n "$jns" get pod jenkins-0 -o jsonpath='{.spec.containers[?(@.name=="jenkins")].image}')
    [[ "$jimg" == */*/* ]] || jimg="docker.io/${jimg}"
    ctx="$TMP/jenkins"; mkdir -p "$ctx/plugins"
    kubectl -n "$jns" exec jenkins-0 -c jenkins -- sh -c 'cd /var/jenkins_home/plugins && tar cf - $(ls *.jpi *.hpi 2>/dev/null)' |
      tar xf - -C "$ctx/plugins"
    printf 'FROM %s\nCOPY plugins/ /usr/share/jenkins/ref/plugins/\n' "$jimg" > "$ctx/Containerfile"
    jtag="${jimg##*:}-plugins"
    dest="cicd-mirror/jenkins:$jtag"
    if podman build -q -t "localhost/cicd-jenkins:$jtag" -f "$ctx/Containerfile" "$ctx" >/dev/null &&
       skopeo copy --quiet "containers-storage:localhost/cicd-jenkins:$jtag" "oci:$OUT/images/oci:$(oci_name "$dest")"; then
      printf '%s\t%s\t%s\n' "$dest" "$(oci_name "$dest")" public >> "$LIST"
      printf '%s\t%s\n' "$dest" "$jimg + $(ls "$ctx/plugins" | wc -l) plugins of $jns/jenkins-0" >> "$SOURCES"
      ok "$dest  <- $jimg + plugins of the running Jenkins"
      podman rmi -f "localhost/cicd-jenkins:$jtag" >/dev/null 2>&1 || true
    else
      FAILED+=("$dest"); warn "Jenkins image with plugins not built (base image $jimg reachable?)"
    fi
  else
    info "Jenkins (podman / kubectl / $jns/jenkins-0) not available: no Jenkins image - only scm vendors need it"
  fi
fi

# summary + package ---------------------------------------------------------------------------------------------------
count=$(wc -l < "$LIST")
((count)) || die "nothing exported"
{ echo "# Harbor image export $(date -Iseconds) from $HARBOR"
  echo "# load in the closed network: offline/load-to-harbor.sh <this directory>  (docs/harbor-image-migration.md)"
  cut -f1,3 "$LIST"; } > "$OUT/README.txt"
echo
ok "$count images -> $OUT ($(du -sh "$OUT/images" | cut -f1))"
if [[ "$PACK" == 1 ]]; then
  tar -C "$(dirname "$OUT")" -cf "$OUT.tar" "$(basename "$OUT")"
  (cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT").tar" > "$(basename "$OUT").tar.sha256")
  ok "package: $OUT.tar (+ .sha256) - carry it into the closed network"
fi
if ((${#FAILED[@]})); then
  warn "not exported (${#FAILED[@]}):"; printf '       - %s\n' "${FAILED[@]}" >&2
  exit 3
fi
