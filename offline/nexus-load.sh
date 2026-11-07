#!/bin/bash
# Upload collected application dependencies (collect-app-deps.sh) into the company Nexus (nexus-setup.sh).
# Run on the bootstrap VM or any host of the closed network that reaches Nexus. Re-runnable: what is already in
# Nexus is skipped, packages.json is merged.
#
#   NEXUS_ADMIN_PASSWORD=... ./nexus-load.sh <appdeps-dir> [nexus-url]     (default http://localhost:8081)
#
# The dist URLs of packages.json use NEXUS_PUBLIC_URL (default http://<BOOTSTRAP_HOST>:<NEXUS_PORT>): the
# address the builds reach Nexus with.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=offline-vars.sh
source "$SCRIPT_DIR/offline-vars.sh"
DEPS=${1:-}
[[ -n "$DEPS" && -d "$DEPS" ]] || { echo "Usage: NEXUS_ADMIN_PASSWORD=... $0 <appdeps-dir> [nexus-url]" >&2; exit 2; }
DEPS=$(cd "$DEPS" && pwd)
URL=${2:-"http://localhost:$NEXUS_PORT"}; URL=${URL%/}
PUBLIC=${NEXUS_PUBLIC_URL:-"http://$BOOTSTRAP_HOST:$NEXUS_PORT"}
[[ -n "${NEXUS_ADMIN_PASSWORD:-}" ]] || { echo "[ERROR] Set NEXUS_ADMIN_PASSWORD" >&2; exit 1; }
CFG=$(mktemp); trap 'rm -f "$CFG"' EXIT; chmod 600 "$CFG"
printf 'user = "admin:%s"\n' "$NEXUS_ADMIN_PASSWORD" > "$CFG"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -K "$CFG" "$URL/service/rest/v1/status/check")" == 200 ]] || \
  { echo "[ERROR] Nexus $URL: not reachable or wrong admin password" >&2; exit 1; }
code() { curl -s -o /dev/null -w '%{http_code}' -K "$CFG" "$@"; }
put() { # file repository path -> uploaded | exists | error
  if [[ "$(code -I "$URL/repository/$2/$3")" == 200 ]]; then echo exists; return; fi
  [[ "$(code -X PUT --upload-file "$1" "$URL/repository/$2/$3")" =~ ^20[01]$ ]] && echo uploaded || echo error
}
declare -A stat=()
tally() { stat[$1:$2]=$(( ${stat[$1:$2]:-0} + 1 )); }

# Maven (also the Gradle cache converted to Maven layout and the Maven wrapper distribution)
if [[ -d "$DEPS/maven" ]]; then
  while IFS= read -r -d '' f; do
    tally maven "$(put "$f" maven-offline "${f#"$DEPS/maven/"}")"
  done < <(find "$DEPS/maven" -type f ! -name '*.sha1' ! -name '*.md5' ! -name '*.sha256' ! -name '*.sha512' -print0)
fi
# raw files (Gradle distributions)
if [[ -d "$DEPS/files" ]]; then
  while IFS= read -r -d '' f; do
    tally files "$(put "$f" files-offline "${f#"$DEPS/files/"}")"
  done < <(find "$DEPS/files" -type f -print0)
fi
# npm tarballs (components API; an existing version answers 400)
for f in "$DEPS"/npm/*.tgz; do
  [[ -f "$f" ]] || continue
  c=$(code -X POST -F "npm.asset=@$f" "$URL/service/rest/v1/components?repository=npm-offline")
  case "$c" in 204) tally npm uploaded ;; 400) tally npm exists ;; *) tally npm error; echo "[WARN] npm $(basename "$f"): HTTP $c" >&2 ;; esac
done
# Composer: dists, then packages.json merged with the one in Nexus
if [[ -f "$DEPS/composer/packages.json" ]]; then
  while IFS= read -r -d '' f; do
    tally composer "$(put "$f" composer-offline "${f#"$DEPS/composer/"}")"
  done < <(find "$DEPS/composer/dists" -type f -print0)
  current=$(mktemp)
  curl -s -f -K "$CFG" "$URL/repository/composer-offline/packages.json" -o "$current" || echo '{"packages":{}}' > "$current"
  python3 - "$current" "$DEPS/composer/packages.json" "$PUBLIC" <<'PY'
import json, sys
cur_path, new_path, public = sys.argv[1:4]
cur = json.load(open(cur_path))
for name, versions in json.load(open(new_path)).get("packages", {}).items():
    for v, e in versions.items():
        e["dist"]["url"] = e["dist"]["url"].replace("@NEXUS@", public.rstrip("/"))
        cur.setdefault("packages", {}).setdefault(name, {})[v] = e
json.dump(cur, open(cur_path, "w"))
print(f"[OK]   composer packages.json: {len(cur['packages'])} packages")
PY
  [[ "$(code -X PUT --upload-file "$current" "$URL/repository/composer-offline/packages.json")" =~ ^20[01]$ ]] || \
    echo "[WARN] packages.json upload failed" >&2
  rm -f "$current"
fi

for k in "${!stat[@]}"; do echo "  $k ${stat[$k]}"; done | sort
echo "Builds: CICD_NEXUS_URL=\"$PUBLIC\" in cicd-portal-deployment/script/cicd-vars.sh (then 앱 추가 / REPLACE_CI for existing apps)"
[[ -z "$(for k in "${!stat[@]}"; do [[ $k == *:error ]] && echo x; done)" ]] || exit 3
