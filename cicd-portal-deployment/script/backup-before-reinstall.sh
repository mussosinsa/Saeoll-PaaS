#!/bin/bash
# Back up what the CI/CD portal holds before the servers are wiped and reinstalled (e.g. with a DNS domain
# instead of <ip>.nip.io: docs/install-with-domain.md). Read-only on the cluster.
#
# Usage: ./backup-before-reinstall.sh [backup-dir]        (default: ../backup-<date>, mode 700)
#   inventory/ : vendors (source, namespace layout, CI account, members), applications (type, running tags,
#                autoscaling, stopped) - what to register again in the new CI/CD console
#   repos/     : every SCM-Manager repository as a git mirror (all branches and tags), the 참여자 list of
#                scm.<domain> (permissions.tsv); GitLab vendors: the projects of their groups
#   db/        : SQL dumps of the application databases (dedicated MariaDB per app/env, shared K-PaaS MariaDB)
#   security/  : 품질 관리 policy (gates, profiles, exceptions) and rules
#   images/    : list of the Harbor images; IMAGES=1 also saves the images running in dev/prod as
#                oci-archive files (needs skopeo) - image apps upload them again (컨테이너 이미지 등록)
#   config/    : the variable files of the deployments (contain passwords: keep the backup safe)
# Copy the backup off the servers before they are wiped. Restore: restore-after-reinstall.sh.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
# shellcheck source=lib.sh
source ./lib.sh

OUT=${1:-"$SCRIPT_DIR/../backup-$(date +%Y%m%d-%H%M)"}
load_portal_vars
require_cmds kubectl python3 git
umask 077
mkdir -p "$OUT"/{inventory,repos,db,security,images,config}
OUT=$(cd "$OUT" && pwd)
info "Backup directory: $OUT"
FAILED=()

# 1. inventory --------------------------------------------------------------------------------------------------
kubectl -n "$ARGOCD_NAMESPACE" get appprojects.argoproj.io -o json > "$OUT/inventory/appprojects.json"
kubectl -n "$ARGOCD_NAMESPACE" get applications.argoproj.io -l cicd.k-paas.org/vendor -o json > "$OUT/inventory/applications.json"
kubectl get horizontalpodautoscalers.autoscaling -A -o json > "$OUT/inventory/hpa.json" 2>/dev/null || echo '{"items":[]}' > "$OUT/inventory/hpa.json"
python3 - "$OUT/inventory" <<'PY'
import json, os, sys
d = sys.argv[1]
projects = json.load(open(os.path.join(d, "appprojects.json")))["items"]
apps = json.load(open(os.path.join(d, "applications.json")))["items"]
L = "cicd.k-paas.org"
vendors = []
for p in projects:
    m = p["metadata"]
    if m["name"] == "default":
        continue
    lb, an = m.get("labels") or {}, m.get("annotations") or {}
    vendors.append({"vendor": m["name"], "source": lb.get(f"{L}/source", ""), "ns_mode": lb.get(f"{L}/ns-mode", "split"),
                    "ci_user": an.get(f"{L}/scm-ci-user", ""), "suspended": lb.get(f"{L}/suspended") == "true"})
rows = {}
for a in apps:
    lb = a["metadata"].get("labels") or {}
    key = (lb.get(f"{L}/vendor"), lb.get(f"{L}/app"))
    images = ((a.get("status") or {}).get("summary") or {}).get("images") or []
    e = rows.setdefault(key, {"vendor": key[0], "app": key[1], "type": lb.get(f"{L}/type", ""), "envs": {}})
    e["envs"][lb.get(f"{L}/env", "dev")] = {"images": images, "stopped": lb.get(f"{L}/stopped") == "true",
                                           "namespace": a["spec"]["destination"].get("namespace", "")}
json.dump({"vendors": vendors, "apps": list(rows.values())}, open(os.path.join(d, "inventory.json"), "w"),
          ensure_ascii=False, indent=1)
print(f"[OK]   inventory: {len(vendors)} vendors, {len(rows)} applications")
PY
for v in $(python3 -c 'import json,sys;print(" ".join(x["vendor"] for x in json.load(open(sys.argv[1]))["vendors"]))' "$OUT/inventory/inventory.json"); do
  members=$($API kc-group-members "cicd-$v" 2>/dev/null || true)
  printf '%s\t%s\n' "$v" "$members" >> "$OUT/inventory/members.tsv"
done
ok "Keycloak members of cicd-* groups: inventory/members.tsv"

# 2. repositories -----------------------------------------------------------------------------------------------
if has_source scm; then
  require_scm_admin
  askpass="$OUT/.askpass"
  printf '#!/bin/sh\ncase "$1" in Username*) echo "$SCM_ADMIN_USER";; *) echo "$SCM_ADMIN_PASSWORD";; esac\n' > "$askpass"
  chmod 700 "$askpass"
  for repo in $($API scm-repos); do
    if GIT_ASKPASS=$askpass GIT_TERMINAL_PROMPT=0 GIT_SSL_CAINFO=$CA_FILE \
         git clone -q --mirror "$SCM_GIT_URL/$repo" "$OUT/repos/scm/$repo.git" 2>/dev/null; then
      ok "SCM $repo ($(git -C "$OUT/repos/scm/$repo.git" for-each-ref --format=x refs/heads refs/tags | wc -l) refs)"
    else
      FAILED+=("SCM repository $repo"); warn "SCM $repo: clone failed"
    fi
  done
  rm -f "$askpass"
  DATABASE_USER_PASSWORD="$DATABASE_USER_PASSWORD" $API scm-permissions > "$OUT/repos/permissions.tsv" 2>/dev/null || \
    warn "scm.<domain> 참여자 list not exported (cp_scm)"
fi
if has_source gitlab && [[ -n "$(get_secret automation-token)" ]]; then
  load_gitlab_token
  for v in $(python3 -c 'import json,sys;print(" ".join(x["vendor"] for x in json.load(open(sys.argv[1]))["vendors"] if x["source"]=="gitlab"))' "$OUT/inventory/inventory.json"); do
    for path in $($API gl-get "/groups/$v/projects?per_page=100&include_subgroups=true" | python3 -c 'import json,sys;print(" ".join(p["path_with_namespace"] for p in json.load(sys.stdin) or []))'); do
      mkdir -p "$OUT/repos/gitlab/$(dirname "$path")"
      GIT_SSL_CAINFO=$CA_FILE GIT_TERMINAL_PROMPT=0 \
        git -c credential.helper='!f() { echo username=oauth2; echo "password=$GITLAB_TOKEN"; }; f' \
        clone -q --mirror "$GITLAB_GIT_URL/$path.git" "$OUT/repos/gitlab/$path.git" 2>/dev/null && ok "GitLab $path" || \
        { FAILED+=("GitLab project $path"); warn "GitLab $path: clone failed"; }
    done
  done
fi

# 3. databases --------------------------------------------------------------------------------------------------
dump() { # namespace pod database password-on-stdin file
  kubectl -n "$1" exec -i "$2" -- sh -c 'IFS= read -r MYSQL_PWD; export MYSQL_PWD
    c=$(command -v mariadb-dump || command -v mysqldump)
    "$c" -uroot --single-transaction --routines --triggers --databases "$0"' "$3" | gzip > "$4"
}
while IFS=$'\t' read -r vendor app env ns mode; do
  [[ -n "$app" ]] || continue
  VENDOR=$vendor APP=$app NS_MODE=$mode
  env_names "$env"
  host=$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.DB_HOST}' 2>/dev/null | base64 -d 2>/dev/null || true)
  [[ -n "$host" ]] || continue
  name=$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.DB_NAME}' | base64 -d)
  file="$OUT/db/$vendor-$app-$env.sql.gz"
  if kubectl -n "$NS" get pod "$DB_POD" >/dev/null 2>&1; then
    pw=$(kubectl -n "$NS" get secret "$ROOT_SECRET" -o jsonpath='{.data.password}' | base64 -d)
    printf '%s\n' "$pw" | dump "$NS" "$DB_POD" "$name" "$file" && \
      ok "DB $vendor/$app $env (dedicated $DB_POD/$name)" || { FAILED+=("DB $vendor/$app $env"); warn "DB $vendor/$app $env: dump failed"; }
  elif [[ "$host" == "${PLATFORM_DB_URL%%:*}" ]]; then
    pod=$(kubectl -n mariadb get pods -l app.kubernetes.io/name=mariadb -o name | head -n1); pod=${pod#pod/}
    printf '%s\n' "$DATABASE_USER_PASSWORD" | dump mariadb "${pod:-mariadb-0}" "$name" "$file" && \
      ok "DB $vendor/$app $env (shared $name)" || { FAILED+=("DB $vendor/$app $env"); warn "DB $vendor/$app $env: dump failed"; }
  else
    info "DB $vendor/$app $env: external database $host - back it up where it runs"
  fi
done < <(python3 - "$OUT/inventory/inventory.json" <<'PY'
import json, sys
inv = json.load(open(sys.argv[1]))
modes = {v["vendor"]: v["ns_mode"] for v in inv["vendors"]}
for a in inv["apps"]:
    for env, e in a["envs"].items():
        print("\t".join([a["vendor"], a["app"], env, e["namespace"], modes.get(a["vendor"], "split")]))
PY
)

# 4. security policy --------------------------------------------------------------------------------------------
for ns in "$JENKINS_NAMESPACE" "$RUNNER_NAMESPACE"; do
  if kubectl -n "$ns" get configmap cicd-security-policy -o jsonpath='{.data.policy\.json}' > "$OUT/security/policy.json" 2>/dev/null; then
    kubectl -n "$ns" get configmap cicd-security-rules -o json > "$OUT/security/rules-configmap.json" 2>/dev/null || true
    ok "품질 관리 policy and rules ($ns)"
    break
  fi
done
[[ -s "$OUT/security/policy.json" ]] || rm -f "$OUT/security/policy.json"

# 5. images -----------------------------------------------------------------------------------------------------
python3 - "$OUT/inventory/inventory.json" > "$OUT/images/running.txt" <<'PY'
import json, sys
for a in json.load(open(sys.argv[1]))["apps"]:
    for env, e in sorted(a["envs"].items()):
        for img in e["images"]:
            print(f"{a['vendor']}/{a['app']}\t{env}\t{img}")
PY
ok "Images running in dev/prod: images/running.txt"
if [[ "${IMAGES:-0}" == 1 ]]; then
  require_cmds skopeo
  auth="$OUT/.harbor-auth.json"
  python3 -c 'import base64,json,os,sys;json.dump({"auths":{sys.argv[1]:{"auth":base64.b64encode(f"{os.environ[\"REPOSITORY_USERNAME\"]}:{os.environ[\"REPOSITORY_PASSWORD\"]}".encode()).decode()}}},open(sys.argv[2],"w"))' \
    "$HARBOR_HOST" "$auth"
  while IFS=$'\t' read -r key env image; do
    [[ "$image" == "$HARBOR_HOST/"* ]] || continue
    file="$OUT/images/${key//\//-}-$env.tar"
    ref=${image%@*}
    if skopeo copy --quiet --authfile "$auth" ${CA_FILE:+--src-cert-dir "$(dirname "$CA_FILE")"} \
         "docker://$image" "oci-archive:$file:${ref##*:}" 2>/dev/null; then
      ok "image $image -> images/$(basename "$file")"
    else
      FAILED+=("image $image"); warn "image $image: copy failed"
    fi
  done < "$OUT/images/running.txt"
  rm -f "$auth"
fi

# 6. configuration ----------------------------------------------------------------------------------------------
for f in "$PORTAL_VARS" ./cicd-vars.sh ../../cp-source-control-deployment/script/cp-source-control-vars.sh \
         ../../cp-pipeline-deployment/script/cp-pipeline-vars.sh; do
  [[ -f "$f" ]] && cp "$f" "$OUT/config/" && chmod 600 "$OUT/config/$(basename "$f")"
done
ok "Variable files: config/ (passwords inside - the new installation uses a new domain, review before reuse)"

cat > "$OUT/README.txt" <<EOF
CI/CD portal backup $(date '+%Y-%m-%d %H:%M') from $HOST_DOMAIN
Restore after the reinstallation (docs/install-with-domain.md, 6):
  ./restore-after-reinstall.sh $OUT            (plan: what to register, repositories, databases)
EOF
du -sh "$OUT" | awk '{print "[INFO] Backup size: " $1}'
echo
echo "Backup: $OUT"
echo "Copy it OFF the servers before they are wiped, e.g.: tar czf backup.tgz -C $(dirname "$OUT") $(basename "$OUT")"
if ((${#FAILED[@]})); then
  printf '[WARN] Not saved: %s\n' "${FAILED[@]}"
  exit 3
fi
