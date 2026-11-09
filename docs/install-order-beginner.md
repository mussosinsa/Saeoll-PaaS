# 설치 순서와 명령 정리 (초보자용)

K-PaaS 포털부터 CI/CD 포털까지 **설치 순서, 명령, 실행 폴더**를 한곳에 정리했다.
위에서부터 한 단계씩 실행하고, **✅ 성공 확인**이 맞으면 다음 단계로 넘어간다.

```text
0. 준비 (저장소, 도구)
① cp-portal-deployment           필수 — Keycloak, Harbor, MariaDB, 인증서, 도메인
② cp-source-control-deployment   SCM + Jenkins 방식이면 필수 (GitLab만 쓰면 생략)
③ cicd-portal-deployment         Jenkins · GitLab · Argo CD · 콘솔 · 보안 검사
   ※ cp-pipeline-deployment(K-PaaS 기본 파이프라인)는 선택 — ① 이후 아무 때나 설치하거나 설치하지 않아도 된다
```

- 모든 명령은 **관리 노드(마스터 노드, `kubectl`이 되는 서버)** 에서 실행한다.
- 저장소 위치는 `~/Saeoll-PaaS` 기준이다. 다른 곳에 받았다면 그 경로로 바꿔 읽는다.
- 각 단계의 **📁 실행 위치**로 먼저 이동한 뒤 명령을 실행한다.
- 인터넷이 차단된 폐쇄망이면 [폐쇄망 설치 따라하기](offline-install-beginner.md)를 따른다.

---

## 0. 준비 (처음 한 번)

### 0-1. 저장소 받기

📁 홈 폴더

```bash
cd ~ && git clone -b claude/stoic-edison-jc393z https://github.com/mussosinsa/Saeoll-PaaS.git
```

이미 받았다면 최신으로:

```bash
cd ~/Saeoll-PaaS && git pull
```

### 0-2. 기본 도구

📁 아무 곳

```bash
sudo dnf install -y git curl python3 podman wget
```

### 0-3. kubectl · helm · step · istioctl

📁 `~/Saeoll-PaaS/cp-portal-deployment/istio_mc`

```bash
cd ~/Saeoll-PaaS/cp-portal-deployment/istio_mc
```

```bash
chmod +x install_tools.sh && ./install_tools.sh
```

✅ 성공 확인: 끝에 kubectl, helm, step, istioctl 버전이 나온다.

```bash
kubectl get nodes
```

✅ 성공 확인: 모든 노드가 `Ready`.

> **RKE2 클러스터**라면 먼저 실행한다:
> `export PATH=$PATH:/var/lib/rancher/rke2/bin KUBECONFIG=/etc/rancher/rke2/rke2.yaml`

---

## ① cp-portal-deployment (K-PaaS 포털)

📁 **실행 위치: `~/Saeoll-PaaS/cp-portal-deployment/script`**

```bash
cd ~/Saeoll-PaaS/cp-portal-deployment/script
```

### ①-1. 설정 자동 채우기

Kubernetes 설치 때 쓴 `cluster.env` 경로와 **도메인**을 넣는다.

```bash
chmod +x *.sh && ./configure-from-cluster-env.sh /path/to/cluster.env kpaas.example.co.kr
```

✅ 성공 확인: `HOST_DOMAIN=kpaas.example.co.kr`, `INGRESS_LB_IP=...` 가 출력된다.

> 도메인을 생략하면 `IP.nip.io` 주소가 된다(주소에 IP가 보이므로 시험용). 도메인은 내부 DNS에
> `*.kpaas.example.co.kr → Ingress IP` 와일드카드 레코드가 있어야 한다([도메인 가이드](install-with-domain.md)).

### ①-2. 비밀번호 입력

```bash
vi cp-portal-vars.sh
```

| 바꿀 변수 | 내용 |
| --- | --- |
| `REPOSITORY_PASSWORD` | Harbor 관리자 비밀번호 |
| `DATABASE_USER_PASSWORD`, `DATABASE_TERRAMAN_PASSWORD` | DB 비밀번호 |
| `KEYCLOAK_ADMIN_PASSWORD` | Keycloak 관리자 비밀번호 |

```bash
chmod 600 cp-portal-vars.sh
```

### ①-3. 설치 (30~60분)

```bash
./deploy-cp-portal.sh 2>&1 | tee cp-portal-deploy.log
```

### ①-4. 확인

```bash
./check-cp-portal.sh
```

```bash
kubectl get pods -A | grep -v -E 'Running|Completed'
```

✅ 성공 확인:
- 두 번째 명령은 제목 줄만 나온다(문제 있는 Pod 없음).
- 브라우저 `https://portal.<도메인>` 에 `admin`으로 로그인된다.

### ①-5. 사용자 PC 인증서 (사설 CA인 경우)

`~/Saeoll-PaaS/cp-portal-deployment/certs/ca.crt`를 사용자 PC에 복사해 **신뢰할 수 있는 루트 인증 기관**에 설치한다.

> ⚠️ 같은 폴더의 `ca.key`는 절대 배포하지 않는다.

---

## ② cp-source-control-deployment (소스 저장소)

> GitLab만 쓸 경우(`CICD_SOURCES="gitlab"`) 이 단계는 건너뛴다.

📁 **실행 위치: `~/Saeoll-PaaS/cp-source-control-deployment/script`**

```bash
cd ~/Saeoll-PaaS/cp-source-control-deployment/script
```

### ②-1. 설치 패키지 받기

```bash
chmod +x *.sh && ./fetch-cp-source-control.sh
```

> 인터넷이 안 되면 받아 둔 파일 경로를 붙인다:
> `./fetch-cp-source-control.sh /경로/cp-source-control-deployment-v1.6.0.tar.gz`

### ②-2. 설치 (10~20분)

```bash
./deploy-cp-source-control.sh 2>&1 | tee cp-source-control-deploy.log
```

### ②-3. 확인

```bash
./check-cp-source-control.sh
```

✅ 성공 확인: 브라우저 `https://scm.<도메인>` 이 열린다.

### ②-4. 관리자 git 비밀번호 설정 (③에서 필요)

브라우저에서 `https://scm.<도메인>` 에 `scmadmin`으로 로그인 → 오른쪽 위 → **내정보 관리** → **git 비밀번호** 설정.
이 값은 Keycloak 비밀번호와 다르다. 기억해 둔다.

비밀번호를 터미널에 입력해 두고(셸 기록에 남지 않는다) 다시 확인한다:

```bash
read -rsp 'scmadmin git 비밀번호: ' SCM_ADMIN_PASSWORD; echo; export SCM_ADMIN_PASSWORD
```

```bash
./check-cp-source-control.sh
```

✅ 성공 확인: 관리자 로그인 항목까지 OK.

---

## ③ cicd-portal-deployment (Jenkins · GitLab · Argo CD · 콘솔 · 보안 검사)

📁 **실행 위치: `~/Saeoll-PaaS/cicd-portal-deployment/script`**

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script
```

### ③-1. 설정

처음에는 소스 방식만 정한다(나머지는 기본값).

```bash
vi cicd-vars.sh
```

`CICD_SOURCES` 줄을 쓸 방식으로 바꾼다:

| 값 | 의미 |
| --- | --- |
| `"scm"` | 소스 컨트롤(②) + Jenkins |
| `"gitlab"` | GitLab만 (② 불필요) |
| `"scm gitlab"` | 둘 다 (업체마다 선택) |

```bash
CICD_SOURCES=${CICD_SOURCES:-${CICD_SOURCE:-"scm"}}
```

### ③-2. 사전 점검

새 터미널이면 ②-4의 `read` 명령으로 `SCM_ADMIN_PASSWORD`를 다시 입력한 뒤:

```bash
chmod +x *.sh && ./deploy-cicd-portal.sh preflight
```

✅ 성공 확인: `[OK] Preflight passed`.
`[WARN]`, `[FAIL]`이 있으면 메시지대로 고치고 다시 실행한다. (도구, StorageClass, 인증서, Keycloak, Ingress, 소스 컨트롤 로그인,
Pod Security, 노드의 Harbor 이미지 받기까지 점검한다.)

### ③-3. Jenkins · GitLab · Argo CD 설치 (20~40분)

```bash
./deploy-cicd-portal.sh 2>&1 | tee cicd-portal-deploy.log
```

✅ 성공 확인: 마지막에 `Jenkins: https://jenkins...`, `Argo CD: https://argocd...` (GitLab 포함 시 GitLab) 주소가 나온다.

> 실패하면 원인을 고치고 **같은 명령을 다시 실행**한다. 이미 된 부분은 그대로 둔다.
> Jenkins 첫 기동은 플러그인 다운로드로 5~15분, GitLab 첫 기동은 5~15분 걸린다.

### ③-4. Jenkins API 토큰 등록 (scm 방식, 1회)

1. 브라우저 `https://jenkins.<도메인>` → K-PaaS SSO로 `admin` 로그인
2. 오른쪽 위 이름 → **Security** → **Add new Token** → 이름 `cicd-portal` → **Generate** → 값 복사(다시 볼 수 없다)

```bash
read -rsp 'Jenkins API 토큰: ' JENKINS_API_TOKEN; echo
```

```bash
JENKINS_USER=admin JENKINS_API_TOKEN="$JENKINS_API_TOKEN" ./deploy-cicd-portal.sh jenkins-token
```

✅ 성공 확인: `[OK] Jenkins API token stored for admin`

### ③-5. 콘솔 · 보안 검사 설치 (15~20분)

`sudo` 비밀번호를 물으면 입력한다(이미지 빌드).

```bash
./deploy-cicd-portal.sh console-image security-image security console 2>&1 | tee cicd-console-deploy.log
```

> 폐쇄망이면 이미지가 이미 Harbor에 있으므로 `./deploy-cicd-portal.sh security console`만 실행한다.

### ③-6. 최종 점검

```bash
./check-cicd-portal.sh
```

✅ 성공 확인: 마지막 줄 `[RESULT] OK`. 브라우저 확인:

| 주소 | 확인할 것 |
| --- | --- |
| `https://cicd.<도메인>` | `admin` 로그인, 오른쪽 위 **운영 관리자** 표시, 메뉴 **품질 관리** |
| `https://jenkins.<도메인>` | 로그인됨 |
| `https://argocd.<도메인>` | **LOG IN VIA K-PAAS SSO**로 로그인 |
| `https://gitlab.<도메인>` (GitLab 포함 시) | SSO 로그인 |

설치 끝. 업체 등록과 앱 추가는 [CI/CD 콘솔 운영 관리자 가이드](../cicd-portal-deployment/docs/console-admin-guide.md)를 따른다.

---

## 한눈에 보기

| 순서 | 📁 실행 위치 | 명령 (순서대로) |
| --- | --- | --- |
| 0 | `~/Saeoll-PaaS/cp-portal-deployment/istio_mc` | `./install_tools.sh` |
| ① | `~/Saeoll-PaaS/cp-portal-deployment/script` | `./configure-from-cluster-env.sh <cluster.env> <도메인>` → `vi cp-portal-vars.sh` → `./deploy-cp-portal.sh` → `./check-cp-portal.sh` |
| ② | `~/Saeoll-PaaS/cp-source-control-deployment/script` | `./fetch-cp-source-control.sh` → `./deploy-cp-source-control.sh` → `./check-cp-source-control.sh` → scmadmin git 비밀번호 설정 |
| ③ | `~/Saeoll-PaaS/cicd-portal-deployment/script` | `vi cicd-vars.sh` → `./deploy-cicd-portal.sh preflight` → `./deploy-cicd-portal.sh` → `... jenkins-token` → `... console-image security-image security console` → `./check-cicd-portal.sh` |
| (선택) | `~/Saeoll-PaaS/cp-pipeline-deployment/script` | `./deploy-cp-pipeline.sh` — K-PaaS 기본 파이프라인이 필요할 때만 |

## cp-pipeline-deployment는 설치해야 하나?

**필수가 아니다.** CI/CD 포털은 자체 Jenkins·GitLab·Argo CD를 쓰고, 소스 컨트롤도 cp-pipeline을 필요로 하지 않는다.

| 설치하는 경우 | 설치하지 않는 경우 (권장 기본) |
| --- | --- |
| 기존 `pipeline.<도메인>` 화면으로 배포하던 업체를 당분간 유지 | 새로 시작하거나 CI/CD 포털로 옮길 때 |
| SonarQube 코드 품질 지표가 꼭 필요 | 자원 절약(메모리 4Gi+, 저장소 28Gi+), 보안 부담 감소(2017년 Jenkins, privileged 실행) |

설치하지 않으면 CP-Portal의 파이프라인 메뉴는 열리지 않는다(기능 영향 없음).

## 문제가 생기면

실패한 단계 번호(예: ③-3)와 로그 파일의 마지막 50줄을 함께 전달한다.

```bash
tail -50 cicd-portal-deploy.log
```
