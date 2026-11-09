# CI/CD 포털 배포에 필요한 기존 환경 정보와 환경 변수

`cicd-portal-deployment`는 **이미 설치된 Kubernetes + K-PaaS(CP-Portal)** 위에 올라간다.
이 문서는 ① 기존 환경에서 무엇을 가져다 쓰는지, ② 새 환경에 배포할 때 어떤 파일과 환경 변수를 설정하는지 정리한 것이다.
설치 순서는 [설치 순서 (초보자용)](install-order-beginner.md), 폐쇄망은 [폐쇄망 설치](install-offline.md)를 본다.

```
cp-portal-deployment/script/cp-portal-vars.sh  ─┐  (도메인, Keycloak·Harbor 관리자, MariaDB, StorageClass)
cp-portal-deployment/certs/ca.crt               ─┤  (K-PaaS CA)
cicd-portal-deployment/script/cicd-vars.sh      ─┼─► lib.sh load_portal_vars ─► deploy-cicd-portal.sh, 콘솔, 스크립트
실행할 때의 환경 변수 (SCM_ADMIN_PASSWORD 등)     ─┘
```

CI/CD 포털은 CP-Portal 설정 파일을 **다시 읽어서** 쓴다. 같은 값을 `cicd-vars.sh`에 또 적지 않는다.

---

## 1. 기존 환경에서 가져오는 정보

### 1-1. 파일 (관리 노드의 `~/Saeoll-PaaS` 아래)

| 파일 | 쓰는 값 | 없거나 틀리면 |
|---|---|---|
| `cp-portal-deployment/script/cp-portal-vars.sh` | 아래 1-2 표 | `lib.sh`가 `HOST_DOMAIN is not configured` 등으로 멈춤 |
| `cp-portal-deployment/certs/ca.crt` | K-PaaS 사설 CA. API 호출(Keycloak, Harbor, SCM, Jenkins) 검증, 빌드 Pod의 신뢰 인증서(Secret `cicd-ca`) | preflight `K-PaaS CA certificate not found`, `CERTIFICATE_VERIFY_FAILED` |

> CP-Portal을 **다른 폴더나 다른 서버에서** 설치했다면 그때 쓴 `cp-portal-vars.sh`와 `certs/ca.crt`를 위 위치로 복사한다.
> 위치를 바꾸려면 `PORTAL_DIR`(cp-portal-deployment 폴더), `PORTAL_VARS`(vars 파일), `CA_FILE`(CA)을 환경 변수로 지정한다.
> **`ca.key`(CA 개인 키)는 필요 없다. 복사하지 않는다.**

### 1-2. `cp-portal-vars.sh`에서 읽는 값

| 변수 | 용도 | 확인 방법 |
|---|---|---|
| `HOST_DOMAIN` | 모든 주소: `jenkins.`, `argocd.`, `gitlab.`, `cicd.`, `scm.`, `scm-manager.`, `harbor.`, `keycloak.` + 도메인 | `kubectl -n cp-portal get ingress` 의 호스트 |
| `K8S_STORAGECLASS` | Jenkins·GitLab·Argo CD·앱 DB 볼륨 | `kubectl get storageclass` 목록에 있어야 함 |
| `KEYCLOAK_URL`, `KEYCLOAK_CP_REALM` | 로그인(OIDC), 클라이언트·그룹 생성 (realm `cp-realm`) | `https://keycloak.<도메인>/realms/cp-realm` 이 열림 |
| `KEYCLOAK_ADMIN_USERNAME`, `KEYCLOAK_ADMIN_PASSWORD` | Keycloak 관리 API (클라이언트 `cicd-*`, 그룹 `cicd-admins`, `cicd-<업체>`, 사용자) | Keycloak 관리 화면 로그인 |
| `REPOSITORY_URL`, `REPOSITORY_USERNAME`, `REPOSITORY_PASSWORD` | Harbor: 콘솔·스캐너 이미지, 업체 프로젝트, robot 계정, 이미지 보안 정책 | Harbor 화면 admin 로그인 |
| `DATABASE_URL`, `DATABASE_USER_PASSWORD` | K-PaaS MariaDB (공유 DB 연결, `scm.` 목록 DB `cp_scm` 등록·권한) | `kubectl -n mariadb get pod` |

> 설치 후 Harbor·Keycloak 관리자 비밀번호를 화면에서 바꿨다면 **이 파일도 같은 값으로 고친다**(401 오류의 가장 흔한 원인).

### 1-3. 클러스터에 있어야 하는 것

| 항목 | 기본 이름 | 확인 명령 | 비고 |
|---|---|---|---|
| Kubernetes 접근 | — | `kubectl get nodes` | RKE2: `export PATH=$PATH:/var/lib/rancher/rke2/bin KUBECONFIG=/etc/rancher/rke2/rke2.yaml` |
| IngressClass | `nginx` | `kubectl get ingressclass` | 다르면 `cicd-vars.sh`의 `INGRESS_CLASS_NAME` |
| 와일드카드 TLS Secret | `cp-portal/<도메인>-tls` | `kubectl -n cp-portal get secret <도메인>-tls` | CP-Portal이 만든 것을 각 네임스페이스로 복사해 씀 |
| Keycloak | `keycloak` 네임스페이스 | `kubectl -n keycloak get pod` | Running |
| Harbor | `harbor` 네임스페이스 | `kubectl -n harbor get pod` | 노드가 Harbor에서 이미지를 받을 수 있어야 함(CA 설치) |
| MariaDB | `mariadb` 네임스페이스 | `kubectl -n mariadb get pod` | |
| 소스 컨트롤 (scm 사용 시) | `cp-source-control` | `kubectl -n cp-source-control get pod` | SCM-Manager `cp-source-control-manager-service:8080/scm` |
| DNS | `*.<도메인>` → Ingress IP | `getent hosts jenkins.<도메인>` | nip.io면 자동 |
| CP-Portal Role | `cp-init-role`, `cp-admin-role` | `kubectl get roles -A \| grep cp-` | 업체 네임스페이스를 CP-Portal 사용자 화면에서 고르게 함 (`portal-roles.sh`) |

### 1-4. 사람이 알고 있어야 하는 값 (파일에 없음)

| 값 | 어디서 | 언제 필요 |
|---|---|---|
| **SCM 관리자 git 비밀번호** (`scmadmin`) | `https://scm.<도메인>` → `scmadmin` 로그인 → 내정보 관리에서 정한 **git 비밀번호**(Keycloak 비밀번호 아님) | scm 업체 사용 시: preflight, 콘솔 배포, 업체 등록, 앱 추가 |
| **CI 계정 git 비밀번호** (`jenkins-<업체>`) | 그 계정으로 `scm.` 첫 로그인 후 내정보 관리 | 업체 등록 2차 |
| **Jenkins API 토큰** | Jenkins 로그인(`cicd-admins` 구성원) → 사용자 → Security → API Token | Jenkins 설치 직후 1회 (`jenkins-token` 단계) |

### 1-5. 한 번에 확인

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script && ./deploy-cicd-portal.sh preflight
```

위 1-1~1-3 항목과 Ingress 컨트롤러, Pod Security, 노드별 Harbor 이미지 받기, 노드 여유를 점검한다. `[FAIL]`이 없어야 한다.

---

## 2. 새 환경에 배포할 때 설정

### 2-1. 순서

1. 새 환경에 K-PaaS 설치: ① `cp-portal-deployment` → ② `cp-source-control-deployment`(scm 사용 시).
   → `cp-portal-vars.sh`, `certs/ca.crt`가 **새 환경 값**으로 생긴다. 다른 서버에서 설치했으면 관리 노드로 복사.
2. `cicd-portal-deployment/script/cicd-vars.sh` 수정 (2-2).
3. 실행할 때의 환경 변수 입력 (2-3).
4. `./deploy-cicd-portal.sh preflight` → `./deploy-cicd-portal.sh` → `jenkins-token` → `console-image console` → (선택) `security-image security`.

> 기존 환경의 `cicd-vars.sh`를 그대로 복사해도 된다. 단 **도메인·IP·Harbor 주소가 들어간 값**(아래 ★)은 새 환경 값으로 바꾼다.
> 비밀번호·토큰은 `cicd-vars.sh`에 적지 않는다(2-3처럼 실행할 때 입력).

### 2-2. `cicd-vars.sh` — 보통 바꾸는 값

| 변수 | 기본값 | 바꾸는 경우 |
|---|---|---|
| `HOST_DOMAIN` | `"{host domain}"` | 그대로 두면 CP-Portal 값 사용. 다른 도메인을 쓸 때만 |
| `K8S_STORAGECLASS` | `""` | 비우면 CP-Portal 값. 그 값이 실제 목록에 없을 때 (예: `"nfs-client"`) |
| `CICD_SOURCES` | `"scm gitlab"` | 설치할 소스. K-PaaS SCM + Jenkins만: `"scm"`, GitLab만: `"gitlab"` |
| `INGRESS_CLASS_NAME` | `"nginx"` | IngressClass 이름이 다를 때 |
| `CP_PORTAL_NAMESPACE` | `"cp-portal"` | TLS Secret이 다른 네임스페이스에 있을 때 |
| `SCM_NAMESPACE`, `SCM_INTERNAL_URL` | `cp-source-control`, `http://cp-source-control-manager-service...:8080/scm` | 소스 컨트롤을 다른 이름으로 설치했을 때 |
| `SCM_ADMIN_USER` | `scmadmin` | SCM 관리자 ID가 다를 때 |
| `KEYCLOAK_ADMIN_GROUP` | `cicd-admins` | 운영 관리자 그룹 이름 |
| `CICD_POD_SECURITY` | `baseline` | CI 네임스페이스 Pod Security (RKE2 CIS는 기본 restricted라 필요) |
| `VENDOR_POD_SECURITY` | `""` | 업체 네임스페이스 Pod Security (root 이미지를 쓰면 `baseline`) |
| `PORTAL_ROLES` | `cp-init-role cp-admin-role` | CP-Portal이 만드는 Role 이름이 다를 때 |
| `JENKINS_CHART_VERSION` | `""`(최신) | 첫 설치 후 고정 권장. 폐쇄망은 묶음의 버전 |
| `ARGOCD_CHART_VERSION`, `GITLAB_RUNNER_CHART_VERSION`, `GITLAB_IMAGE` | 고정 버전 | 업그레이드할 때 |
| `JENKINS_DATA_SIZE`, `GITLAB_*_SIZE`, `GITLAB_*_REQUEST/LIMIT`, `RUNNER_*` | — | 용량·자원 조정 |
| `CONSOLE_HOST_PREFIX` | `cicd` | 콘솔 주소 `https://cicd.<도메인>` 바꿀 때 |
| `CONSOLE_IMAGE_TAG`, `SECURITY_IMAGE_TAG` | `1.0.0` | 이미지를 새로 만들 때 올림 |
| `CONSOLE_JENKINS_API_URL`, `CONSOLE_GITLAB_API_URL`, `CONSOLE_SCM_API_URL` | `""` | 콘솔 Pod가 `*.<도메인>`에 접근하지 못할 때 내부 주소 |
| `MARIADB_IMAGE`, `DB_SIZE` | `docker.io/library/mariadb:11.4`, `2Gi` | 앱 전용 DB 이미지·크기 |

### 2-3. 폐쇄망·사내 미러를 쓸 때 (★ = 새 환경의 Harbor 주소로)

`offline/load-to-harbor.sh`가 마지막에 이 값들을 출력한다([Harbor 이미지 옮기기](harbor-image-migration.md)).

| 변수 | 예 | 뜻 |
|---|---|---|
| `CICD_CHART_DIR` | `/opt/offline/charts` | Helm 차트를 인터넷 대신 이 폴더에서 |
| `JENKINS_IMAGE` ★ | `harbor.<도메인>/cicd-mirror/jenkins:2.479.3-jdk17-plugins` | 플러그인이 들어 있는 Jenkins (플러그인 다운로드 안 함) |
| `JENKINS_TOOL_IMAGE` ★ | `harbor.<도메인>/cicd-mirror/jenkins:lts-jdk17` | Jenkins 초기화 이미지 |
| `CICD_BASE_REGISTRY` ★ | `harbor.<도메인>/base-images` | 앱 Dockerfile의 `FROM` (php, java, node, nginx) |
| `CICD_DOCKERHUB` ★ | `harbor.<도메인>/base-images` | 빌드 도구 이미지 (maven, gradle, node, composer, alpine) |
| `KANIKO_IMAGE` ★ | `harbor.<도메인>/cicd-mirror/kaniko-executor:v1.23.2-debug` | Jenkins 이미지 빌드 |
| `MARIADB_IMAGE` ★ | `harbor.<도메인>/base-images/mariadb:11.4` | 앱 전용 DB |
| `CICD_NEXUS_URL` | `http://bootstrap.<도메인>:8081` | Maven/Gradle/npm/Composer 의존성 (사내 Nexus) |
| `CONSOLE_PIP_INDEX_URL`, `CONSOLE_APT_MIRROR` | Nexus PyPI, Debian 미러 | 콘솔·스캐너 이미지를 폐쇄망에서 **빌드**할 때만 |
| `SECURITY_TRIVY_DB_REPOSITORY`, `SECURITY_TRIVY_JAVA_DB_REPOSITORY` ★ | `harbor.<도메인>/mirror/trivy-db` | Trivy 취약점 DB 미러 |
| `SECURITY_GITLEAKS_IMAGE`, `SECURITY_TRIVY_IMAGE`, `PRESIDIO_IMAGE`, `GITLAB_IMAGE` | — | 미러 레지스트리 주소로 바꾸거나, 부트스트랩 미러(원래 이름 유지)를 쓰면 그대로 |

> 이미지를 Harbor에서 가져오면 폐쇄망에서는 `console-image`, `security-image` 단계(빌드)를 실행하지 않는다.

### 2-4. 실행할 때 입력하는 환경 변수 (파일에 저장하지 않음)

비밀번호는 명령줄에 그대로 쓰지 말고 `read -rs`로 입력받는다. 새 터미널마다 다시 입력한다.

```bash
read -rsp 'scmadmin git 비밀번호: ' SCM_ADMIN_PASSWORD; echo; export SCM_ADMIN_PASSWORD
```

| 환경 변수 | 필요한 명령 | 설명 |
|---|---|---|
| `SCM_ADMIN_PASSWORD` | `preflight`, `console`, `onboard-vendor.sh`, `add-app.sh`, 업체·앱 삭제, 재설치 백업·복원 | SCM 관리자 git 비밀번호. `console` 단계에서 콘솔 Secret(`cicd-console-secrets`)에 저장되어 콘솔이 씀 |
| `JENKINS_USER`, `JENKINS_API_TOKEN` | `./deploy-cicd-portal.sh jenkins-token` (1회) | Jenkins API 토큰 등록. 이후 스크립트·콘솔은 저장된 토큰 사용 |
| `SCM_CI_PASSWORD` | `onboard-vendor.sh` (업체 등록 2차) | CI 계정 git 비밀번호. 콘솔에서 등록하면 화면에 입력 |
| `SCM_CI_USER` | `onboard-vendor.sh` | CI 계정을 `jenkins-<업체>` 대신 기존 계정으로 |
| `PM_USERS` | `onboard-vendor.sh` | 업체 PM (GitLab Maintainer) |
| `CICD_SOURCES` | 모든 명령 | `cicd-vars.sh` 값 대신 이번 실행만 (예: `CICD_SOURCES=gitlab`) |
| `CICD_JENKINS_URL`, `CICD_GITLAB_URL`, `CICD_SCM_URL` | 스크립트 | 관리 노드에서 `*.<도메인>` 대신 다른 API 주소를 쓸 때 |
| `CICD_BUILD_TMPDIR`, `CICD_BUILD_MIN_FREE_GB` | `console-image`, `security-image` | podman 빌드 임시 폴더(디스크 부족 시 `/data/podman-tmp`), 최소 여유 GB(기본 10) |
| `SECURITY_PRESIDIO`, `DEFECTDOJO_URL`, `DEFECTDOJO_TOKEN`, `SECURITY_POLICY_RESET` | `security` | 개인정보 분석기, 결과 전송, 정책 초기화 |
| `PORTAL_DIR`, `PORTAL_VARS`, `CA_FILE` | 모든 명령 | 1-1의 파일 위치가 다를 때 |

### 2-5. 콘솔 Pod 환경 (자동)

콘솔은 시작할 때 `lib.sh`를 실행해 위 값을 그대로 읽는다(도메인, Keycloak·Harbor 관리자, MariaDB 비밀번호 등).
따로 설정하지 않는다. 필요하면 `cicd-portal-deployment/manifests/console.yaml`의 콘솔 컨테이너 `env`에 다음 값을
넣거나 고친다(`CICD_UPLOAD_MAX_MB`는 이미 있음, 나머지는 추가).

| 변수 | 기본 | 뜻 |
|---|---|---|
| `CICD_UPLOAD_MAX_MB` | `2048` | 컨테이너 이미지 등록 최대 크기 |
| `CICD_SCM_RECONCILE_MINUTES` | `10` | 구성원 SCM 권한 '첫 로그인 대기' 자동 적용 주기 (`0` 끔) |
| `CONSOLE_TZ_OFFSET` | `9` | 화면 시간대 (KST) |

`cp-portal-vars.sh`나 `cicd-vars.sh`를 바꾼 뒤에는 콘솔을 다시 배포한다(`./deploy-cicd-portal.sh console-image console`, 폐쇄망은 `console`).

---

## 3. 새 환경 배포 체크리스트

- [ ] `kubectl get nodes` 모두 Ready, CP-Portal·Keycloak·Harbor·MariaDB(·소스 컨트롤) Running
- [ ] `cp-portal-deployment/script/cp-portal-vars.sh`가 새 환경 값 (도메인, 관리자 비밀번호가 현재 값과 같음)
- [ ] `cp-portal-deployment/certs/ca.crt`가 새 환경 CA, 모든 노드(제어 노드 포함)에 CA 설치
- [ ] `cicd-vars.sh`: `CICD_SOURCES`, `K8S_STORAGECLASS`, (폐쇄망) ★ 값들
- [ ] `scmadmin` git 비밀번호 준비 → `export SCM_ADMIN_PASSWORD`
- [ ] `./deploy-cicd-portal.sh preflight` 에 `[FAIL]` 없음
- [ ] `./deploy-cicd-portal.sh` → Jenkins 로그인 → API 토큰 → `JENKINS_USER=.. JENKINS_API_TOKEN=.. ./deploy-cicd-portal.sh jenkins-token`
- [ ] `./deploy-cicd-portal.sh console-image console` (폐쇄망: `console`), 선택 `security-image security`
- [ ] `./check-cicd-portal.sh`, `https://cicd.<도메인>` 로그인, 운영자를 Keycloak 그룹 `cicd-admins`에 추가
