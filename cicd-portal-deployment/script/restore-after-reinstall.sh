#!/bin/bash
# Restore a backup of backup-before-reinstall.sh into the newly installed CI/CD portal (new domain).
#
# Usage: ./restore-after-reinstall.sh <backup-dir> [--repos] [--db] [--security] [--vendor <vendor>]
#   (no step option)  plan: the vendors and applications to register again in the CI/CD console and what
#                     each step would restore - nothing is changed
#   --repos     SCM: every backed-up repository except <vendor>-gitops (the new onboarding creates a new one
#               with the new domain) is created in the new SCM (참여자: CI account 보기, members of
#               cicd-<vendor> 쓰기) and pushed with all branches and tags. Run after 업체 등록, before 앱 추가.
#               A repository that already has commits is skipped (FORCE=1 pushes anyway).
#               GitLab vendors: the projects are pushed into the new GitLab (the groups must exist).
#   --db        the SQL dumps into the application databases. Run after 앱 추가 + DB 연결 (same mode as before).
#   --security  the 품질 관리 policy (gates, profiles, exceptions) into the new CI namespaces
# Order: docs/install-with-domain.md, 6.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
# shellcheck source=lib.sh
source ./lib.sh

BACKUP=${1:-}
[[ -n "$BACKUP" && -f "$BACKUP/inventory/inventory.json" ]] || {
  echo "Usage: $0 <backup-dir> [--repos] [--db] [--security] [--vendor <vendor>]" >&2; exit 2; }
BACKUP=$(cd "$BACKUP" && pwd)
shift
DO_REPOS=0 DO_DB=0 DO_SEC=0 ONLY=""
while (($#)); do
  case "$1" in
    --repos) DO_REPOS=1 ;;
    --db) DO_DB=1 ;;
    --security) DO_SEC=1 ;;
    --vendor) ONLY=${2:-}; shift ;;
    *) echo "Unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
load_portal_vars
require_cmds kubectl python3 git
INV="$BACKUP/inventory/inventory.json"
vendors() { python3 -c 'import json,sys;[print(v["vendor"],v["source"],v["ns_mode"]) for v in json.load(open(sys.argv[1]))["vendors"] if not sys.argv[2] or v["vendor"]==sys.argv[2]]' "$INV" "$ONLY"; }
FAILED=()

# Plan -------------------------------------------------------------------------------------------------------------
if ((!DO_REPOS && !DO_DB && !DO_SEC)); then
  echo "Backup of $(head -n1 "$BACKUP/README.txt" | sed 's/.* from //') -> new domain $HOST_DOMAIN"
  echo
  echo "1. CI/CD console > 업체 등록 (same ID, source and namespace layout; members from the backup):"
  while read -r v src mode; do
    members=$(awk -F'\t' -v v="$v" '$1==v{print $2}' "$BACKUP/inventory/members.tsv" 2>/dev/null)
    echo "   - $v  (source $src, namespace $mode)  members: ${members:-none}"
  done < <(vendors)
  echo "2. $0 $BACKUP --repos"
  ls "$BACKUP/repos/scm" 2>/dev/null | sed -e 's/\.git$//' -e 's/^/   - SCM /' | grep -v -- '-gitops$' || true
  echo "3. CI/CD console > 앱 추가 for each application, with '시작 소스를 넣지 않음' (the restored source has its"
  echo "   Dockerfile and Jenkinsfile) and the same DB 연결 mode; image apps: type image. A repository not named"
  echo "   <vendor>-<app> (e.g. saeoll for saeoll/php-service): enter it in '기존 SCM 저장소 이름'."
  python3 - "$INV" "$ONLY" <<'PY'
import json, sys
inv, only = json.load(open(sys.argv[1])), sys.argv[2]
for a in inv["apps"]:
    if only and a["vendor"] != only:
        continue
    envs = ", ".join(f"{e}{' (중지)' if x['stopped'] else ''}" for e, x in sorted(a["envs"].items()))
    print(f"   - {a['vendor']}/{a['app']}  type {a['type']}  [{envs}]")
PY
  echo "4. $0 $BACKUP --db"
  ls "$BACKUP/db" 2>/dev/null | sed 's/^/   - /' || true
  echo "5. Build: develop -> dev automatically; prod: 릴리스 with the last tag (images/running.txt shows the tags)."
  echo "   Image apps: 컨테이너 이미지 등록 with images/*.tar (when backed up with IMAGES=1)."
  [[ -f "$BACKUP/security/policy.json" ]] && echo "6. $0 $BACKUP --security   (품질 관리 gates, profiles, exceptions)"
  echo
  echo "Nothing changed (plan only)."
  exit 0
fi

# Repositories -----------------------------------------------------------------------------------------------------
if ((DO_REPOS)); then
  if [[ -d "$BACKUP/repos/scm" ]]; then
    require_scm_admin
    askpass=$(mktemp)
    printf '#!/bin/sh\ncase "$1" in Username*) echo "$SCM_ADMIN_USER";; *) echo "$SCM_ADMIN_PASSWORD";; esac\n' > "$askpass"
    chmod 700 "$askpass"
    for dir in "$BACKUP"/repos/scm/*.git; do
      repo=$(basename "$dir" .git)
      [[ "$repo" == *-gitops ]] && { info "SCM $repo: skipped (gitops is recreated by 업체 등록)"; continue; }
      vendor=""
      while read -r v _ _; do [[ "$repo" == "$v-"* || "$repo" == "$v" ]] && vendor=$v; done < <(vendors)
      [[ -n "$ONLY" && -z "$vendor" ]] && continue
      ci=$([[ -n "$vendor" ]] && vendor_ci_user "$vendor" || true)
      DATABASE_USER_PASSWORD="$DATABASE_USER_PASSWORD" $API scm-app-repo "$repo" --description "restored ($(date +%F))" \
        --ci-user "$ci" ${vendor:+--writers-group "cicd-$vendor"} >/dev/null || { FAILED+=("SCM $repo (create)"); continue; }
      target="$SCM_GIT_URL/$repo"
      if [[ "${FORCE:-0}" != 1 ]] && GIT_ASKPASS=$askpass GIT_TERMINAL_PROMPT=0 GIT_SSL_CAINFO=$CA_FILE \
           git ls-remote --heads "$target" 2>/dev/null | grep -q .; then
        info "SCM $repo: already has branches - skipped (FORCE=1 pushes anyway)"
        continue
      fi
      if GIT_ASKPASS=$askpass GIT_TERMINAL_PROMPT=0 GIT_SSL_CAINFO=$CA_FILE \
           git -C "$dir" push -q --mirror "$target" 2>/dev/null; then
        ok "SCM $repo restored ($(git -C "$dir" for-each-ref --format=x refs/heads refs/tags | wc -l) branches/tags)"
      else
        FAILED+=("SCM $repo (push)"); warn "SCM $repo: push failed"
      fi
    done
    rm -f "$askpass"
  fi
  if [[ -d "$BACKUP/repos/gitlab" ]]; then
    load_gitlab_token
    while IFS= read -r dir; do
      path=${dir#"$BACKUP/repos/gitlab/"}; path=${path%.git}
      [[ "$path" == */gitops ]] && continue
      [[ -n "$ONLY" && "$path" != "$ONLY/"* ]] && continue
      $API gl-project "$(dirname "$path")" "$(basename "$path")" --visibility private --empty >/dev/null || { FAILED+=("GitLab $path"); continue; }
      GIT_SSL_CAINFO=$CA_FILE GIT_TERMINAL_PROMPT=0 \
        git -C "$dir" -c credential.helper='!f() { echo username=oauth2; echo "password=$GITLAB_TOKEN"; }; f' \
        push -q --mirror "$GITLAB_GIT_URL/$path.git" 2>/dev/null && ok "GitLab $path restored" || \
        { FAILED+=("GitLab $path (push)"); warn "GitLab $path: push failed"; }
    done < <(find "$BACKUP/repos/gitlab" -type d -name '*.git' -prune)
  fi
fi

# Databases ----------------------------------------------------------------------------------------------------------
if ((DO_DB)); then
  restore_sql() { # namespace pod (password on stdin, first line) < dump
    kubectl -n "$1" exec -i "$2" -- sh -c 'IFS= read -r MYSQL_PWD; export MYSQL_PWD
      c=$(command -v mariadb || command -v mysql); "$c" -uroot'
  }
  while read -r v _ mode; do
    for file in "$BACKUP"/db/"$v"-*.sql.gz; do
      [[ -f "$file" ]] || continue
      base=$(basename "$file" .sql.gz); env=${base##*-}; app=${base#"$v-"}; app=${app%-"$env"}
      # a dump of another vendor whose name starts with "$v-" (e.g. soft and soft-x)
      python3 -c 'import json,sys;sys.exit(0 if any(a["vendor"]==sys.argv[2] and a["app"]==sys.argv[3] for a in json.load(open(sys.argv[1]))["apps"]) else 1)' \
        "$INV" "$v" "$app" || continue
      VENDOR=$v APP=$app NS_MODE=$(vendor_ns_mode "$v")
      env_names "$env"
      host=$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.DB_HOST}' 2>/dev/null | base64 -d 2>/dev/null || true)
      if [[ -z "$host" ]]; then
        warn "DB $v/$app $env: not connected yet (CI/CD console > $v/$app > DB 연결) - skipped"; FAILED+=("DB $v/$app $env"); continue
      fi
      if kubectl -n "$NS" get pod "$DB_POD" >/dev/null 2>&1; then
        pw=$(kubectl -n "$NS" get secret "$ROOT_SECRET" -o jsonpath='{.data.password}' | base64 -d)
        { printf '%s\n' "$pw"; gunzip -c "$file"; } | restore_sql "$NS" "$DB_POD" && ok "DB $v/$app $env restored (dedicated)" || \
          { FAILED+=("DB $v/$app $env"); warn "DB $v/$app $env: restore failed"; }
      elif [[ "$host" == "${PLATFORM_DB_URL%%:*}" ]]; then
        pod=$(kubectl -n mariadb get pods -l app.kubernetes.io/name=mariadb -o name | head -n1); pod=${pod#pod/}
        { printf '%s\n' "$DATABASE_USER_PASSWORD"; gunzip -c "$file"; } | restore_sql mariadb "${pod:-mariadb-0}" && \
          ok "DB $v/$app $env restored (shared)" || { FAILED+=("DB $v/$app $env"); warn "DB $v/$app $env: restore failed"; }
      else
        warn "DB $v/$app $env: external database $host - restore it there"
      fi
    done
  done < <(vendors)
fi

# 품질 관리 -----------------------------------------------------------------------------------------------------------
if ((DO_SEC)) && [[ -f "$BACKUP/security/policy.json" ]]; then
  done_ns=0
  for ns in "$JENKINS_NAMESPACE" "$RUNNER_NAMESPACE"; do
    kubectl -n "$ns" get configmap cicd-security-policy >/dev/null 2>&1 || continue
    kubectl -n "$ns" create configmap cicd-security-policy --from-file=policy.json="$BACKUP/security/policy.json" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    ok "품질 관리 policy restored in $ns"
    done_ns=1
  done
  ((done_ns)) || { warn "Security scan is not installed yet (./deploy-cicd-portal.sh security)"; FAILED+=("security policy"); }
fi

echo
if ((${#FAILED[@]})); then
  printf '[TODO] %s\n' "${FAILED[@]}"
  exit 3
fi
echo "Restore steps done."
