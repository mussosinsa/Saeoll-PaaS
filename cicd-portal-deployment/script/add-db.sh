#!/bin/bash
# Connect an application to a MariaDB database.
#   - Kubernetes Secret <app>-db in <vendor>-<env>: DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD
#   - gitops: the Deployment reads the Secret (envFrom); dedicated mode also adds the MariaDB itself
# Passwords are generated here, stored only in Secrets and never printed or committed to Git.
#
# Usage: ./add-db.sh <vendor> <app> [dev|prod|all] [dedicated|shared|external]
#   env (default dev) : prod is applied to gitops too, but deployed only by the Argo CD prod sync (cicd-admins)
#   mode (default dedicated):
#     dedicated : MariaDB StatefulSet <app>-mariadb in <vendor>-<env> (gitops, volume DB_SIZE=2Gi,
#                 StorageClass DB_STORAGECLASS / K8S_STORAGECLASS / cluster default)
#     shared    : database + user <vendor>_<app>_<env> on the K-PaaS MariaDB (namespace mariadb);
#                 quick tests only, the platform databases share that server
#     external  : an existing database: env DB_HOST DB_NAME DB_USER DB_PASSWORD [DB_PORT=3306]
# An existing Secret is kept (re-runnable). DB_SECRET_UPDATE=1 replaces it (shared: new password,
# external: new values); a dedicated MariaDB keeps the password it was initialised with.
# The app must read DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASSWORD (see ../samples/php-board).
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
# shellcheck source=lib.sh
source ./lib.sh

VENDOR=${1:-}
APP=${2:-}
ENV_ARG=${3:-dev}
MODE=${4:-dedicated}
NAME_RE='^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$'
if [[ ! "$VENDOR" =~ $NAME_RE || ! "$APP" =~ $NAME_RE || ! "$ENV_ARG" =~ ^(dev|prod|all)$ \
      || ! "$MODE" =~ ^(dedicated|shared|external)$ ]]; then
  echo "Usage: $0 <vendor> <app> [dev|prod|all] [dedicated|shared|external]" >&2
  exit 2
fi
[[ "$ENV_ARG" == all ]] && ENVS=(dev prod) || ENVS=("$ENV_ARG")
load_portal_vars
require_cmds kubectl python3 git
SOURCE=$(vendor_source "$VENDOR")
[[ -n "$SOURCE" ]] || die "Vendor $VENDOR is not onboarded."
kubectl -n "$ARGOCD_NAMESPACE" get applications.argoproj.io "$VENDOR-$APP-dev" >/dev/null 2>&1 || \
  die "Application $VENDOR/$APP not found. Run ./add-app.sh $VENDOR $APP <type> first."
if [[ "$MODE" == external ]]; then
  for v in DB_HOST DB_NAME DB_USER DB_PASSWORD; do
    [[ -n "${!v:-}" ]] || die "external mode needs env DB_HOST DB_NAME DB_USER DB_PASSWORD (missing $v)"
  done
fi
NS_MODE=$(vendor_ns_mode "$VENDOR")
# Names per environment. Single namespace layout (dev and prod share <vendor>): the names carry the env,
# and kustomize's -<env> suffix makes the dedicated MariaDB <app>-mariadb-<env>.
env_names() { # env -> NS SECRET ROOT_SECRET DB_SERVICE DB_POD
  NS=$(env_namespace "$VENDOR" "$1" "$NS_MODE")
  if [[ "$NS_MODE" == single ]]; then
    SECRET="$APP-$1-db" ROOT_SECRET="$APP-$1-mariadb-root" DB_SERVICE="$APP-mariadb-$1"
  else
    SECRET="$APP-db" ROOT_SECRET="$APP-mariadb-root" DB_SERVICE="$APP-mariadb"
  fi
  DB_POD="$DB_SERVICE-0"
}
# Volume of a dedicated MariaDB: DB_STORAGECLASS, else K8S_STORAGECLASS if it exists, else the cluster default
if [[ "$MODE" == dedicated ]]; then
  DB_STORAGECLASS=${DB_STORAGECLASS:-$K8S_STORAGECLASS}
  if [[ -n "$DB_STORAGECLASS" ]] && ! kubectl get storageclass "$DB_STORAGECLASS" >/dev/null 2>&1; then
    warn "StorageClass $DB_STORAGECLASS not found - the MariaDB volume uses the cluster default StorageClass"
    DB_STORAGECLASS=""
  fi
fi

# Secret from environment variables (values never on a command line)
apply_db_secret() { # namespace name  (values in env S_HOST S_PORT S_NAME S_USER S_PASSWORD)
  python3 - "$1" "$2" "$APP" <<'PY' | kubectl apply -f - >/dev/null
import base64, json, os, sys
ns, name, app = sys.argv[1:]
keys = {"DB_HOST": "S_HOST", "DB_PORT": "S_PORT", "DB_NAME": "S_NAME", "DB_USER": "S_USER", "DB_PASSWORD": "S_PASSWORD"}
data = {k: base64.b64encode(os.environ[v].encode()).decode() for k, v in keys.items()}
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                  "metadata": {"name": name, "namespace": ns,
                               "labels": {"app.kubernetes.io/managed-by": "cicd-portal", "cicd.k-paas.org/app": app}},
                  "data": data}))
PY
}
apply_password_secret() { # namespace name  (value in env S_PASSWORD)
  python3 - "$1" "$2" "$APP" <<'PY' | kubectl apply -f - >/dev/null
import base64, json, os, sys
ns, name, app = sys.argv[1:]
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                  "metadata": {"name": name, "namespace": ns,
                               "labels": {"app.kubernetes.io/managed-by": "cicd-portal", "cicd.k-paas.org/app": app}},
                  "data": {"password": base64.b64encode(os.environ["S_PASSWORD"].encode()).decode()}}))
PY
}
# MariaDB identifier: letters, digits, _ (max 64)
db_ident() { local s=${1//-/_}; echo "${s:0:64}"; }

# Run SQL as root on the K-PaaS MariaDB; the root password goes through stdin (first line)
platform_sql() { # sql on stdin
  local pod
  pod=$(kubectl -n mariadb get pods -l app.kubernetes.io/name=mariadb -o name 2>/dev/null | head -n 1)
  [[ -n "$DATABASE_USER_PASSWORD" ]] || die "DATABASE_USER_PASSWORD not found in $PORTAL_VARS (K-PaaS MariaDB root)."
  { printf '%s\n' "$DATABASE_USER_PASSWORD"; cat; } | kubectl -n mariadb exec -i "${pod:-mariadb-0}" -- \
    sh -c 'IFS= read -r MYSQL_PWD; export MYSQL_PWD; c=$(command -v mariadb || command -v mysql); "$c" -uroot'
}

# 1. Secrets per environment ----------------------------------------------------------------------
for env in "${ENVS[@]}"; do
  env_names "$env"
  ns=$NS
  kubectl get namespace "$ns" >/dev/null 2>&1 || die "Namespace $ns not found (onboard-vendor.sh $VENDOR)."
  if kubectl -n "$ns" get secret "$SECRET" >/dev/null 2>&1 && [[ "${DB_SECRET_UPDATE:-0}" != 1 || "$MODE" == dedicated ]]; then
    info "Secret $ns/$SECRET exists - kept"
    continue
  fi
  case "$MODE" in
    dedicated)
      # A MariaDB volume keeps the password it was initialised with: a new Secret would not match
      if kubectl -n "$ns" get pvc "data-$DB_POD" >/dev/null 2>&1; then
        die "$ns has volume data-$DB_POD but no Secret $SECRET: restore the old Secret, or delete the volume (DATA LOSS): kubectl -n $ns delete pvc data-$DB_POD"
      fi
      S_HOST="$DB_SERVICE" S_PORT=3306 S_NAME=$(db_ident "$APP") S_USER=$(db_ident "$APP") \
        S_PASSWORD=$(random_string 24) apply_db_secret "$ns" "$SECRET"
      kubectl -n "$ns" get secret "$ROOT_SECRET" >/dev/null 2>&1 || \
        S_PASSWORD=$(random_string 24) apply_password_secret "$ns" "$ROOT_SECRET"
      ok "Secrets $ns/$SECRET, $ns/$ROOT_SECRET (dedicated MariaDB $DB_SERVICE)"
      ;;
    shared)
      name=$(db_ident "${VENDOR}_${APP}_${env}")
      password=$(random_string 24)
      # identifiers are [a-z0-9_] (validated names), the password is alphanumeric
      platform_sql <<SQL || die "Cannot create database $name on the K-PaaS MariaDB (kubectl -n mariadb get pods)."
CREATE DATABASE IF NOT EXISTS \`$name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$name'@'%' IDENTIFIED BY '$password';
ALTER USER '$name'@'%' IDENTIFIED BY '$password';
GRANT ALL PRIVILEGES ON \`$name\`.* TO '$name'@'%';
SQL
      S_HOST=${PLATFORM_DB_URL%%:*} S_PORT=${PLATFORM_DB_URL##*:} S_NAME=$name S_USER=$name S_PASSWORD=$password \
        apply_db_secret "$ns" "$SECRET"
      unset password
      ok "Database and user $name on the K-PaaS MariaDB, Secret $ns/$SECRET"
      ;;
    external)
      S_HOST=$DB_HOST S_PORT=${DB_PORT:-3306} S_NAME=$DB_NAME S_USER=$DB_USER S_PASSWORD=$DB_PASSWORD \
        apply_db_secret "$ns" "$SECRET"
      ok "Secret $ns/$SECRET -> $DB_USER@$DB_HOST:${DB_PORT:-3306}/$DB_NAME"
      ;;
  esac
done

# 2. gitops: MariaDB (dedicated) and envFrom on the Deployment ---------------------------------------
if [[ "$SOURCE" == scm ]]; then
  require_scm_admin
  gdir=$(scm_clone "$VENDOR-gitops")
else
  load_gitlab_token
  gdir="$(mktemp -d)/repo"
  GIT_SSL_CAINFO=$CA_FILE GIT_TERMINAL_PROMPT=0 \
    git -c credential.helper='!f() { echo username=oauth2; echo "password=$GITLAB_TOKEN"; }; f' \
    clone -q -b main "$GITLAB_GIT_URL/$VENDOR/gitops.git" "$gdir" || die "Cannot clone GitLab $VENDOR/gitops"
  git -C "$gdir" config credential.helper '!f() { echo username=oauth2; echo "password=$GITLAB_TOKEN"; }; f'
  git -C "$gdir" config http.sslCAInfo "$CA_FILE"
  git -C "$gdir" config user.name "cicd-portal"
  git -C "$gdir" config user.email "cicd-portal@${HOST_DOMAIN}"
fi
for env in "${ENVS[@]}"; do
  env_names "$env"
  overlay="$gdir/apps/$APP/overlays/$env"
  [[ -f "$overlay/kustomization.yaml" ]] || die "gitops apps/$APP/overlays/$env not found (add-app.sh $VENDOR $APP <type>)."
  if [[ "$MODE" == dedicated && ! -f "$overlay/mariadb.yaml" ]]; then
    render_file ../db-template/mariadb.yaml "$overlay/mariadb.yaml" APP="$APP" MARIADB_IMAGE="$MARIADB_IMAGE" \
      DB_SECRET="$SECRET" ROOT_SECRET="$ROOT_SECRET" \
      STORAGECLASS="$DB_STORAGECLASS" DB_SIZE="$DB_SIZE"
    [[ -n "$DB_STORAGECLASS" ]] || sed -i '/storageClassName: /d' "$overlay/mariadb.yaml"
  fi
  [[ "$MODE" != dedicated && -f "$overlay/mariadb.yaml" ]] && \
    warn "apps/$APP/overlays/$env still deploys the dedicated MariaDB (mariadb.yaml): remove it from the overlay once its data is migrated"
  python3 - "$overlay/kustomization.yaml" "$APP" "$([[ "$MODE" == dedicated ]] && echo 1 || echo 0)" "$SECRET" <<'PY'
import re, sys
path, app, dedicated, secret = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4]
lines = open(path, encoding="utf-8").read().splitlines()
text = "\n".join(lines)
if dedicated and not re.search(r"^\s*-\s*mariadb\.yaml\s*(#.*)?$", text, re.M):
    i = next((n for n, l in enumerate(lines) if re.match(r"^\s*-\s*\.\./\.\./base\s*(#.*)?$", l)), None)
    if i is None:
        sys.exit("resources entry '../../base' not found in " + path)
    indent = re.match(r"^(\s*)", lines[i]).group(1)
    lines.insert(i + 1, f"{indent}- mariadb.yaml")
if f"name: {secret}" not in text:
    block = f"""  - target:
      kind: Deployment
      name: {app}
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/envFrom
        value:
          - secretRef:
              name: {secret}""".splitlines()
    p = next((n for n, l in enumerate(lines) if re.match(r"^patches:\s*$", l)), None)
    if p is None:
        lines += ["patches:"] + block
    else:
        end = next((n for n in range(p + 1, len(lines)) if lines[n] and not lines[n][0].isspace()
                    and not lines[n].startswith("#")), len(lines))
        while end > p + 1 and not lines[end - 1].strip():
            end -= 1
        lines[end:end] = block
open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY
done
envs_text="${ENVS[*]}"
if scm_commit_push "$gdir" main "Connect $APP ($envs_text) to MariaDB: $MODE (cicd-portal)"; then
  ok "gitops apps/$APP/overlays/{${envs_text// /,}}: $([[ "$MODE" == dedicated ]] && echo "dedicated MariaDB + ")envFrom DB Secret"
else
  info "gitops apps/$APP already connected to $SECRET"
fi
if [[ "$SOURCE" == scm ]]; then scm_cleanup "$gdir"; else rm -rf "$(dirname "$gdir")"; fi

echo
echo "Database for $VENDOR/$APP ($MODE, ${envs_text}):"
for env in "${ENVS[@]}"; do
  if [[ "$env" == dev ]]; then
    echo "  dev  : Argo CD $VENDOR-$APP-dev syncs automatically (~3 min). Check: https://$APP-$VENDOR-dev.$HOST_DOMAIN"
  else
    echo "  prod : Argo CD $VENDOR-$APP-prod -> APP DIFF -> SYNC (cicd-admins)"
  fi
done
env_names "${ENVS[0]}"
echo "  App environment: DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD (Secret $SECRET in $NS)"
echo "  Read a value   : kubectl -n $NS get secret $SECRET -o jsonpath='{.data.DB_PASSWORD}' | base64 -d"
[[ "$MODE" == dedicated ]] && \
  echo "  Database shell : kubectl -n $NS exec -it $DB_POD -- sh -c 'mariadb -u\"\$MARIADB_USER\" -p\"\$MARIADB_PASSWORD\" \"\$MARIADB_DATABASE\"'"
exit 0
