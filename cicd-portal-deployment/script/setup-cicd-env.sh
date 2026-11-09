#!/bin/bash
# Interactive setup of the CI/CD portal on an existing K-PaaS (RKE2 or Kubernetes): asks for the values the
# installation needs, finds what it can in the cluster (domain, IngressClass, StorageClass, K-PaaS CA), checks every
# password and the certificates right away, runs the preflight and - step by step, after asking - the deployment.
# docs/cicd-portal-env-reference.md
#
# Usage: ./setup-cicd-env.sh [--answers FILE] [--yes] [--no-deploy]
#   --answers FILE  defaults from a file in the format of cicd-vars.local.sh (another server, a re-run)
#   --yes           accept the defaults (no questions; passwords from the environment or the secrets file)
#   --no-deploy     stop after the preflight
#
# Writes (not in git):
#   script/cicd-vars.local.sh   values of this installation (read by cicd-vars.sh, also by the console)
#   script/portal-vars.local.sh only when cp-portal-vars.sh is missing or its admin passwords no longer work (0600)
#   certs/ca.crt                only when the K-PaaS CA is not cp-portal-deployment/certs/ca.crt (public CA only)
#   values/rke2-node-ca.sh      RKE2: CA for the nodes (run as root on every node when Harbor pulls fail)
# Passwords are asked hidden, never put on a command line, and kept for this run only (optionally the SCM
# password in ~/.config/cicd-portal/secrets.env, 0600). The CA private key (ca.key) is never asked for or read.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
ROOT=$(cd .. && pwd)
PORTAL_DIR=${PORTAL_DIR:-"$ROOT/../cp-portal-deployment"}
LOCAL="$SCRIPT_DIR/cicd-vars.local.sh"
PLOCAL="$SCRIPT_DIR/portal-vars.local.sh"
SECRETS_FILE=${CICD_SECRETS_FILE:-"$HOME/.config/cicd-portal/secrets.env"}

ANSWERS="" YES=0 DEPLOY=1
while (($#)); do
  case "$1" in
    --answers) ANSWERS=$(cd "$(dirname "$2")" && pwd)/$(basename "$2"); shift 2 ;;
    --yes) YES=1; shift ;;
    --no-deploy) DEPLOY=0; shift ;;
    *) echo "Usage: $0 [--answers FILE] [--yes] [--no-deploy]" >&2; exit 2 ;;
  esac
done

C_B=$'\e[1m' C_0=$'\e[0m'
[[ -t 1 ]] || { C_B=""; C_0=""; }
info() { echo "[INFO] $*"; }
ok() { echo "[OK]   $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }
title() { echo; echo "${C_B}== $* ==${C_0}"; }

# ask VAR "question" default [regex]   (--yes: the default)
ask() {
  local var=$1 q=$2 def=${3:-} re=${4:-} v
  while true; do
    if ((YES)); then v=$def
    else read -rp "  $q [${def}]: " v || true; v=${v:-$def}; fi
    if [[ -z "$re" || "$v" =~ $re ]]; then printf -v "$var" '%s' "$v"; return 0; fi
    ((YES)) && die "$q: '$v' is not valid"
    echo "  -> 형식이 맞지 않습니다."
  done
}
yesno() { # "question" default(y|n)
  local a
  if ((YES)); then [[ "$2" == y ]]; return; fi
  read -rp "  $1 [$([[ $2 == y ]] && echo Y/n || echo y/N)]: " a || true
  a=${a:-$2}; [[ "$a" =~ ^[Yy] ]]
}
# secret VAR "question" check-command...   (hidden input, checked; 3 tries)
secret() {
  local var=$1 q=$2 v reason try; shift 2
  for try in 1 2 3; do
    if ((YES)); then die "$q: not set (export it, or run without --yes)"; fi
    read -rsp "  $q: " v || true; echo
    [[ -n "$v" ]] || continue
    if reason=$(printf '%s\n' "$v" | "$@" 2>&1); then printf -v "$var" '%s' "$v"; ok "로그인 확인"; return 0; fi
    echo "  -> 로그인 실패: $reason"
  done
  die "$q: 3번 실패했습니다."
}
check() { printf '%s\n' "$1" | python3 setup_check.py login "${@:2}"; }

# value of a variable in a vars file (in a subshell: the files define many names)
file_var() { # file name
  [[ -f "$1" ]] || return 0
  (set +u; cicd_set() { printf -v "$1" '%s' "$2"; }; source "$1" >/dev/null 2>&1; printf '%s' "${!2:-}")
}
# default: answers file > this installation's local file > fallback
cur() { # name fallback
  local v=""
  [[ -n "$ANSWERS" ]] && v=$(file_var "$ANSWERS" "$1")
  [[ -z "$v" ]] && v=$(file_var "$LOCAL" "$1")
  printf '%s' "${v:-$2}"
}

declare -A OUT=()          # cicd-vars.local.sh
declare -A PV=()           # portal values (cp-portal-vars.sh or portal-vars.local.sh)
NEED_PLOCAL=0
EXTRA_LINES=()

echo "${C_B}CI/CD 포털 설치 설정${C_0} - Enter: [기본값] 사용. 비밀번호는 화면에 보이지 않습니다."

# 1. Kubernetes / RKE2 --------------------------------------------------------------------------------------------
title "1/7 Kubernetes 접속"
if ! command -v kubectl >/dev/null && [[ -x /var/lib/rancher/rke2/bin/kubectl ]]; then
  export PATH="$PATH:/var/lib/rancher/rke2/bin"
  EXTRA_LINES+=('[[ -x /var/lib/rancher/rke2/bin/kubectl ]] && ! command -v kubectl >/dev/null && PATH="$PATH:/var/lib/rancher/rke2/bin"')
  info "RKE2 kubectl: /var/lib/rancher/rke2/bin/kubectl"
fi
if [[ -z "${KUBECONFIG:-}" && ! -f "$HOME/.kube/config" && -r /etc/rancher/rke2/rke2.yaml ]]; then
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
  EXTRA_LINES+=('[[ -z "${KUBECONFIG:-}" && ! -f "$HOME/.kube/config" && -r /etc/rancher/rke2/rke2.yaml ]] && export KUBECONFIG=/etc/rancher/rke2/rke2.yaml')
  info "RKE2 kubeconfig: /etc/rancher/rke2/rke2.yaml"
fi
for c in kubectl python3 openssl; do command -v "$c" >/dev/null || die "$c 가 없습니다 (sudo dnf install -y $c)"; done
kubectl get nodes >/dev/null 2>&1 || die "kubectl get nodes 실패 - KUBECONFIG 를 확인하세요 (RKE2: /etc/rancher/rke2/rke2.yaml, root 권한)"
D=$(python3 setup_check.py discover)
dget() { python3 -c 'import functools,json,sys; v=functools.reduce(lambda a,k: a[k], sys.argv[2].split("."), json.loads(sys.argv[1]))
print(" ".join(v) if isinstance(v, list) else v)' "$D" "$1"; }
DISTRO=$(dget distro)
ok "$(dget nodes) nodes, $DISTRO ($(dget versions))"
for ns in cp-portal keycloak harbor mariadb; do
  [[ $(dget "namespaces.$ns") == True ]] || die "K-PaaS 네임스페이스 $ns 가 없습니다 - CP-Portal 을 먼저 설치하세요"
done
ok "K-PaaS: cp-portal, keycloak, harbor, mariadb"

# 2. K-PaaS values ----------------------------------------------------------------------------------------------------
title "2/7 기존 K-PaaS 정보"
PORTAL_VARS_FILE=$(cur PORTAL_VARS "${PORTAL_VARS:-$PORTAL_DIR/script/cp-portal-vars.sh}")
[[ "$PORTAL_VARS_FILE" == "$PLOCAL" && ! -f "$PLOCAL" ]] && PORTAL_VARS_FILE="$PORTAL_DIR/script/cp-portal-vars.sh"
for k in HOST_DOMAIN K8S_STORAGECLASS KEYCLOAK_URL KEYCLOAK_ADMIN_USERNAME KEYCLOAK_ADMIN_PASSWORD KEYCLOAK_CP_REALM \
         REPOSITORY_URL REPOSITORY_USERNAME REPOSITORY_PASSWORD DATABASE_URL DATABASE_USER_PASSWORD; do
  PV[$k]=$(file_var "$PORTAL_VARS_FILE" "$k")
done
if [[ "$PORTAL_VARS_FILE" == "$PLOCAL" ]]; then info "CP-Portal 설정: $PLOCAL (이전 실행에서 만든 것)"; NEED_PLOCAL=1
elif [[ -f "$PORTAL_VARS_FILE" ]]; then info "CP-Portal 설정: $PORTAL_VARS_FILE"
else warn "CP-Portal 설정 파일이 없습니다 ($PORTAL_VARS_FILE) - 입력한 값으로 portal-vars.local.sh 를 만듭니다"; NEED_PLOCAL=1; fi
def_domain=${PV[HOST_DOMAIN]}
[[ -z "$def_domain" || "$def_domain" == *'{'* ]] && def_domain=$(dget domain)
ask DOMAIN "도메인 (portal.<도메인>)" "$def_domain" '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
if [[ "$DOMAIN" != "${PV[HOST_DOMAIN]}" ]]; then
  if [[ -f "$PORTAL_VARS_FILE" && "${PV[HOST_DOMAIN]}" != *'{'* && -n "${PV[HOST_DOMAIN]}" ]]; then OUT[HOST_DOMAIN]=$DOMAIN
  else PV[HOST_DOMAIN]=$DOMAIN; NEED_PLOCAL=1; fi
fi
getent hosts "keycloak.$DOMAIN" >/dev/null || warn "keycloak.$DOMAIN 이 이 서버에서 해석되지 않습니다 (DNS *.$DOMAIN -> Ingress IP $(dget lb_ip))"

# 3. certificates -------------------------------------------------------------------------------------------------------
title "3/7 인증서 (K-PaaS CA)"
CA=""
for f in "$(cur CA_FILE "")" "$PORTAL_DIR/certs/ca.crt" "$ROOT/certs/ca.crt"; do
  [[ -n "$f" && -s "$f" ]] && { CA=$f; info "CA 후보: $f"; break; }
done
if [[ -z "$CA" ]]; then
  mkdir -p "$ROOT/certs"
  if where=$(python3 setup_check.py ca-from-cluster "$ROOT/certs/ca.crt" 2>/dev/null); then
    CA="$ROOT/certs/ca.crt"; chmod 644 "$CA"; info "클러스터에서 CA 를 찾았습니다 ($where)"
  fi
fi
while true; do
  if [[ -z "$CA" ]]; then
    ((YES)) && die "K-PaaS CA 를 찾지 못했습니다 - CA_FILE 을 지정하세요"
    ask CA "K-PaaS CA 인증서 경로 (ca.crt, CP-Portal 설치 서버의 cp-portal-deployment/certs/ca.crt)" "" '^.+$'
  fi
  if out=$(python3 setup_check.py verify-ca "$CA" "$DOMAIN"); then echo "$out" | sed 's/^/  /'; break; fi
  echo "$out" | sed 's/^/  /'
  ((YES)) && die "인증서 확인 실패"
  yesno "다른 CA 파일을 지정할까요?" y || die "인증서 확인 실패 - CA 와 *.$DOMAIN 인증서를 확인하세요"
  CA=""
done
openssl x509 -noout -fingerprint -sha256 -in "$CA" | sed 's/^/  CA /'
if [[ "$CA" != "$PORTAL_DIR/certs/ca.crt" ]]; then
  if [[ "$CA" != "$ROOT/certs/ca.crt" ]]; then mkdir -p "$ROOT/certs"; cp "$CA" "$ROOT/certs/ca.crt"; chmod 644 "$ROOT/certs/ca.crt"; fi
  CA="$ROOT/certs/ca.crt"; OUT[CA_FILE]=$CA
fi
export CA_FILE=$CA

# 4. admin accounts ---------------------------------------------------------------------------------------------------
title "4/7 관리자 계정 확인"
kc_url=${PV[KEYCLOAK_URL]//\$\{HOST_DOMAIN\}/$DOMAIN}; kc_url=${kc_url//\{host domain\}/$DOMAIN}
[[ -z "$kc_url" || "$kc_url" == *'{'* || "$kc_url" == *'$'* ]] && kc_url="https://keycloak.$DOMAIN"
hb_url=${PV[REPOSITORY_URL]//\{host domain\}/$DOMAIN}
[[ -z "$hb_url" || "$hb_url" == *'{'* || "$hb_url" == *'$'* ]] && hb_url="https://harbor.$DOMAIN"
PV[KEYCLOAK_URL]=$kc_url PV[REPOSITORY_URL]=$hb_url
PV[KEYCLOAK_CP_REALM]=${PV[KEYCLOAK_CP_REALM]:-cp-realm}
PV[KEYCLOAK_ADMIN_USERNAME]=${PV[KEYCLOAK_ADMIN_USERNAME]:-admin}
PV[REPOSITORY_USERNAME]=${PV[REPOSITORY_USERNAME]:-admin}
PV[DATABASE_URL]=${PV[DATABASE_URL]:-mariadb.mariadb.svc.cluster.local:3306}
account() { # label password-key login-args...
  local label=$1 key=$2 reason; shift 2
  if [[ -n "${PV[$key]}" ]] && reason=$(check "${PV[$key]}" "$@" 2>&1); then ok "$label: 설정 파일의 비밀번호로 로그인됨"; return; fi
  [[ -n "${PV[$key]}" ]] && warn "$label: 설정 파일의 비밀번호로 로그인 실패 (${reason:-?}) - 현재 비밀번호를 입력하세요"
  secret "PV[$key]" "$label 비밀번호" python3 setup_check.py login "$@"
  NEED_PLOCAL=1
}
account "Keycloak $kc_url (${PV[KEYCLOAK_ADMIN_USERNAME]})" KEYCLOAK_ADMIN_PASSWORD keycloak "$kc_url" "${PV[KEYCLOAK_ADMIN_USERNAME]}"
account "Harbor $hb_url (${PV[REPOSITORY_USERNAME]})" REPOSITORY_PASSWORD harbor "$hb_url" "${PV[REPOSITORY_USERNAME]}"
account "MariaDB root" DATABASE_USER_PASSWORD mariadb

# 5. what to install --------------------------------------------------------------------------------------------------
title "5/7 설치 선택"
def_src=$(cur CICD_SOURCES "")
[[ -z "$def_src" ]] && { [[ $(dget namespaces.cp-source-control) == True ]] && def_src="scm" || def_src="gitlab"; }
ask SOURCES "소스 (scm = K-PaaS SCM + Jenkins, gitlab = GitLab CE, 둘 다: \"scm gitlab\")" "$def_src" '^(scm|gitlab|scm gitlab|gitlab scm)$'
OUT[CICD_SOURCES]=$SOURCES
SCM_PW=${SCM_ADMIN_PASSWORD:-}
[[ -z "$SCM_PW" && -f "$SECRETS_FILE" ]] && SCM_PW=$(file_var "$SECRETS_FILE" SCM_ADMIN_PASSWORD)
if [[ " $SOURCES " == *" scm "* ]]; then
  [[ $(dget namespaces.cp-source-control) == True ]] || die "K-PaaS 소스 컨트롤(cp-source-control)이 없습니다 - cp-source-control-deployment 를 먼저 설치하세요"
  ask SCM_USER "SCM 관리자 ID" "$(cur SCM_ADMIN_USER scmadmin)" '^[A-Za-z0-9._@-]+$'
  [[ "$SCM_USER" != scmadmin ]] && OUT[SCM_ADMIN_USER]=$SCM_USER
  scm_url="${CICD_SCM_URL:-https://scm-manager.$DOMAIN/scm}"
  if [[ -n "$SCM_PW" ]] && check "$SCM_PW" scm "$scm_url" "$SCM_USER" >/dev/null; then ok "SCM $SCM_USER: 저장된/환경 변수 비밀번호로 로그인됨"
  else
    echo "  SCM 관리자 비밀번호 = https://scm.$DOMAIN 에 $SCM_USER 로 로그인 > 내정보 관리에서 정한 git 비밀번호"
    secret SCM_PW "SCM $SCM_USER git 비밀번호" python3 setup_check.py login scm "$scm_url" "$SCM_USER"
  fi
fi

mapfile -t SCS < <(dget storage_classes | tr ' ' '\n' | sed '/^$/d')
((${#SCS[@]})) || die "StorageClass 가 없습니다"
def_sc=$(cur K8S_STORAGECLASS "${PV[K8S_STORAGECLASS]}")
printf '%s\n' "${SCS[@]}" | grep -qx "$def_sc" || def_sc=$(dget default_storage_class)
[[ -n "$def_sc" ]] || def_sc=${SCS[0]}
echo "  StorageClass 목록: ${SCS[*]}"
ask SC "StorageClass" "$def_sc" "^($(IFS='|'; echo "${SCS[*]}"))$"
[[ "$SC" == local-path ]] && warn "local-path 는 노드 디스크에 저장됩니다 (노드 장애 시 Jenkins/GitLab 데이터 위험) - 운영은 NFS/Longhorn 권장"
[[ "$SC" != "${PV[K8S_STORAGECLASS]}" ]] && OUT[K8S_STORAGECLASS]=$SC

mapfile -t ICS < <(dget ingress_classes | tr ' ' '\n' | sed '/^$/d')
((${#ICS[@]})) || die "IngressClass 가 없습니다"
def_ic=$(cur INGRESS_CLASS_NAME nginx)
printf '%s\n' "${ICS[@]}" | grep -qx "$def_ic" || def_ic=${ICS[0]}
echo "  IngressClass 목록: ${ICS[*]}"
ask IC "IngressClass (CP-Portal 이 쓰는 것)" "$def_ic" "^($(IFS='|'; echo "${ICS[*]}"))$"
[[ "$IC" != nginx ]] && OUT[INGRESS_CLASS_NAME]=$IC

if [[ "$DISTRO" == rke2 ]]; then
  echo "  RKE2: CIS 프로필이면 Pod Security 기본값이 restricted 라 빌드 Pod(root)가 거부됩니다."
  ask PSA "CI 네임스페이스 Pod Security (baseline 권장)" "$(cur CICD_POD_SECURITY baseline)" '^(baseline|privileged|restricted)?$'
  OUT[CICD_POD_SECURITY]=$PSA
  ask VPSA "업체 네임스페이스 Pod Security (비움 = 클러스터 기본, root 이미지면 baseline)" "$(cur VENDOR_POD_SECURITY "")" '^(baseline|privileged|restricted)?$'
  OUT[VENDOR_POD_SECURITY]=$VPSA
fi

# 6. closed network ---------------------------------------------------------------------------------------------------
title "6/7 폐쇄망 (인터넷 없이 설치)"
OFFLINE=n; [[ -n "$(cur CICD_CHART_DIR "")" ]] && OFFLINE=y
if yesno "폐쇄망입니까? (차트·이미지를 반입 묶음과 Harbor 에서)" "$OFFLINE"; then
  ask CHARTS "Helm 차트 폴더 (반입 묶음의 charts)" "$(cur CICD_CHART_DIR /opt/offline/charts)" '^/.+'
  [[ -d "$CHARTS" ]] || warn "$CHARTS 가 없습니다 - 반입 묶음을 먼저 복사하세요"
  OUT[CICD_CHART_DIR]=$CHARTS
  if vals=$(printf '%s\n' "${PV[REPOSITORY_PASSWORD]}" | python3 setup_check.py harbor-mirror "$hb_url" "${PV[REPOSITORY_USERNAME]}"); then
    # read the list first: ask reads the answers from stdin
    mapfile -t MIRROR < <(python3 -c 'import json,sys; [print(f"{k}\t{v}") for k,v in json.loads(sys.argv[1]).items()]' "$vals")
    for line in "${MIRROR[@]}"; do
      k=${line%%$'\t'*}; v=${line#*$'\t'}
      ask val "$k (Harbor)" "$(cur "$k" "$v")"; OUT[$k]=$val
    done
  fi
  grep -q . <<<"${OUT[JENKINS_IMAGE]:-}" || warn "Harbor 에 cicd-mirror/jenkins:*-plugins 가 없습니다 - offline/load-to-harbor.sh 를 먼저 실행하세요"
  ask NEXUS "사내 Nexus 주소 (앱 빌드 의존성, 없으면 비움)" "$(cur CICD_NEXUS_URL "")" '^(https?://.+)?$'
  OUT[CICD_NEXUS_URL]=$NEXUS
fi

# 7. write, node CA, preflight, deploy --------------------------------------------------------------------------------
title "7/7 저장과 점검"
{
  echo "# Values of this installation - written by setup-cicd-env.sh $(date '+%Y-%m-%d %H:%M') (re-run it to change them)."
  echo "# Read by cicd-vars.sh after its defaults; variables exported by the caller win. Not in git. No passwords."
  for l in "${EXTRA_LINES[@]}"; do echo "$l"; done
  for k in $(printf '%s\n' "${!OUT[@]}" | sort); do printf 'cicd_set %s %q\n' "$k" "${OUT[$k]}"; done
} > "$LOCAL.tmp"
if ((NEED_PLOCAL)); then
  umask_old=$(umask); umask 077
  {
    echo "# K-PaaS values for the CI/CD portal (setup-cicd-env.sh): cp-portal-vars.sh was missing or its admin passwords"
    echo "# no longer worked. Admin passwords: keep this file private (0600), never in git or in an image."
    for k in HOST_DOMAIN K8S_STORAGECLASS KEYCLOAK_URL KEYCLOAK_ADMIN_USERNAME KEYCLOAK_ADMIN_PASSWORD KEYCLOAK_CP_REALM \
             REPOSITORY_URL REPOSITORY_USERNAME REPOSITORY_PASSWORD DATABASE_URL DATABASE_USER_PASSWORD; do
      v=${PV[$k]}; [[ "$k" == HOST_DOMAIN ]] && v=$DOMAIN; [[ "$k" == K8S_STORAGECLASS ]] && v=$SC
      printf '%s=%q\n' "$k" "$v"
    done
  } > "$PLOCAL"
  umask "$umask_old"; chmod 600 "$PLOCAL"
  printf 'cicd_set PORTAL_VARS %q\n' "$PLOCAL" >> "$LOCAL.tmp"
  ok "portal-vars.local.sh (0600): cp-portal-vars.sh 대신 사용 - 원본 파일은 바꾸지 않았습니다"
fi
[[ -f "$LOCAL" ]] && cp "$LOCAL" "$LOCAL.bak"
mv "$LOCAL.tmp" "$LOCAL"
ok "저장: $LOCAL"
sed -n '/^cicd_set/p' "$LOCAL" | sed 's/^cicd_set /  /'

if [[ "$DISTRO" == rke2 ]]; then
  mkdir -p "$ROOT/values"
  python3 setup_check.py node-ca-script "$CA" "$DOMAIN" "harbor.$DOMAIN" > "$ROOT/values/rke2-node-ca.sh"
  chmod 755 "$ROOT/values/rke2-node-ca.sh"
  info "RKE2 노드용 CA 설치 스크립트: $ROOT/values/rke2-node-ca.sh"
  info "  (점검에서 노드의 Harbor 이미지 받기가 x509 로 실패하면 그 노드에서 root 로 실행 - 제어 노드 포함)"
fi

if [[ -n "$SCM_PW" ]] && yesno "SCM 비밀번호를 다음 실행을 위해 $SECRETS_FILE (0600)에 저장할까요?" n; then
  mkdir -p "$(dirname "$SECRETS_FILE")"; chmod 700 "$(dirname "$SECRETS_FILE")"
  (umask 077; printf 'SCM_ADMIN_PASSWORD=%q\n' "$SCM_PW" > "$SECRETS_FILE")
  ok "저장: $SECRETS_FILE"
fi
[[ -n "$SCM_PW" ]] && export SCM_ADMIN_PASSWORD=$SCM_PW

title "사전 점검 (./deploy-cicd-portal.sh preflight)"
if ! ./deploy-cicd-portal.sh preflight; then
  echo
  warn "점검 실패 항목을 고친 뒤 다시 실행하세요: ./setup-cicd-env.sh (입력한 값이 기본값으로 나옵니다)"
  [[ "$DISTRO" == rke2 ]] && warn "Harbor 이미지 받기 x509 실패 -> 해당 노드에서: sudo bash $ROOT/values/rke2-node-ca.sh"
  exit 1
fi
((DEPLOY)) || { ok "설정과 점검 완료 (--no-deploy). 배포: ./deploy-cicd-portal.sh"; exit 0; }

title "배포"
run() { echo "+ ./deploy-cicd-portal.sh $*"; ./deploy-cicd-portal.sh "$@"; }
if yesno "Keycloak 설정 + $SOURCES + Argo CD 설치를 진행할까요? (./deploy-cicd-portal.sh)" y; then run; fi
if [[ " $SOURCES " == *" scm "* ]] && yesno "Jenkins API 토큰을 등록할까요? (Jenkins 로그인 필요, 1회)" y; then
  ask JUSER "Jenkins 에 로그인할 운영자 ID (Keycloak 그룹 cicd-admins)" "$(cur JENKINS_USER "${PV[KEYCLOAK_ADMIN_USERNAME]}")" '^[A-Za-z0-9._@-]+$'
  if yesno "$JUSER 를 Keycloak 그룹 cicd-admins 에 추가할까요?" y; then
    bash -c 'source ./lib.sh; load_portal_vars; $API kc-group "$KEYCLOAK_ADMIN_GROUP" --members "$1"' _ "$JUSER"
  fi
  echo "  https://jenkins.$DOMAIN 에 $JUSER 로 로그인 > 오른쪽 위 사용자 > Security > API Token > Add new Token"
  read -rsp "  생성한 API 토큰: " JTOKEN; echo
  [[ -n "$JTOKEN" ]] && JENKINS_USER=$JUSER JENKINS_API_TOKEN=$JTOKEN run jenkins-token
  unset JTOKEN
fi
if yesno "CI/CD 콘솔을 설치할까요? (https://cicd.$DOMAIN)" y; then
  if [[ -n "${OUT[CICD_CHART_DIR]:-}" ]]; then run console    # closed network: the image is already in Harbor
  else run console-image console; fi
fi
if yesno "보안 검사(품질 관리)를 설치할까요?" n; then
  if [[ -n "${OUT[CICD_CHART_DIR]:-}" ]]; then run security; else run security-image security; fi
fi
echo
ok "완료. 확인: ./check-cicd-portal.sh   설정 다시 하기: ./setup-cicd-env.sh"
