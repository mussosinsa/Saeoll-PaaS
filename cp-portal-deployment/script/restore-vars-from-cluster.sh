#!/bin/bash
# Put the values of a running installation back into cp-portal-vars.sh (e.g. after "git checkout/stash" reset it to
# the placeholders). Source: the copy the CI/CD console keeps (secret cicd-console/cicd-console-secrets, key
# cp-portal-vars.sh: domain, StorageClass, Keycloak / Harbor admin accounts, MariaDB password) and the cluster
# (ingress address).
#
# Usage: ./restore-vars-from-cluster.sh [--dry-run]
#   Only these lines are changed (a backup cp-portal-vars.sh.bak.<time> is written first):
#     HOST_DOMAIN INGRESS_LB_IP K8S_STORAGECLASS KEYCLOAK_ADMIN_USERNAME KEYCLOAK_ADMIN_PASSWORD KEYCLOAK_CP_REALM
#     REPOSITORY_USERNAME REPOSITORY_PASSWORD DATABASE_USER_PASSWORD (+ KEYCLOAK_URL / REPOSITORY_URL / DATABASE_URL
#     when they differ from the defaults)
#   Other values (node IPs, cluster names, ...) are not in the cluster copy: compare with an older
#   cp-portal-vars.sh.bak.* or run configure-from-cluster-env.sh for them.
# Secrets are written into the file (as before) and never printed: the output shows "(set)" for passwords.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VARS="$SCRIPT_DIR/cp-portal-vars.sh"
DRY=0; [[ "${1:-}" == --dry-run ]] && DRY=1
if ! command -v kubectl >/dev/null && [[ -x /var/lib/rancher/rke2/bin/kubectl ]]; then
  PATH="$PATH:/var/lib/rancher/rke2/bin"
fi
[[ -f "$VARS" ]] || { echo "[ERROR] $VARS not found" >&2; exit 1; }
NS=${CONSOLE_NAMESPACE:-cicd-console}
src=$(kubectl -n "$NS" get secret cicd-console-secrets -o jsonpath='{.data.cp-portal-vars\.sh}' 2>/dev/null | base64 -d 2>/dev/null || true)
[[ -n "$src" ]] || { echo "[ERROR] secret $NS/cicd-console-secrets (key cp-portal-vars.sh) not found - the CI/CD console keeps the copy" >&2
                     echo "        Use an older backup instead: ls $SCRIPT_DIR/cp-portal-vars.sh.bak.*" >&2; exit 1; }
nginx_ip=$(kubectl -n "${INGRESS_NAMESPACE:-ingress-nginx}" get service "${INGRESS_SERVICE:-ingress-nginx-controller}" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
[[ -n "$nginx_ip" ]] || nginx_ip=$(kubectl -n istio-system get service istio-ingressgateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

# the values go through a private temp file (a heredoc takes python's stdin)
tmp=$(mktemp); chmod 600 "$tmp"; trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$src" > "$tmp"
python3 - "$VARS" "$DRY" "$nginx_ip" "$tmp" <<'PY'
import datetime, re, shlex, shutil, sys
path, dry, ingress_ip, src = sys.argv[1], sys.argv[2] == "1", sys.argv[3], sys.argv[4]
values = {}
for line in open(src, encoding="utf-8").read().splitlines():          # KEY=value lines written with printf %q
    m = re.match(r"^([A-Z0-9_]+)=(.*)$", line)
    if m:
        values[m.group(1)] = " ".join(shlex.split(m.group(2))) if m.group(2) else ""
domain = values.get("HOST_DOMAIN", "")
if not domain or "{" in domain:
    sys.exit("[ERROR] the cluster copy has no HOST_DOMAIN")
defaults = {"KEYCLOAK_URL": f"https://keycloak.{domain}", "REPOSITORY_URL": f"https://harbor.{domain}",
            "DATABASE_URL": "mariadb.mariadb.svc.cluster.local:3306"}
want = {k: values[k] for k in ("HOST_DOMAIN", "K8S_STORAGECLASS", "KEYCLOAK_ADMIN_USERNAME", "KEYCLOAK_ADMIN_PASSWORD",
                               "KEYCLOAK_CP_REALM", "REPOSITORY_USERNAME", "REPOSITORY_PASSWORD",
                               "DATABASE_USER_PASSWORD") if values.get(k)}
for k, default in defaults.items():
    if values.get(k) and values[k] != default:
        want[k] = values[k]
if ingress_ip and not domain.endswith(".nip.io"):
    want["INGRESS_LB_IP"] = ingress_ip
secret = re.compile(r"PASSWORD")
lines = open(path, encoding="utf-8").read().splitlines()
done, out = set(), []
for line in lines:
    m = re.match(r'^([A-Z0-9_]+)=("[^"]*"|\S*)(.*)$', line)
    if m and m.group(1) in want and m.group(1) not in done:
        k, rest = m.group(1), m.group(3)
        quoted = re.sub(r'([\\"$`])', r"\\\1", want[k])            # safe inside "..." in bash
        new = f'{k}="{quoted}"{rest}'
        if new != line:
            shown = "(set)" if secret.search(k) else want[k]
            print(f"  {k} = {shown}")
        line = new
        done.add(k)
    out.append(line)
missing = sorted(set(want) - done)
for k in missing:
    print(f"[WARN] {k} has no line in {path} - not written")
if dry:
    print("[INFO] dry run: nothing written")
    sys.exit(0)
backup = f"{path}.bak.{datetime.datetime.now():%Y%m%d%H%M%S}"
shutil.copy2(path, backup)
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
print(f"[OK]   {path} updated (backup {backup})")
PY
chmod 600 "$VARS" 2>/dev/null || true
if grep -nE '^[A-Z0-9_]+="\{[^$]' "$VARS" >&2; then
  echo "[WARN] the lines above still have placeholders (not in the cluster copy): fill them from an older" >&2
  echo "       cp-portal-vars.sh.bak.* or configure-from-cluster-env.sh - only needed to re-run deploy-cp-portal.sh" >&2
fi
