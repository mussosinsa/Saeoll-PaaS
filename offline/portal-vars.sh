# K-PaaS values for the offline scripts (sourced): sets PORTAL_VARS to a cp-portal-vars.sh that has HOST_DOMAIN.
#   PORTAL_VARS from the environment > <repo>/cp-portal-deployment/script/cp-portal-vars.sh > the copy the CI/CD
#   console keeps in the cluster (secret cicd-console/cicd-console-secrets, written to a 0600 temp file that
#   PORTAL_VARS_TMP names; the caller removes it)
# shellcheck shell=bash
resolve_portal_vars() { # repo-dir
  local file=${PORTAL_VARS:-"$1/cp-portal-deployment/script/cp-portal-vars.sh"} domain copy
  domain=$( (set +eu; source "$file" >/dev/null 2>&1; echo "${HOST_DOMAIN:-}") 2>/dev/null || true)
  if [[ -n "$domain" && "$domain" != *'{'* ]]; then
    PORTAL_VARS=$file
    return 0
  fi
  copy=$(mktemp); chmod 600 "$copy"
  if command -v kubectl >/dev/null && kubectl -n "${CONSOLE_NAMESPACE:-cicd-console}" get secret cicd-console-secrets \
       -o jsonpath='{.data.cp-portal-vars\.sh}' 2>/dev/null | base64 -d > "$copy" 2>/dev/null && [[ -s "$copy" ]]; then
    domain=$( (set +eu; source "$copy" >/dev/null 2>&1; echo "${HOST_DOMAIN:-}") )
    if [[ -n "$domain" && "$domain" != *'{'* ]]; then
      echo "[WARN] $file has no HOST_DOMAIN - using the copy of the CI/CD console ($domain)." >&2
      echo "       Fix the file: cp-portal-deployment/script/restore-vars-from-cluster.sh" >&2
      PORTAL_VARS=$copy PORTAL_VARS_TMP=$copy
      return 0
    fi
  fi
  rm -f "$copy"
  echo "[ERROR] HOST_DOMAIN is not configured in $file (and no copy in the cluster)." >&2
  echo "        Restore it: cd $1/cp-portal-deployment/script && ./restore-vars-from-cluster.sh, or PORTAL_VARS=<file>" >&2
  return 1
}
