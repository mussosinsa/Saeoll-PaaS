#!/bin/bash
# Download and extract the K-PaaS source control deployment package
# (cp-source-control-deployment-<version>.tar.gz) into ../upstream.
#
#   ./fetch-cp-source-control.sh                 # download from nextcloud.k-paas.org
#   ./fetch-cp-source-control.sh /path/pkg.tar.gz  # offline: use a copied tarball
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR/.." || exit 1

SC_DOWNLOAD_URL=${SC_DOWNLOAD_URL:-"https://nextcloud.k-paas.org/index.php/s/dkfdTd6zttpi3T2/download"}
SC_TARBALL=${1:-}

if [[ -z "$SC_TARBALL" ]]; then
  SC_TARBALL=$(ls -t cp-source-control-deployment-*.tar.gz 2>/dev/null | head -1)
fi
if [[ -z "$SC_TARBALL" ]]; then
  command -v wget >/dev/null || { echo "[ERROR] wget is not installed (dnf install -y wget)." >&2; exit 1; }
  echo "[INFO] Downloading $SC_DOWNLOAD_URL"
  wget --content-disposition "$SC_DOWNLOAD_URL" || {
    echo "[ERROR] Download failed. Copy the tarball here and pass its path as an argument." >&2; exit 1; }
  SC_TARBALL=$(ls -t cp-source-control-deployment-*.tar.gz 2>/dev/null | head -1)
fi
[[ -r "$SC_TARBALL" ]] || { echo "[ERROR] Tarball not found: ${SC_TARBALL:-cp-source-control-deployment-*.tar.gz}" >&2; exit 1; }
ls -lh "$SC_TARBALL"

# Extract into a scratch directory, then move the package root to ../upstream
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
tar -xvf "$SC_TARBALL" -C "$WORK" || { echo "[ERROR] Failed to extract $SC_TARBALL" >&2; exit 1; }
DEPLOY_SH=$(find "$WORK" -path '*/script/deploy-cp-source-control.sh' | head -1)
[[ -n "$DEPLOY_SH" ]] || {
  echo "[ERROR] script/deploy-cp-source-control.sh not found in $SC_TARBALL" >&2; exit 1; }
PKG_ROOT=$(dirname "$(dirname "$DEPLOY_SH")")

rm -rf upstream
mv "$PKG_ROOT" upstream
chmod +x upstream/script/*.sh
echo "[INFO] Extracted to $(pwd)/upstream"
ls upstream upstream/script
