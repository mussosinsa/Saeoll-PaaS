#!/bin/bash
# Company repository: Nexus Repository 3 on the bootstrap VM (docs/install-offline.md, 6). Run as root on the
# bootstrap VM after bootstrap-server.sh (the Nexus image comes from the bootstrap registry). Re-runnable.
#
#   NEXUS_ADMIN_PASSWORD='<new admin password>' ./nexus-setup.sh
#
#   container  nexus (NEXUS_IMAGE) on NEXUS_PORT (8081), data BOOTSTRAP_DATA/nexus, systemd unit, firewalld port
#   admin      the initial password (admin.password) is replaced by NEXUS_ADMIN_PASSWORD (never printed)
#   anonymous  read access on (the builds download without credentials; uploads need the admin account)
#   repositories (hosted: filled from the offline bundle by nexus-load.sh; the closed network has no proxy):
#     maven-offline  (maven2)  -> group maven-public (+ maven-releases, maven-snapshots)   Maven, Gradle, wrappers
#     npm-offline    (npm)     -> group npm-public                                          npm
#     composer-offline (raw)   packages.json + dist zips                                    Composer
#     files-offline  (raw)     Gradle distributions and other files
#   The builds use them through cicd-deps.sh when the CI/CD portal has CICD_NEXUS_URL=http://<bootstrap>:8081
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=offline-vars.sh
source "$SCRIPT_DIR/offline-vars.sh"
ok() { echo "[OK]   $*"; }
info() { echo "[INFO] $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }
((EUID == 0)) || die "Run as root."
[[ -n "${NEXUS_ADMIN_PASSWORD:-}" && ${#NEXUS_ADMIN_PASSWORD} -ge 12 ]] || \
  die "Set NEXUS_ADMIN_PASSWORD (12 characters or more): the admin password of Nexus."
URL="http://localhost:$NEXUS_PORT"
DATA="$BOOTSTRAP_DATA/nexus"

# 1. container ---------------------------------------------------------------------------------------------------
if ! podman image exists "$NEXUS_IMAGE"; then
  podman pull -q --tls-verify=false "localhost:$BOOTSTRAP_REGISTRY_PORT/$NEXUS_IMAGE" >/dev/null || \
    die "$NEXUS_IMAGE is not in the bootstrap registry (offline-vars.sh NEXUS_IMAGE, collect-bundle.sh images)"
  podman tag "localhost:$BOOTSTRAP_REGISTRY_PORT/$NEXUS_IMAGE" "$NEXUS_IMAGE"
fi
mkdir -p "$DATA" && chown -R 200:200 "$DATA"     # nexus user of the image
if ! podman container exists nexus; then
  podman run -d --name nexus --restart=always -p "$NEXUS_PORT:8081" -v "$DATA:/nexus-data:Z" \
    -e INSTALL4J_ADD_VM_PARAMS="-Xms1g -Xmx2g -XX:MaxDirectMemorySize=2g -Djava.util.prefs.userRoot=/nexus-data/javaprefs" \
    "$NEXUS_IMAGE" >/dev/null
fi
(cd /etc/systemd/system && podman generate systemd --new --files --name nexus >/dev/null 2>&1) && \
  systemctl daemon-reload && systemctl enable container-nexus.service >/dev/null 2>&1 || true
if systemctl is-active -q firewalld; then
  firewall-cmd -q --permanent --add-port="$NEXUS_PORT/tcp" && firewall-cmd -q --reload
fi
info "Waiting for Nexus (first start: 2-5 minutes)"
for _ in $(seq 1 120); do
  [[ "$(curl -s -o /dev/null -w '%{http_code}' "$URL/service/rest/v1/status/writable")" == 200 ]] && break
  sleep 5
done
[[ "$(curl -s -o /dev/null -w '%{http_code}' "$URL/service/rest/v1/status/writable")" == 200 ]] || \
  die "Nexus does not answer on $URL (podman logs nexus)"
ok "Nexus running: http://$BOOTSTRAP_HOST:$NEXUS_PORT"

# 2. admin password (credentials through a curl config file, not the command line) ------------------------------------
CFG=$(mktemp); trap 'rm -f "$CFG"' EXIT; chmod 600 "$CFG"
auth() { printf 'user = "admin:%s"\n' "$1" > "$CFG"; }
api() { # method path [json] -> http code
  curl -s -o /dev/null -w '%{http_code}' -K "$CFG" -X "$1" -H 'Content-Type: application/json' ${3:+--data "$3"} "$URL$2"
}
auth "$NEXUS_ADMIN_PASSWORD"
if [[ "$(api GET /service/rest/v1/status/check)" != 200 ]]; then
  [[ -f "$DATA/admin.password" ]] || die "admin password is neither NEXUS_ADMIN_PASSWORD nor the initial one ($DATA/admin.password)"
  auth "$(cat "$DATA/admin.password")"
  printf '%s' "$NEXUS_ADMIN_PASSWORD" > "$DATA/.newpw" && chmod 600 "$DATA/.newpw"
  code=$(curl -s -o /dev/null -w '%{http_code}' -K "$CFG" -X PUT -H 'Content-Type: text/plain' \
           --data-binary "@$DATA/.newpw" "$URL/service/rest/v1/security/users/admin/change-password")
  rm -f "$DATA/.newpw"
  [[ "$code" == 204 ]] || die "Cannot change the admin password (HTTP $code)"
  rm -f "$DATA/admin.password"
  auth "$NEXUS_ADMIN_PASSWORD"
  ok "admin password changed (initial password removed)"
fi

# 3. anonymous read --------------------------------------------------------------------------------------------------
[[ "$(api PUT /service/rest/v1/security/anonymous '{"enabled":true,"userId":"anonymous","realmName":"NexusAuthorizingRealm"}')" == 200 ]] && \
  ok "anonymous read access on" || info "anonymous access not changed (check Security > Anonymous Access)"

# 4. repositories ------------------------------------------------------------------------------------------------------
existing=$(curl -s -K "$CFG" "$URL/service/rest/v1/repositories" | python3 -c 'import json,sys;print(" ".join(r["name"] for r in json.load(sys.stdin)))')
storage='"storage":{"blobStoreName":"default","strictContentTypeValidation":false,"writePolicy":"allow"}'
repo() { # format type name json-rest
  local code
  if [[ " $existing " == *" $3 "* ]]; then
    code=$(api PUT "/service/rest/v1/repositories/$1/$2/$3" "{\"name\":\"$3\",\"online\":true,$4}")
  else
    code=$(api POST "/service/rest/v1/repositories/$1/$2" "{\"name\":\"$3\",\"online\":true,$4}")
  fi
  [[ "$code" == 201 || "$code" == 204 ]] && ok "repository $3 ($1 $2)" || die "repository $3: HTTP $code"
}
repo maven hosted maven-offline "$storage,\"maven\":{\"versionPolicy\":\"MIXED\",\"layoutPolicy\":\"PERMISSIVE\"}"
members='"maven-offline"'
for m in maven-releases maven-snapshots; do [[ " $existing " == *" $m "* ]] && members+=",\"$m\""; done
repo maven group maven-public "\"storage\":{\"blobStoreName\":\"default\",\"strictContentTypeValidation\":true},\"group\":{\"memberNames\":[$members]}"
repo npm hosted npm-offline "$storage"
repo npm group npm-public '"storage":{"blobStoreName":"default","strictContentTypeValidation":true},"group":{"memberNames":["npm-offline"]}'
repo raw hosted composer-offline "$storage,\"raw\":{\"contentDisposition\":\"ATTACHMENT\"}"
repo raw hosted files-offline "$storage,\"raw\":{\"contentDisposition\":\"ATTACHMENT\"}"

echo
echo "Nexus ready: http://$BOOTSTRAP_HOST:$NEXUS_PORT  (admin: NEXUS_ADMIN_PASSWORD; builds read anonymously)"
echo "  Load the dependencies of the bundle:  NEXUS_ADMIN_PASSWORD=... ./nexus-load.sh <bundle>/appdeps"
echo "  CI/CD portal (cicd-vars.sh):         CICD_NEXUS_URL=\"http://$BOOTSTRAP_HOST:$NEXUS_PORT\""
