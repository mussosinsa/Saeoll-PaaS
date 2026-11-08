# 폐쇄망 설치 따라하기 (초보자용)

인터넷이 차단된 폐쇄망에 **K-PaaS + CI/CD 포털 전체**(CP-Portal, 소스 컨트롤, 파이프라인, Jenkins, GitLab, Argo CD, 콘솔,
보안 검사, Nexus)를 처음부터 설치하는 과정을 **순서대로 따라 하기만 하면 되도록** 정리했다.
명령은 한 줄씩 복사해 실행하고, 각 단계의 **"성공 확인"**이 맞는지 본 다음 다음 단계로 넘어간다.

> 더 자세한 원리·옵션은 [폐쇄망 설치 가이드](install-offline.md), 도메인·백업은 [도메인 방식 재설치 가이드](install-with-domain.md)에 있다.

---

## 0. 전체 그림

세 곳에서 작업한다.

```text
 ① 지금 서버 (인터넷 O, 초기화 전)        ② 부트스트랩 VM (폐쇄망)           ③ 새 서버들 (폐쇄망, OS 재설치)
 ─────────────────────────────          ───────────────────────          ─────────────────────────────
 필요한 것 전부 모으기  ──USB·망연계──▶   창고 역할                        Kubernetes, K-PaaS, CI/CD 포털
 (이미지·패키지·라이브러리·백업)            · 패키지 저장소 (dnf)   ◀────── 모든 서버가 여기서 받음
                                         · 이미지 저장소 (레지스트리)
                                         · 라이브러리 저장소 (Nexus)
```

| 파트 | 어디서 | 하는 일 | 시간(대략) |
| --- | --- | --- | --- |
| [A](#파트-a-지금-서버에서-모으기-인터넷-o) | ① 지금 서버 | 백업, 반입 묶음 만들기 | 반나절 (내려받기 시간) |
| [B](#파트-b-인프라-담당자에게-요청) | 인프라 담당 | DNS 등록, 인증서 | 요청 후 대기 |
| [C](#파트-c-부트스트랩-vm-만들기) | ② 부트스트랩 VM | 창고 구성, Nexus | 2~3시간 |
| [D](#파트-d-새-서버-준비와-kubernetes) | ③ 모든 새 서버 | OS 설치, 창고 연결, Kubernetes | 반나절 |
| [E](#파트-e-k-paas-cp-portal-설치) | ③ 관리 노드 | CP-Portal | 1~2시간 |
| [F](#파트-f-소스-컨트롤-파이프라인-cicd-포털) | ③ 관리 노드 | 소스 컨트롤, 파이프라인, CI/CD 포털 | 2~3시간 |
| [G](#파트-g-업체앱-복원) | ③ 관리 노드 + 콘솔 | 업체·앱 복원 | 업체 수에 따라 |
| [H](#파트-h-최종-점검) | 전체 | 최종 점검 | 30분 |

> ⚠️ **파트 A를 끝내기 전에는 절대 서버를 초기화하지 않는다.** A에서 모은 것이 폐쇄망 설치의 전부다.

---

## 1. 알아 둘 용어 (5개만)

| 용어 | 뜻 |
| --- | --- |
| **반입 묶음** | 폐쇄망에 가져갈 파일 전체(이미지, 패키지, 라이브러리, 스크립트). 하나의 폴더 |
| **부트스트랩 VM** | 폐쇄망 안의 "창고" 서버. 모든 서버가 인터넷 대신 여기서 받는다 |
| **미러** | "docker.io에서 받아라"는 요청을 자동으로 창고로 돌려 주는 설정. 그래서 설정 파일의 이미지 주소를 고칠 필요가 없다 |
| **Nexus** | 앱 빌드에 필요한 라이브러리(Maven, npm, Composer) 창고 |
| **관리 노드** | 설치 명령을 실행하는 서버(kubectl이 되는 서버) |

---

## 2. 시작 전에 정할 값 (작업 메모)

아래 표를 **먼저 채워 두고** 시작한다. 이 문서의 예시 값 대신 자기 값을 넣어 실행한다.

| 항목 | 예시 | 내 값 |
| --- | --- | --- |
| 도메인 | `kpaas.example.co.kr` | |
| Ingress IP (MetalLB 풀 첫 IP) | `192.168.20.151` | |
| 내부 DNS 서버 | `192.168.20.10` | |
| 시간 서버(NTP) | `192.168.20.10` (없으면 생략) | |
| 부트스트랩 VM IP / 이름 | `192.168.20.140` / `bootstrap.kpaas.example.co.kr` | |
| Harbor·DB·Keycloak 관리자 비밀번호 | `cp-portal-vars.sh`에 넣을 값 | (메모장 X, 안전한 곳) |
| Nexus 관리자 비밀번호 | 12자 이상 | (안전한 곳) |
| SCM 관리자(scmadmin) git 비밀번호 | 지금 서버의 값 | (안전한 곳) |
| 인증서 방식 | 사설 CA(기본) / 기관 와일드카드 인증서 | |

준비물 체크:

- [ ] 반입 매체 **150GB 이상** (외장 디스크 또는 망연계 시스템)
- [ ] Rocky Linux **9.7** DVD ISO (모든 서버 OS 설치용)
- [ ] 부트스트랩 VM: Rocky 9.7, 4 CPU / 12GB / 디스크 **300GB 이상**
- [ ] 서버 목록(이름, IP)과 지금 Kubernetes 설치에 쓴 `cluster.env`

---

## 파트 A. 지금 서버에서 모으기 (인터넷 O)

지금 동작 중인 **관리 노드**에서 한다. 지금 잘 돌아가는 환경을 그대로 모으므로 빠지는 것이 없다.

### A-1. 저장소 최신으로

```bash
cd ~/Saeoll-PaaS && git pull
```

✅ 성공 확인: `Already up to date.` 또는 파일 목록이 나온다.

### A-2. 도구 설치

```bash
sudo dnf install -y skopeo podman dnf-plugins-core createrepo_c wget
```

✅ 성공 확인: `Complete!`

### A-3. 콘솔·보안 검사 이미지 새로 만들기

폐쇄망에서는 이미지를 새로 만들 수 없으므로 최신으로 만들어 둔다(보안 검사의 취약점 DB도 최신이 된다).

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script
```

```bash
./deploy-cicd-portal.sh security-image console-image
```

✅ 성공 확인: `[OK] Security scanner image pushed`, `[OK] ... cicd-console ...` (10~15분)

### A-4. 업체 데이터 백업

업체 소스 저장소, DB, 품질 관리 정책, 이미지 목록을 백업한다.

```bash
read -rsp 'scmadmin git 비밀번호: ' SCM_ADMIN_PASSWORD; echo; export SCM_ADMIN_PASSWORD
```

```bash
IMAGES=1 ./backup-before-reinstall.sh /data/backup
```

✅ 성공 확인: 마지막에 `Backup: /data/backup`. `[WARN] Not saved:`가 있으면 그 항목을 확인한다.

```bash
ls /data/backup/repos/scm /data/backup/db
```

업체 저장소 이름과 `*.sql.gz` 파일이 보여야 한다.

### A-5. 반입 묶음 만들기

시간이 오래 걸리므로(1~4시간) 접속이 끊겨도 계속되게 실행한다. `APP_SOURCES`에는 백업한 업체 저장소를 넣어 **업체 앱의 라이브러리까지** 모은다.

```bash
cd ~/Saeoll-PaaS/offline
```

```bash
nohup env APP_SOURCES="$(ls -d /data/backup/repos/scm/*.git | grep -v -- '-gitops.git' | tr '\n' ' ')" \
  ./collect-bundle.sh /data/offline-bundle > /data/collect.log 2>&1 &
```

진행 보기 (끝나면 `Ctrl+C`로 보기만 멈춘다):

```bash
tail -f /data/collect.log
```

✅ 성공 확인: 로그 마지막이 `Bundle ready: /data/offline-bundle`.

`[WARN] Missing: ...`가 있으면 → 메시지를 확인하고 그 단계만 다시 실행한다. 예: 이미지만 다시

```bash
./collect-bundle.sh /data/offline-bundle images
```

`registries not in MIRRORED_REGISTRIES` 경고가 있으면 → `offline-vars.sh`의 `MIRRORED_REGISTRIES`에 그 이름을 추가하고 `images` 단계를 다시 실행한다.

### A-6. 확인하고 반입 매체로 복사

```bash
cd /data/offline-bundle && sha256sum -c --quiet SHA256SUMS && echo 무결성OK
```

✅ 성공 확인: `무결성OK`

```bash
du -sh /data/offline-bundle /data/backup
```

두 폴더(`/data/offline-bundle`, `/data/backup`)를 반입 매체로 복사하고, 기관의 반입 절차(백신 검사, 승인)를 받는다.

> ⚠️ 여기까지 끝났고, 반입 매체의 파일을 다른 PC에서 열어 확인했다면 이제 서버를 초기화해도 된다.

---

## 파트 B. 인프라 담당자에게 요청

### B-1. DNS 등록 (내부 DNS)

| 레코드 | 값 | 용도 |
| --- | --- | --- |
| `*.kpaas.example.co.kr` A | `192.168.20.151` (Ingress IP) | 포털·Harbor·Keycloak·앱 주소 전부 |
| `bootstrap.kpaas.example.co.kr` A | `192.168.20.140` (부트스트랩 VM) | 창고 서버 (개별 레코드가 와일드카드보다 우선) |

등록 후 아무 PC에서 확인:

```bash
nslookup test123.kpaas.example.co.kr
```

✅ 성공 확인: `192.168.20.151`이 나온다(임의의 이름도 나오면 와일드카드가 맞다).

### B-2. 인증서

- **사설 CA(기본)**: 할 일 없음. 설치 후 만들어지는 `ca.crt`를 사용자 PC에 배포한다(E-6).
- **기관 와일드카드 인증서**: `*.kpaas.example.co.kr` 인증서, 개인키, 발급 CA 체인 파일 3개를 받아 둔다(E-4에서 사용).

---

## 파트 C. 부트스트랩 VM 만들기

### C-1. OS 설치

Rocky Linux 9.7 DVD로 **최소 설치**. 고정 IP `192.168.20.140`, 호스트 이름 `bootstrap`, root 비밀번호 설정.

### C-2. 반입 묶음 복사와 확인

반입 매체를 연결하고 `/data/offline-bundle`로 복사한다(예: `cp -r /run/media/.../offline-bundle /data/`).

```bash
cd /data/offline-bundle && sha256sum -c --quiet SHA256SUMS && echo 무결성OK
```

✅ 성공 확인: `무결성OK`

### C-3. 창고 구성 (패키지·파일·이미지 저장소)

```bash
cd /data/offline-bundle/scripts
```

```bash
sudo BOOTSTRAP_HOST=bootstrap.kpaas.example.co.kr ./bootstrap-server.sh /data/offline-bundle
```

이미지를 하나씩 올리므로 30분~1시간 걸린다.

✅ 성공 확인: 마지막에 `Bootstrap VM ready (N/N images)` — 앞뒤 숫자가 같아야 한다.

확인:

```bash
curl -s http://localhost:5000/v2/_catalog | head -c 300; echo
```

이미지 이름 목록(`docker.io/...`)이 보이면 된다.

### C-4. Nexus (라이브러리 창고)

```bash
sudo NEXUS_ADMIN_PASSWORD='<Nexus 관리자 비밀번호>' ./nexus-setup.sh
```

✅ 성공 확인: `Nexus ready: http://bootstrap.kpaas.example.co.kr:8081` (첫 기동 2~5분)

라이브러리 올리기:

```bash
NEXUS_ADMIN_PASSWORD='<Nexus 관리자 비밀번호>' ./nexus-load.sh /data/offline-bundle/appdeps
```

✅ 성공 확인: `maven:uploaded`, `npm:uploaded` 같은 숫자 목록. `error`가 0이어야 한다.

브라우저(폐쇄망 PC)에서 `http://bootstrap.kpaas.example.co.kr:8081` → **Browse** → `maven-public`에 라이브러리가 보이면 된다.

---

## 파트 D. 새 서버 준비와 Kubernetes

**모든 Kubernetes 서버와 관리 노드**에서 D-1 ~ D-4를 한다.

### D-1. OS 설치

Rocky Linux 9.7 DVD로 최소 설치. 고정 IP, 호스트 이름(예: `master01`, `worker01`).

### D-2. 내부 DNS 사용

연결 이름 확인:

```bash
nmcli connection show
```

(첫 줄 NAME 값, 예: `ens192`)

```bash
sudo nmcli connection modify ens192 ipv4.dns 192.168.20.10 ipv4.ignore-auto-dns yes && sudo nmcli connection up ens192
```

✅ 성공 확인:

```bash
getent hosts portal.kpaas.example.co.kr bootstrap.kpaas.example.co.kr
```

`192.168.20.151 ...`, `192.168.20.140 ...` 두 줄이 나온다.

### D-3. 창고 연결 (패키지·이미지·시간)

```bash
mkdir -p ~/offline && cd ~/offline
```

```bash
curl -fO http://bootstrap.kpaas.example.co.kr:8080/offline/node-setup.sh -fO http://bootstrap.kpaas.example.co.kr:8080/offline/offline-vars.sh
```

```bash
chmod +x node-setup.sh && sudo BOOTSTRAP_HOST=bootstrap.kpaas.example.co.kr ./node-setup.sh --ntp 192.168.20.10
```

✅ 성공 확인: `[OK] dnf: offline repositories`, `[OK] containerd: mirrors`, `[OK] podman: mirrors`, `Node ready ...`

```bash
sudo dnf install -y git && git --version
```

창고에서 패키지가 설치되면 연결이 된 것이다.

### D-4. (관리 노드만) 스크립트 받기

```bash
cd ~ && curl -fO http://bootstrap.kpaas.example.co.kr:8080/Saeoll-PaaS.bundle && git clone Saeoll-PaaS.bundle Saeoll-PaaS
```

✅ 성공 확인: `ls ~/Saeoll-PaaS` 에 `cp-portal-deployment`, `cicd-portal-deployment`, `offline` 등이 보인다.

### D-5. Kubernetes 설치

평소 쓰던 방법(`cluster.env`)으로 설치하되, 인터넷 대신 창고를 쓰게 한다.

- **kubespray로 설치하는 경우**: 관리 노드에서 설정 조각을 출력해 inventory의 `group_vars/all/offline.yml`에 붙여 넣는다.

```bash
cd ~/Saeoll-PaaS/offline && BOOTSTRAP_HOST=bootstrap.kpaas.example.co.kr ./node-setup.sh --kubespray
```

  출력의 안내대로 `inventory/sample/group_vars/all/offline.yml`의 `*_download_url` 줄도 복사해 주석(`#`)을 지운다.
- **다른 설치 도구인 경우**: 그 도구가 바이너리를 `http://bootstrap.kpaas.example.co.kr:8080/files/kubespray/...`에서 받도록 설정한다.
  이미지는 D-3의 미러가 처리하므로 바꾸지 않는다.

✅ 성공 확인 (관리 노드):

```bash
kubectl get nodes
```

모든 노드가 `Ready`.

```bash
sudo crictl pull docker.io/library/busybox:1.36
```

(아무 노드에서) `Image is up to date` → 이미지 미러가 동작한다.

---

## 파트 E. K-PaaS (CP-Portal) 설치

여기부터는 **관리 노드**에서 한다.

### E-1. 반입 묶음을 관리 노드로

설치에 필요한 파일(도구, 차트, Harbor에 올릴 이미지)을 `/opt/offline`에 둔다. 반입 매체를 연결하거나 부트스트랩 VM에서 복사한다:

```bash
sudo mkdir -p /opt/offline && sudo chown $USER /opt/offline
```

```bash
scp -r root@bootstrap.kpaas.example.co.kr:/data/offline-bundle/{files,charts,images} /opt/offline/
```

### E-2. 도구 설치 (kubectl, helm, step, istioctl)

```bash
cd ~/Saeoll-PaaS/cp-portal-deployment/istio_mc && OFFLINE_FILES=/opt/offline/files ./install_tools.sh
```

✅ 성공 확인: 끝에 kubectl, helm, step, istioctl 버전이 나온다.

### E-3. 차트와 플러그인 놓기

```bash
mkdir -p ~/Saeoll-PaaS/cp-portal-deployment/charts ~/Saeoll-PaaS/cp-pipeline-deployment/charts
```

```bash
cp /opt/offline/charts/*.tgz ~/Saeoll-PaaS/cp-portal-deployment/charts/ && cp /opt/offline/charts/*.tgz ~/Saeoll-PaaS/cp-pipeline-deployment/charts/
```

```bash
tar xzf /opt/offline/files/helm-push-plugin.tar.gz -C /opt/offline/files
```

### E-4. 설정 (도메인과 비밀번호)

```bash
cd ~/Saeoll-PaaS/cp-portal-deployment/script
```

```bash
./configure-from-cluster-env.sh /path/to/cluster.env kpaas.example.co.kr
```

✅ 성공 확인: `HOST_DOMAIN=kpaas.example.co.kr`, `INGRESS_LB_IP=192.168.20.151`

비밀번호를 넣는다:

```bash
vi cp-portal-vars.sh
```

| 변수 | 넣을 값 |
| --- | --- |
| `REPOSITORY_PASSWORD` | Harbor 관리자 비밀번호 |
| `DATABASE_USER_PASSWORD`, `DATABASE_TERRAMAN_PASSWORD` | DB 비밀번호 |
| `KEYCLOAK_ADMIN_PASSWORD` | Keycloak 관리자 비밀번호 |
| (기관 인증서만) `TLS_CERT_AUTO_GENERATED="N"`, `TLS_CERT_PATH`, `TLS_KEY_PATH`, `TLS_CA_CERT_PATH` | B-2에서 받은 파일 경로 |

`K_PAAS_REGISTRY`는 **바꾸지 않는다**(미러가 처리).

```bash
chmod 600 cp-portal-vars.sh
```

### E-5. 설치

```bash
HELM_PUSH_PLUGIN=/opt/offline/files/helm-push ./deploy-cp-portal.sh 2>&1 | tee cp-portal-deploy.log
```

설치 앞부분에서 DNS를 검사한다:

```text
[OK] DNS (this node): portal.kpaas.example.co.kr -> 192.168.20.151
[OK] DNS (cluster/CoreDNS): portal.kpaas.example.co.kr -> 192.168.20.151
```

`[ERROR] DNS ...`가 나오면 → [문제 해결](#문제-해결)의 DNS 항목.

✅ 성공 확인: 오류 없이 끝나고 브라우저에서 `https://portal.kpaas.example.co.kr` 로그인 화면이 열린다.

### E-6. 사용자 PC에 인증서 신뢰 (사설 CA인 경우)

`~/Saeoll-PaaS/cp-portal-deployment/certs/ca.crt`를 사용자 PC에 복사해 설치한다.
Windows: 파일 더블클릭 → **인증서 설치** → 로컬 컴퓨터 → **신뢰할 수 있는 루트 인증 기관**.

> ⚠️ 같은 폴더의 `ca.key`는 절대 복사·배포하지 않는다.

---

## 파트 F. 소스 컨트롤, 파이프라인, CI/CD 포털

### F-1. 포털 이미지를 Harbor로

```bash
cd ~/Saeoll-PaaS/offline && ./load-to-harbor.sh /opt/offline
```

✅ 성공 확인: 마지막에 **CI/CD 포털 설정 값** 목록이 나온다. 이 출력은 F-4에서 그대로 쓰므로 복사해 둔다.

### F-2. 소스 컨트롤

```bash
cd ~/Saeoll-PaaS/cp-source-control-deployment/script && ./fetch-cp-source-control.sh /opt/offline/files/cp-source-control-deployment-*.tar.gz
```

```bash
./deploy-cp-source-control.sh 2>&1 | tee cp-source-control-deploy.log
```

✅ 성공 확인: `https://scm.kpaas.example.co.kr` 접속, 그리고

```bash
./check-cp-source-control.sh
```

이후 `scmadmin`으로 `https://scm.kpaas.example.co.kr`에 로그인해 **내정보 관리**에서 git 비밀번호를 설정한다(F-5에서 사용).

### F-3. 파이프라인 (사용하는 경우만)

```bash
cd ~/Saeoll-PaaS/cp-pipeline-deployment/script && ./deploy-cp-pipeline.sh 2>&1 | tee cp-pipeline-deploy.log
```

### F-4. CI/CD 포털 설정

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script && vi cicd-vars.sh
```

F-1에서 출력된 값과 아래 값을 넣는다(숫자는 F-1 출력 그대로):

```bash
CICD_SOURCES=${CICD_SOURCES:-${CICD_SOURCE:-"scm gitlab"}}
CICD_CHART_DIR="/opt/offline/charts"
JENKINS_CHART_VERSION="..."
ARGOCD_CHART_VERSION="..."
GITLAB_RUNNER_CHART_VERSION="..."
JENKINS_IMAGE="harbor.kpaas.example.co.kr/cicd-mirror/jenkins:...-plugins"
CICD_BASE_REGISTRY="harbor.kpaas.example.co.kr/base-images"
CONSOLE_IMAGE_TAG="..."
SECURITY_IMAGE_TAG="..."
CICD_NEXUS_URL="http://bootstrap.kpaas.example.co.kr:8081"
```

`vi`에서 해당 변수 줄을 찾아 값만 바꾸고(`/변수이름`으로 검색), 없는 변수는 맨 아래에 추가한다.

### F-5. CI/CD 포털 설치

```bash
read -rsp 'scmadmin git 비밀번호: ' SCM_ADMIN_PASSWORD; echo; export SCM_ADMIN_PASSWORD
```

```bash
./deploy-cicd-portal.sh preflight
```

✅ 성공 확인: `[OK] Preflight passed`

```bash
./deploy-cicd-portal.sh 2>&1 | tee cicd-portal-deploy.log
```

Jenkins, GitLab, GitLab Runner, Argo CD가 차례로 설치된다(GitLab 첫 기동 5~15분). 실패하면 원인을 고치고 **같은 명령을 다시 실행**한다.

✅ 성공 확인: 마지막에 `Jenkins: https://jenkins...`, `GitLab ...`, `Argo CD: https://argocd...` 주소가 나온다.

**Jenkins API 토큰 등록 (1회)**:
1. `https://jenkins.kpaas.example.co.kr` → K-PaaS SSO로 `admin` 로그인
2. 오른쪽 위 사용자 이름 → **Security** → **Add new Token** → 이름 `cicd-portal` → **Generate** → 값 복사

```bash
read -rsp 'Jenkins API 토큰: ' JENKINS_API_TOKEN; echo
```

```bash
JENKINS_USER=admin JENKINS_API_TOKEN="$JENKINS_API_TOKEN" ./deploy-cicd-portal.sh jenkins-token
```

✅ 성공 확인: `[OK] Jenkins API token stored for admin`

**보안 검사와 콘솔** (이미지는 이미 Harbor에 있으므로 `console-image`, `security-image`는 실행하지 않는다):

```bash
./deploy-cicd-portal.sh security console 2>&1 | tee cicd-console-deploy.log
```

### F-6. 점검

```bash
./check-cicd-portal.sh
```

✅ 성공 확인: 마지막 줄 `[RESULT] OK`. 브라우저에서 확인:

| 주소 | 확인할 것 |
| --- | --- |
| `https://cicd.kpaas.example.co.kr` | `admin` 로그인, 오른쪽 위 **운영 관리자**, 메뉴 **품질 관리** |
| `https://jenkins.kpaas.example.co.kr` | 로그인, 플러그인을 내려받지 않고 바로 뜸 |
| `https://gitlab.kpaas.example.co.kr` | K-PaaS SSO 로그인 |
| `https://argocd.kpaas.example.co.kr` | **LOG IN VIA K-PAAS SSO** |

---

## 파트 G. 업체·앱 복원

백업을 관리 노드의 `~/backup`에 복사한 뒤, 먼저 **복원 계획**을 본다(아무것도 바꾸지 않는다).

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script && ./restore-after-reinstall.sh ~/backup
```

계획에 나온 순서대로 한다.

| 순서 | 할 일 | 어떻게 |
| --- | --- | --- |
| 1 | 업체 등록 | 콘솔 **업체 등록** — 계획에 나온 업체 ID·소스 방식·네임스페이스 방식 그대로. 구성원은 **신규 계정 만들기**(임시 비밀번호가 화면에 한 번 표시) |
| 2 | 소스 저장소 | `./restore-after-reinstall.sh ~/backup --repos` (SCM_ADMIN_PASSWORD 필요) |
| 3 | 앱 추가 | 콘솔 **앱 추가** — 같은 앱 ID·유형, **시작 소스를 넣지 않음** 체크, 저장소 이름이 `<업체>-<앱>`이 아니면 **기존 SCM 저장소 이름** 입력, **기존 CI 파일 교체** 체크(라이브러리 창고 연결) |
| 4 | DB 연결 → 복원 | 콘솔 **DB 연결**(전과 같은 방식) → `./restore-after-reinstall.sh ~/backup --db` |
| 5 | 빌드 | dev는 자동(또는 콘솔 **빌드 실행**). 운영은 `images/running.txt`의 태그로 **릴리스** → **prod Sync** |
| 6 | 품질 관리 정책 | `./restore-after-reinstall.sh ~/backup --security` |

✅ 성공 확인: 앱의 dev 빌드 로그에 `[cicd-deps] dependencies from http://bootstrap...:8081` 이 나오고 빌드가 성공, dev 주소가 열린다.

> 기존 앱의 **Dockerfile**은 업체 소스라 자동으로 바뀌지 않는다. 빌드가 Dockerfile 안에서 라이브러리를 못 받으면,
> `cicd-portal-deployment/starters/<유형>/Dockerfile`의 `ARG NEXUS_URL`, `cicd-deps.sh` 줄을 업체 Dockerfile에 반영한다.

업체에 알릴 것: 새 주소(`https://cicd.kpaas.example.co.kr`, `https://scm.kpaas.example.co.kr`), 임시 비밀번호, git 주소 변경
(`git remote set-url origin https://scm-manager.kpaas.example.co.kr/scm/git/<저장소>`), (사설 CA) `ca.crt` 설치.

---

## 파트 H. 최종 점검

- [ ] 사용자 PC: `https://portal.<도메인>`, `https://cicd.<도메인>` — 인증서 경고 없음, 주소에 IP 없음
- [ ] 모든 노드: `getent hosts harbor.<도메인>` → Ingress IP
- [ ] 아무 노드: `sudo crictl pull docker.io/library/busybox:1.36` 성공
- [ ] 콘솔 **시스템 점검** 성공
- [ ] 업체 앱 dev 빌드 성공 (`[cicd-deps]` 줄 확인), dev 주소 접속
- [ ] 복원한 DB 데이터(게시글 등) 확인
- [ ] Nexus(`http://bootstrap...:8081`), 부트스트랩 VM `/srv/offline` 백업 일정 등록
- [ ] 반입 매체·백업 폴더는 비밀번호가 들어 있으므로 안전한 곳에 보관

---

## 문제 해결

| 증상 | 확인 | 해결 |
| --- | --- | --- |
| `[ERROR] DNS (this node) ... not found` | `getent hosts portal.<도메인>` | B-1 DNS 등록, D-2 서버 DNS 설정 |
| `dns-check-숫자...` 만 실패 | 개별 레코드만 등록됨 | `*.도메인` 와일드카드로 등록 |
| `[ERROR] DNS (cluster/CoreDNS)` | Pod가 내부 DNS를 모름 | [도메인 가이드 3-3](install-with-domain.md#3-3-kubernetes-설치와-클러스터-dns-확인)의 CoreDNS 설정 |
| Pod `ImagePullBackOff` | `kubectl describe pod <이름>`의 이미지 이름, 노드에서 `sudo crictl pull <이미지>` | 그 이미지가 묶음에 없으면 인터넷 쪽에서 `offline-vars.sh`의 `EXTRA_IMAGES`에 넣고 `collect-bundle.sh <묶음> images` → 반입 → `bootstrap-server.sh` 재실행 |
| `node-setup.sh` 실행 시 `does not answer` | `curl http://bootstrap...:8080/README.txt` | 부트스트랩 VM 방화벽(8080, 5000, 8081), C-3 재실행 |
| `dnf install` 실패 | `dnf repolist` | D-3 재실행 |
| Jenkins가 플러그인을 받으려다 실패 | `cicd-vars.sh`의 `JENKINS_IMAGE` | F-4 값 확인 후 `./deploy-cicd-portal.sh jenkins` |
| 앱 빌드 `Could not find artifact` / npm `404` | Nexus에 그 라이브러리가 없음 | 인터넷 쪽에서 `collect-app-deps.sh <출력> <앱 소스>` → 반입 → `nexus-load.sh <출력>` |
| 빌드 로그에 `[cicd-deps]` 줄이 없음 | `CICD_NEXUS_URL`, 앱의 `cicd-deps.sh` | F-4 확인, 콘솔 앱 추가를 **기존 CI 파일 교체**로 다시 실행 |
| 브라우저 인증서 경고 | PC 인증서 | E-6 |

**도움을 요청할 때 보낼 것**: 실패한 단계 이름(예: F-5), 명령, 로그 파일(`*.log`)의 마지막 50줄.

```bash
tail -50 cicd-portal-deploy.log
```

---

## 부록. 나중에 업데이트할 때 (정기 반입)

설치 후에는 인터넷 연결 클러스터가 없으므로, **인터넷 PC(Rocky 9.7)**에 이 저장소를 받아 이전 목록으로 새 묶음을 만든다.

```bash
IMAGES_FROM=/data/offline-bundle/images/images.txt ./collect-bundle.sh /data/offline-bundle-2 images files rpms appdeps repo
```

반입 후 부트스트랩 VM에서:

```bash
sudo ./bootstrap-server.sh /data/offline-bundle-2
```

```bash
NEXUS_ADMIN_PASSWORD='...' ./nexus-load.sh /data/offline-bundle-2/appdeps
```

권장 주기: 보안 검사 DB(스캐너 이미지)·OS 보안 패치 **월 1회**, 업체가 새 라이브러리를 요청할 때 수시.
