#!/bin/bash
# Collect the build dependencies of applications for the company Nexus of the closed network
# (docs/install-offline.md, 6). Run where the internet is reachable (the current admin node or an internet PC,
# podman). The real build tools resolve the dependencies in their CI images, so the closed network gets what
# the builds really download.
#
# Usage: ./collect-app-deps.sh <out-dir> <source> [source ...]
#   source : a directory or a git URL (cloned) of an application; also the starters, e.g.
#            ../cicd-portal-deployment/starters/java-gradle
#   out-dir/maven     Maven repository layout (Maven: verify, Gradle: build -> converted from the Gradle cache,
#                     plus the Maven / Gradle wrapper distributions) -> maven-offline
#   out-dir/npm       package tarballs of package-lock.json (generated when missing)  -> npm-offline
#   out-dir/composer  dist zips of composer.lock (generated when missing) + packages.json -> composer-offline
#   out-dir/files     Gradle wrapper distributions (gradle-wrapper.properties)          -> files-offline
# Re-runnable: the output of several runs adds up. GITHUB_TOKEN (optional) avoids the GitHub API limit of
# Composer dist downloads. Images: CICD_DOCKERHUB tools of cicd-vars.sh (MAVEN_IMAGE, GRADLE_IMAGE, ...).
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=${1:-}
[[ -n "$OUT" && $# -ge 2 ]] || { echo "Usage: $0 <out-dir> <source-dir|git-url> ..." >&2; exit 2; }
shift
mkdir -p "$OUT"/{maven,npm,composer/dists,files}
OUT=$(cd "$OUT" && pwd)
DH=${CICD_DOCKERHUB:-docker.io/library}
MAVEN_IMAGE=${MAVEN_IMAGE:-$DH/maven:3.9-eclipse-temurin-17}
GRADLE_IMAGE=${GRADLE_IMAGE:-$DH/gradle:8.10-jdk17}
NODE_IMAGE=${NODE_IMAGE:-$DH/node:20-alpine}
COMPOSER_IMAGE=${COMPOSER_IMAGE:-$DH/composer:2}
command -v podman >/dev/null || { echo "[ERROR] podman is not installed" >&2; exit 1; }
ok() { echo "[OK]   $*"; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
WORK=$(mktemp -d)
trap 'podman unshare rm -rf "$WORK" 2>/dev/null || rm -rf "$WORK"' EXIT
FAILED=()
run() { # image workdir command  (the work copy at /src, caches under $WORK)
  podman run --rm -v "$2:/src:Z" -v "$WORK/cache:/cache:Z" -w /src --user 0 "$1" sh -c "$3"
}
mkdir -p "$WORK/cache"

n=0
for source in "$@"; do
  n=$((n + 1))
  src="$WORK/src$n"
  if [[ -d "$source" ]]; then
    cp -a "$source" "$src"
  else
    git clone -q --depth 1 "$source" "$src" || { FAILED+=("$source (clone)"); continue; }
  fi
  rm -rf "$src/.git"
  name=$(basename "$source" .git)
  info "$name"

  # Maven (+ Maven wrapper distribution)
  if [[ -f "$src/pom.xml" ]]; then
    if run "$MAVEN_IMAGE" "$src" 'M=mvn; [ -x ./mvnw ] && M=./mvnw
          $M -B -q -Dmaven.repo.local=/cache/m2 dependency:go-offline &&
          $M -B -q -Dmaven.repo.local=/cache/m2 -Dmaven.test.failure.ignore=true verify'; then
      ok "$name: Maven dependencies"
    else
      FAILED+=("$name (maven)"); warn "$name: Maven build failed - its dependencies may be incomplete"
    fi
  fi
  # Gradle (+ Gradle wrapper distribution)
  if [[ -f "$src/build.gradle" || -f "$src/build.gradle.kts" ]]; then
    if run "$GRADLE_IMAGE" "$src" 'G=gradle; [ -x ./gradlew ] && G=./gradlew
          $G --no-daemon -q -g /cache/gradle build --continue -x test && $G --no-daemon -q -g /cache/gradle test --continue || true'; then
      ok "$name: Gradle dependencies"
    else
      FAILED+=("$name (gradle)")
    fi
  fi
  # npm: lock file (generated when missing) -> tarballs
  if [[ -f "$src/package.json" ]]; then
    if [[ -f "$src/package-lock.json" ]] || run "$NODE_IMAGE" "$src" 'npm install --package-lock-only --ignore-scripts --no-audit --no-fund >/dev/null'; then
      cp "$src/package-lock.json" "$WORK/npm-lock-$n.json"
      ok "$name: npm lock file"
    else
      FAILED+=("$name (npm)")
    fi
  fi
  # Composer: lock file (generated when missing)
  if [[ -f "$src/composer.json" ]]; then
    if [[ -f "$src/composer.lock" ]] || run "$COMPOSER_IMAGE" "$src" 'composer update --no-install --no-scripts --no-interaction --ignore-platform-reqs -q'; then
      cp "$src/composer.lock" "$WORK/composer-lock-$n.json"
      ok "$name: composer lock file"
    else
      FAILED+=("$name (composer)")
    fi
  fi
  # wrapper distributions
  for props in "$src/.mvn/wrapper/maven-wrapper.properties" "$src/gradle/wrapper/gradle-wrapper.properties"; do
    [[ -f "$props" ]] && grep -E '^(distributionUrl|wrapperUrl)=' "$props" | cut -d= -f2- | sed 's/\\:/:/g' >> "$WORK/wrapper-urls"
  done
done

# Files: Maven repository, npm tarballs, composer dists, wrapper distributions (Python: no tool needed)
podman unshare chown -R 0:0 "$WORK/cache" 2>/dev/null || true
python3 - "$WORK" "$OUT" "${GITHUB_TOKEN:-}" <<'PY'
import glob, hashlib, json, os, re, shutil, sys, urllib.request
work, out, token = sys.argv[1:4]
count = {"maven": 0, "npm": 0, "composer": 0, "files": 0}

def fetch(url, dest, headers=None):
    if os.path.exists(dest):
        return False
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    req = urllib.request.Request(url, headers=headers or {"User-Agent": "cicd-offline"})
    with urllib.request.urlopen(req, timeout=120) as r, open(dest + ".part", "wb") as fh:
        shutil.copyfileobj(r, fh)
    os.replace(dest + ".part", dest)
    return True

# Maven repository (Maven runs): copy without the local-only files
m2 = os.path.join(work, "cache", "m2")
for root, _, files in os.walk(m2):
    for f in files:
        if f in ("_remote.repositories", "resolver-status.properties") or f.endswith((".lastUpdated", ".part")) \
                or f.startswith("maven-metadata-"):
            continue
        rel = os.path.relpath(os.path.join(root, f), m2)
        dest = os.path.join(out, "maven", rel)
        if not os.path.exists(dest):
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.copy2(os.path.join(root, f), dest)
            count["maven"] += 1

# Gradle cache files-2.1/<group>/<module>/<version>/<sha1>/<file> -> Maven layout
g = os.path.join(work, "cache", "gradle", "caches", "modules-2", "files-2.1")
for path in glob.glob(os.path.join(g, "*", "*", "*", "*", "*")):
    group, module, version, _, f = path[len(g) + 1:].split(os.sep)
    dest = os.path.join(out, "maven", *group.split("."), module, version, f)
    if not os.path.exists(dest):
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copy2(path, dest)
        count["maven"] += 1

# Wrapper distributions: Maven (repository path) -> maven/, Gradle -> files/gradle/
if os.path.exists(os.path.join(work, "wrapper-urls")):
    for url in sorted(set(open(os.path.join(work, "wrapper-urls")).read().split())):
        m = re.search(r"/maven2/(.+)$", url)
        dest = os.path.join(out, "maven", m.group(1)) if m else os.path.join(out, "files", "gradle", url.rsplit("/", 1)[1])
        try:
            if fetch(url, dest):
                count["maven" if m else "files"] += 1
        except Exception as e:
            print(f"[WARN] {url}: {e}", file=sys.stderr)

# npm: every "resolved" tarball of the lock files
for lock in glob.glob(os.path.join(work, "npm-lock-*.json")):
    data = json.load(open(lock))
    entries = list((data.get("packages") or {}).values()) or list((data.get("dependencies") or {}).values())
    for e in entries:
        url = e.get("resolved", "")
        if not url.startswith("http"):
            continue
        name = url.split("/-/")[0].split("/")[-2:]       # [@scope, name] or [registry, name]
        fname = (name[0] + "-" if name[0].startswith("@") else "") + url.rsplit("/", 1)[1]
        try:
            if fetch(url, os.path.join(out, "npm", fname)):
                count["npm"] += 1
        except Exception as ex:
            print(f"[WARN] npm {url}: {ex}", file=sys.stderr)

# Composer: dist zips + packages.json (dist url @NEXUS@ is set by nexus-load.sh)
pj_path = os.path.join(out, "composer", "packages.json")
pj = json.load(open(pj_path)) if os.path.exists(pj_path) else {"packages": {}}
for lock in glob.glob(os.path.join(work, "composer-lock-*.json")):
    data = json.load(open(lock))
    for p in (data.get("packages") or []) + (data.get("packages-dev") or []):
        dist = p.get("dist") or {}
        if not dist.get("url"):
            continue
        rel = f"dists/{p['name']}/{p['version']}.zip"
        headers = {"User-Agent": "cicd-offline"}
        if token and "github.com" in dist["url"]:
            headers["Authorization"] = f"token {token}"
        try:
            if fetch(dist["url"], os.path.join(out, "composer", rel), headers):
                count["composer"] += 1
        except Exception as ex:
            print(f"[WARN] composer {p['name']} {p['version']}: {ex}", file=sys.stderr)
            continue
        entry = {k: v for k, v in p.items() if k not in ("source", "notification-url", "installation-source")}
        entry["dist"] = {"type": "zip", "url": "@NEXUS@/repository/composer-offline/" + rel}
        pj["packages"].setdefault(p["name"], {})[p["version"]] = entry
json.dump(pj, open(pj_path, "w"), indent=1)
print("[OK]   files: " + ", ".join(f"{k} +{v}" for k, v in count.items()))
PY

du -sh "$OUT" | awk '{print "[INFO] application dependencies: " $1}'
if ((${#FAILED[@]})); then
  printf '[WARN] incomplete: %s\n' "${FAILED[@]}"
  exit 3
fi
