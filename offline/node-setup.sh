#!/bin/bash
# Point a server of the closed network to the bootstrap VM (docs/install-offline.md, 3).
# Run as root on EVERY Kubernetes node and on the admin node (after the OS installation, before Kubernetes):
#
#   BOOTSTRAP_HOST=<bootstrap VM> ./node-setup.sh [--ntp <server>] [--kubespray]
#
#   dnf      : /etc/yum.repos.d/offline-<repo>.repo -> http://<bootstrap>:8080/rpms/<repo>/, other repositories off
#   containerd (if present now or later): /etc/containerd/certs.d/<registry>/hosts.toml for every mirrored
#              registry -> http://<bootstrap>:5000/v2/<registry> (override_path), so docker.io/..., quay.io/...,
#              registry.k-paas.org/... images are pulled from the bootstrap registry under their own names
#   podman / buildah / skopeo: /etc/containers/registries.conf.d/50-offline-mirror.conf (same mirrors)
#   --ntp    : chrony uses only this time server
#   --kubespray: print the offline.yml settings for kubespray (yum_repo, files_repo, containerd mirrors)
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=offline-vars.sh
source "$SCRIPT_DIR/offline-vars.sh"
NTP="" KUBESPRAY=0
while (($#)); do
  case "$1" in
    --ntp) NTP=${2:-}; shift ;;
    --kubespray) KUBESPRAY=1 ;;
    *) echo "Usage: BOOTSTRAP_HOST=<host> $0 [--ntp <server>] [--kubespray]" >&2; exit 2 ;;
  esac
  shift
done
ok() { echo "[OK]   $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }
FILES="http://$BOOTSTRAP_HOST:$BOOTSTRAP_HTTP_PORT"
REG="$BOOTSTRAP_HOST:$BOOTSTRAP_REGISTRY_PORT"
upstream() { [[ "$1" == docker.io ]] && echo "https://registry-1.docker.io" || echo "https://$1"; }

if ((KUBESPRAY)); then
  cat <<EOF
# inventory/<cluster>/group_vars/all/offline.yml (kubespray, closed network)
# OS packages: the nodes' dnf repositories (node-setup.sh). Kubernetes files from the bootstrap file server:
files_repo: "$FILES/files/kubespray"
# then copy from inventory/sample/group_vars/all/offline.yml the *_download_url lines that use {{ files_repo }}
# (kubeadm, kubectl, kubelet, cni, crictl, etcd, calico, runc, containerd, nerdctl, ...) and uncomment them.
# Images keep their names (no registry_host / *_image_repo changes): containerd pulls them through these mirrors.
containerd_registries_mirrors:
EOF
  for r in $MIRRORED_REGISTRIES; do
    cat <<EOF
  - prefix: $r
    mirrors:
      - host: http://$REG/v2/$r
        capabilities: ["pull", "resolve"]
        skip_verify: true
        override_path: true
EOF
  done
  exit 0
fi
((EUID == 0)) || die "Run as root."
curl -fs "$FILES/rpms/" -o /dev/null || curl -fs "$FILES/README.txt" -o /dev/null || \
  die "Bootstrap file server $FILES does not answer (BOOTSTRAP_HOST, firewall, bootstrap-server.sh)."
curl -fs "http://$REG/v2/" -o /dev/null || die "Bootstrap registry http://$REG does not answer."

# dnf ---------------------------------------------------------------------------------------------------------------
for r in $RPM_REPOS $RPM_EXTRA_REPOS; do
  cat > "/etc/yum.repos.d/offline-$r.repo" <<EOF
[offline-$r]
name=Offline $r ($BOOTSTRAP_HOST)
baseurl=$FILES/rpms/$r/
enabled=1
gpgcheck=0
EOF
done
for f in /etc/yum.repos.d/*.repo; do
  [[ "$(basename "$f")" == offline-* ]] || sed -i 's/^enabled=1/enabled=0/' "$f"
done
dnf -q makecache >/dev/null && ok "dnf: offline repositories ($RPM_REPOS $RPM_EXTRA_REPOS)"

# containerd ----------------------------------------------------------------------------------------------------------
for r in $MIRRORED_REGISTRIES; do
  mkdir -p "/etc/containerd/certs.d/$r"
  cat > "/etc/containerd/certs.d/$r/hosts.toml" <<EOF
server = "$(upstream "$r")"

[host."http://$REG/v2/$r"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
  override_path = true
EOF
done
mkdir -p "/etc/containerd/certs.d/$REG"
printf 'server = "http://%s"\n\n[host."http://%s"]\n  capabilities = ["pull", "resolve"]\n  skip_verify = true\n' "$REG" "$REG" \
  > "/etc/containerd/certs.d/$REG/hosts.toml"
ok "containerd: mirrors in /etc/containerd/certs.d ($MIRRORED_REGISTRIES)"
if [[ -f /etc/containerd/config.toml ]] && ! grep -q 'config_path *= *"/etc/containerd/certs.d"' /etc/containerd/config.toml; then
  warn "/etc/containerd/config.toml does not set config_path = \"/etc/containerd/certs.d\": add it under"
  warn "[plugins.\"io.containerd.grpc.v1.cri\".registry] and restart containerd (kubespray sets it by default)"
fi

# podman / buildah / skopeo -----------------------------------------------------------------------------------------------
mkdir -p /etc/containers/registries.conf.d
{
  echo "# closed network: images from the bootstrap registry (offline/node-setup.sh)"
  for r in $MIRRORED_REGISTRIES; do
    printf '[[registry]]\nprefix = "%s"\nlocation = "%s"\n[[registry.mirror]]\nlocation = "%s/%s"\ninsecure = true\n\n' "$r" "$r" "$REG" "$r"
  done
  printf '[[registry]]\nlocation = "%s"\ninsecure = true\n' "$REG"
} > /etc/containers/registries.conf.d/50-offline-mirror.conf
ok "podman: mirrors in /etc/containers/registries.conf.d/50-offline-mirror.conf"

# time ------------------------------------------------------------------------------------------------------------------
if [[ -n "$NTP" ]]; then
  sed -i -e 's/^\(pool\|server\) /#&/' /etc/chrony.conf
  grep -q "^server $NTP " /etc/chrony.conf || echo "server $NTP iburst" >> /etc/chrony.conf
  systemctl restart chronyd && ok "chrony: $NTP"
fi

echo
echo "Node ready for the closed network. Check an image through the mirror (after containerd is installed):"
echo "  crictl pull docker.io/library/busybox:1.36"
