#!/bin/bash
# Roles in the vendor namespaces for the CP-Portal user screen (사용자 > Namespaces / Roles).
#
# CP-Portal lists the Roles that exist in each namespace; a namespace without a Role (created by the CI/CD
# portal, not by CP-Portal) cannot be selected there. This copies the Roles of a namespace that CP-Portal
# created (same names and rules as CP-Portal uses) into the vendor's namespaces. Re-runnable.
#
# Usage: ./portal-roles.sh [--dry-run] <vendor>
#   template namespace: PORTAL_ROLE_TEMPLATE_NS=<namespace created in CP-Portal>, else found automatically:
#     the namespace (not a system / CI-CD portal / vendor one) holding most of PORTAL_ROLES
#   PORTAL_ROLES (cicd-vars.sh, default "cp-init-role cp-admin-role"): the Role names CP-Portal creates
#   No template found: a read-only Role cicd-vendor-view is created instead (and the Roles seen in several
#   namespaces are listed, to set PORTAL_ROLES).
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
# shellcheck source=lib.sh
source ./lib.sh

DRY=0
[[ "${1:-}" == --dry-run ]] && { DRY=1; shift; }
VENDOR=${1:-}
[[ "$VENDOR" =~ ^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$ ]] || { echo "Usage: $0 [--dry-run] <vendor>" >&2; exit 2; }
load_portal_vars
require_cmds kubectl python3
mapfile -t NAMESPACES < <(kubectl get namespaces -l "cp.k-paas.org/vendor=$VENDOR" -o name | sed 's|.*/||')
((${#NAMESPACES[@]})) || die "No namespace labelled cp.k-paas.org/vendor=$VENDOR (onboard-vendor.sh first)."

kubectl get roles -A -o json > "${TMPDIR:-/tmp}/portal-roles.$$.json"
trap 'rm -f "${TMPDIR:-/tmp}/portal-roles.$$.json"' EXIT
python3 - "${TMPDIR:-/tmp}/portal-roles.$$.json" "$VENDOR" "${PORTAL_ROLES:-cp-init-role cp-admin-role}" \
  "${PORTAL_ROLE_TEMPLATE_NS:-}" "$DRY" "${NAMESPACES[@]}" <<'PY' | { if [[ "$DRY" == 1 ]]; then cat; else kubectl apply -f -; fi; }
import collections, json, re, sys
path, vendor, wanted, template_ns, dry, *targets = sys.argv[1:]
wanted = wanted.split()
roles = json.load(open(path))["items"]
SYSTEM = re.compile(r"^(kube-|cicd-|cp-|default$|harbor|keycloak|mariadb|openbao|chartmuseum|chaos|istio|ingress|metallb|"
                    r"calico|tigera|cattle|longhorn|nfs|local-path|kyverno)")
by_ns = collections.defaultdict(list)
for r in roles:
    by_ns[r["metadata"]["namespace"]].append(r)
vendor_ns = set(targets)

def log(msg):
    print(msg, file=sys.stderr)

if template_ns:
    template = [r for r in by_ns.get(template_ns, []) if not wanted or r["metadata"]["name"] in wanted] or by_ns.get(template_ns, [])
    if not template:
        sys.exit(f"[ERROR] no Role in PORTAL_ROLE_TEMPLATE_NS={template_ns}")
else:
    best, template = None, []
    for ns, items in by_ns.items():
        if ns in vendor_ns or SYSTEM.match(ns):
            continue
        hit = [r for r in items if r["metadata"]["name"] in wanted]
        if len(hit) > len(template):
            best, template = ns, hit
    template_ns = best or ""

docs = []
if template:
    log(f"[INFO] Roles of CP-Portal namespace {template_ns}: {', '.join(r['metadata']['name'] for r in template)}")
    for ns in targets:
        for r in template:
            docs.append({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "Role",
                         "metadata": {"name": r["metadata"]["name"], "namespace": ns,
                                      "labels": {**{k: v for k, v in (r["metadata"].get("labels") or {}).items()
                                                    if not k.startswith("kubernetes.io/")},
                                                 "app.kubernetes.io/managed-by": "cicd-portal"}},
                         "rules": r.get("rules") or []})
else:
    seen = collections.Counter(r["metadata"]["name"] for ns, items in by_ns.items()
                               if not SYSTEM.match(ns) and ns not in vendor_ns for r in items)
    common = [n for n, c in seen.most_common(10) if c >= 2]
    log(f"[WARN] no namespace with the CP-Portal Roles {' '.join(wanted)} found"
        + (f" - Roles seen in several namespaces: {', '.join(common)} (set PORTAL_ROLES)" if common else
           " - create one namespace in CP-Portal (Clusters > Namespaces > 생성) and run this again"))
    log("[INFO] creating the read-only Role cicd-vendor-view so the namespaces can be selected in CP-Portal")
    read = ["get", "list", "watch"]
    for ns in targets:
        docs.append({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "Role",
                     "metadata": {"name": "cicd-vendor-view", "namespace": ns,
                                  "labels": {"app.kubernetes.io/managed-by": "cicd-portal"}},
                     "rules": [{"apiGroups": [""], "resources": ["pods", "pods/log", "services", "endpoints",
                                "configmaps", "persistentvolumeclaims", "events", "resourcequotas", "limitranges"],
                                "verbs": read},
                               {"apiGroups": ["apps"], "resources": ["deployments", "replicasets", "statefulsets",
                                "daemonsets"], "verbs": read},
                               {"apiGroups": ["batch"], "resources": ["jobs", "cronjobs"], "verbs": read},
                               {"apiGroups": ["networking.k8s.io"], "resources": ["ingresses"], "verbs": read},
                               {"apiGroups": ["autoscaling"], "resources": ["horizontalpodautoscalers"], "verbs": read}]})
print(json.dumps({"apiVersion": "v1", "kind": "List", "items": docs}, indent=1 if dry == "1" else None))
PY
if [[ "$DRY" == 1 ]]; then
  echo "[INFO] dry run: nothing applied"
else
  ok "Roles in ${NAMESPACES[*]}: the namespaces can now be selected in CP-Portal (사용자 > Namespaces / Roles)"
fi
