#!/bin/bash
# Set up the bootstrap VM of the closed network from an offline bundle (docs/install-offline.md, 2).
# Run as root on the bootstrap VM (Rocky Linux 9.7, minimal install), from the copied bundle:
#
#   ./bootstrap-server.sh <bundle-dir>          (re-runnable: a newer bundle adds/updates content)
#
#   - dnf: the bundle's Rocky repositories become this VM's only repositories (podman, skopeo, nginx-free)
#   - BOOTSTRAP_DATA/www   served by an nginx container on BOOTSTRAP_HTTP_PORT:
#       rpms/<repo>/  files/  charts/  Saeoll-PaaS.bundle   (dnf repositories, tools, Helm charts, the scripts)
#   - BOOTSTRAP_DATA/registry served by a registry:2 container on BOOTSTRAP_REGISTRY_PORT (HTTP):
#       every image of images/images.txt under its original name: <host>:5000/docker.io/library/mariadb:11.4
#   - systemd units keep both containers running after a reboot; firewalld ports are opened
# Then: node-setup.sh on every node (dnf repositories, containerd / podman mirrors).
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUNDLE=${1:-}
[[ -n "$BUNDLE" && -f "$BUNDLE/images/images.txt" ]] || { echo "Usage: $0 <bundle-dir>" >&2; exit 2; }
BUNDLE=$(cd "$BUNDLE" && pwd)
# shellcheck source=offline-vars.sh
source "$SCRIPT_DIR/offline-vars.sh"
info() { echo "[INFO] $*"; }
ok() { echo "[OK]   $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }
((EUID == 0)) || die "Run as root."
REG="localhost:$BOOTSTRAP_REGISTRY_PORT"

# 1. local dnf repositories (only the bundle) ----------------------------------------------------------------------
mkdir -p "$BOOTSTRAP_DATA/www"
for d in "$BUNDLE"/rpms/*/; do
  r=$(basename "$d")
  mkdir -p "$BOOTSTRAP_DATA/www/rpms"
  cp -ru "$d" "$BOOTSTRAP_DATA/www/rpms/"
  cat > "/etc/yum.repos.d/offline-$r.repo" <<EOF
[offline-$r]
name=Offline bundle $r
baseurl=file://$BOOTSTRAP_DATA/www/rpms/$r/
enabled=1
gpgcheck=0
EOF
done
for f in /etc/yum.repos.d/*.repo; do
  [[ "$(basename "$f")" == offline-* ]] || sed -i 's/^enabled=1/enabled=0/' "$f"
done
ok "dnf: offline repositories only ($(ls "$BOOTSTRAP_DATA/www/rpms" | tr '\n' ' '))"
dnf install -y -q podman skopeo tar >/dev/null
ok "podman, skopeo installed"

# 2. files, charts, scripts ---------------------------------------------------------------------------------------------
for d in files charts; do
  mkdir -p "$BOOTSTRAP_DATA/www/$d"; cp -ru "$BUNDLE/$d/." "$BOOTSTRAP_DATA/www/$d/"
done
for f in Saeoll-PaaS.bundle offline-vars.sh README.txt; do
  [[ -f "$BUNDLE/$f" ]] && cp -u "$BUNDLE/$f" "$BOOTSTRAP_DATA/www/"
done
if [[ -f "$BUNDLE/files/helm-push-plugin.tar.gz" ]]; then
  mkdir -p "$BOOTSTRAP_DATA/www/files/helm-push" && tar xzf "$BUNDLE/files/helm-push-plugin.tar.gz" -C "$BOOTSTRAP_DATA/www/files"
fi
# the node scripts, so new servers get them with curl before git is installed:
#   curl -fO http://<bootstrap>:8080/offline/node-setup.sh -fO http://<bootstrap>:8080/offline/offline-vars.sh
mkdir -p "$BOOTSTRAP_DATA/www/offline"
cp "$SCRIPT_DIR/node-setup.sh" "$SCRIPT_DIR/offline-vars.sh" "$BOOTSTRAP_DATA/www/offline/"
ok "files, charts, repository bundle, node scripts -> $BOOTSTRAP_DATA/www"

# 3. registry and file server containers ----------------------------------------------------------------------------------
load_local() { # image -> containers-storage from the bundle
  local name; name=$(awk -F'\t' -v i="$1" '$1==i{print $2}' "$BUNDLE/images/images.txt")
  [[ -n "$name" ]] || die "$1 is not in the bundle (EXTRA_IMAGES of offline-vars.sh)"
  podman image exists "$1" || skopeo copy --quiet "oci:$BUNDLE/images/oci:$name" "containers-storage:$1"
}
REGISTRY_IMAGE=$(awk -F'\t' '$1 ~ /^docker.io\/library\/registry:/{print $1; exit}' "$BUNDLE/images/images.txt")
NGINX_IMAGE=$(awk -F'\t' '$1 ~ /^docker.io\/library\/nginx:/{print $1; exit}' "$BUNDLE/images/images.txt")
load_local "$REGISTRY_IMAGE"; load_local "$NGINX_IMAGE"
mkdir -p "$BOOTSTRAP_DATA/registry"
run_service() { # name podman-run-args...
  local name=$1; shift
  if ! podman container exists "$name"; then
    podman run -d --name "$name" --restart=always "$@" >/dev/null
  fi
  (cd /etc/systemd/system && podman generate systemd --new --files --name "$name" >/dev/null 2>&1) && \
    systemctl daemon-reload && systemctl enable "container-$name.service" >/dev/null 2>&1 || true
  ok "$name running"
}
run_service offline-registry -p "$BOOTSTRAP_REGISTRY_PORT:5000" -e REGISTRY_STORAGE_DELETE_ENABLED=true \
  -v "$BOOTSTRAP_DATA/registry:/var/lib/registry:Z" "$REGISTRY_IMAGE"
run_service offline-files -p "$BOOTSTRAP_HTTP_PORT:80" -v "$BOOTSTRAP_DATA/www:/usr/share/nginx/html:ro,Z" "$NGINX_IMAGE"
if systemctl is-active -q firewalld; then
  firewall-cmd -q --permanent --add-port="$BOOTSTRAP_HTTP_PORT/tcp" --add-port="$BOOTSTRAP_REGISTRY_PORT/tcp" && firewall-cmd -q --reload
  ok "firewalld: $BOOTSTRAP_HTTP_PORT/tcp, $BOOTSTRAP_REGISTRY_PORT/tcp open"
fi
for _ in $(seq 1 30); do curl -fs "http://$REG/v2/" >/dev/null && break; sleep 1; done

# 4. images into the registry (original names under <host>:5000/<registry>/...) -----------------------------------------
total=$(wc -l < "$BUNDLE/images/images.txt"); n=0; failed=0
while IFS=$'\t' read -r img name; do
  n=$((n + 1))
  dest=${img%@*}                                  # repo[:tag]
  [[ "${dest##*/}" == *:* ]] || dest="$dest:${img##*@}"; dest=${dest//sha256:/sha256-}
  mode=(); [[ "$img" == *@sha256:* ]] && mode=(--all --preserve-digests)
  if skopeo copy --quiet --dest-tls-verify=false "${mode[@]}" "oci:$BUNDLE/images/oci:$name" "docker://$REG/$dest" 2>/dev/null; then
    echo "[OK]   ($n/$total) $img"
  else
    failed=$((failed + 1)); warn "($n/$total) $img: push failed"
  fi
done < "$BUNDLE/images/images.txt"

echo
echo "Bootstrap VM ready ($((total - failed))/$total images):"
echo "  dnf repositories : http://$BOOTSTRAP_HOST:$BOOTSTRAP_HTTP_PORT/rpms/<repo>/"
echo "  files, charts    : http://$BOOTSTRAP_HOST:$BOOTSTRAP_HTTP_PORT/files/ , /charts/"
echo "  registry (HTTP)  : $BOOTSTRAP_HOST:$BOOTSTRAP_REGISTRY_PORT  (mirror of: $MIRRORED_REGISTRIES)"
echo "Next, on every Kubernetes node and the admin node:"
echo "  BOOTSTRAP_HOST=$BOOTSTRAP_HOST ./node-setup.sh"
((failed == 0)) || exit 3
