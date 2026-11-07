# 인터넷이 차단된 폐쇄망에 새로 설치하기

K-PaaS(CP-Portal, 소스 컨트롤, 파이프라인)와 CI/CD 포털(Jenkins, **GitLab**, Argo CD, 콘솔, 보안 검사)을
**인터넷이 없는 폐쇄망**에 새로 설치하는 절차다. 도메인 방식([도메인 방식 재설치 가이드](install-with-domain.md))과 함께 쓴다.

## 0. 구성과 원리

```text
[지금 서버 (인터넷 연결, 초기화 전)]                       [폐쇄망]
 collect-bundle.sh                                         부트스트랩 VM (별도, Rocky 9.7)
  ├ 실행 중 클러스터의 이미지 목록 그대로      ──반입──▶    ├ dnf 저장소 + 파일 서버  http://bootstrap:8080
  ├ 차트(실행 중 버전), 도구, 소스컨트롤 패키지              └ 이미지 레지스트리       bootstrap:5000
  ├ Rocky 9 저장소(reposync)                                        ▲ 모든 노드가 미러로 사용
  ├ Jenkins + 설치된 플러그인 이미지                         Kubernetes 노드 · 관리 노드 (node-setup.sh)
  └ 콘솔·스캐너 이미지, 앱 base 이미지                       → K8s → CP-Portal(Harbor) → load-to-harbor.sh
                                                             → 소스컨트롤 → 파이프라인 → CI/CD 포털
```

**핵심 원리 — 이미지 이름을 바꾸지 않는다.** 부트스트랩 레지스트리는 이미지를 원래 이름 그대로
(`bootstrap:5000/docker.io/library/mariadb:11.4`) 보관하고, 모든 노드의 containerd·podman이
`docker.io`, `quay.io`, `registry.k8s.io`, `registry.k-paas.org`, `gcr.io`, `ghcr.io`, `mcr.microsoft.com`,
`registry.gitlab.com`을 이 레지스트리로 받도록 미러 설정한다. 그래서 차트·매니페스트·스크립트의 이미지 주소를 고칠 필요가 없다.

**지금 서버에서 받는 이유.** 반입 목록을 손으로 만들면 빠지는 것이 생긴다. 지금 **정상 동작 중인 클러스터**의 이미지와 차트 버전,
Jenkins에 설치된 플러그인을 그대로 수집하므로 폐쇄망에 같은 구성이 설치된다. **서버를 초기화하기 전에** 1장을 반드시 끝낸다.

| 역할 | 서버 |
| --- | --- |
| 준비 (인터넷) | 지금의 관리 노드 (초기화 전) |
| 부트스트랩 VM | 폐쇄망의 별도 VM — Rocky 9.7, 디스크 **300GB 이상**(저장소 ~15GB + 이미지 ~40~60GB + Nexus 앱 의존성 + 여유), 4 CPU / **12GB**(Nexus 3 포함) |
| 대상 | Kubernetes 노드, 관리 노드 (초기화 후 재설치) |

---

## 1. 반입 묶음 만들기 (지금 서버, 초기화 전)

### 1-1. 준비

관리 노드에 도구를 설치한다(인터넷 연결 상태).

```bash
sudo dnf install -y skopeo podman dnf-plugins-core createrepo_c wget
```

이 저장소를 최신으로 받고, **콘솔과 스캐너 이미지를 다시 빌드**한다. 콘솔 이미지에는 현재 스크립트가, 스캐너 이미지에는
최신 취약점 DB(Trivy)가 들어간다. 폐쇄망에서는 이 DB를 그대로 쓴다.

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script
```

```bash
./deploy-cicd-portal.sh security-image console-image
```

### 1-2. 수집

```bash
cd ~/Saeoll-PaaS/offline
```

```bash
./collect-bundle.sh /data/offline-bundle
```

| 단계 | 내용 | 결과 |
| --- | --- | --- |
| images | 실행 중인 모든 이미지 + 빌드 때만 쓰는 이미지(Jenkins agent, GitLab runner helper, gradle·maven·node·composer·alpine, kaniko, MariaDB, Presidio, registry, nginx, busybox) | `images/oci`, `images/images.txt` |
| cicd | 콘솔·스캐너 이미지(지금 Harbor), **Jenkins + 설치된 플러그인 전부**(버전 그대로), 앱 Dockerfile의 base 이미지 | `images/harbor-images.txt` |
| charts | K-PaaS 차트, Jenkins·Argo CD·GitLab Runner 차트(**지금 실행 중인 버전**) | `charts/`, `charts/versions.env` |
| files | kubectl, helm, step, istioctl, helm-push 플러그인, 소스 컨트롤 패키지 | `files/` |
| rpms | Rocky 9 baseos·appstream·extras (dnf reposync) | `rpms/` |
| kubespray | Kubernetes 바이너리 (kubespray로 설치하는 경우) | `files/kubespray/` |
| appdeps | 시작 소스·샘플·`APP_SOURCES` 앱의 빌드 의존성 (6장 Nexus) | `appdeps/` |
| repo | 이 저장소 | `Saeoll-PaaS.bundle` |

- 단계만 골라 다시 실행할 수 있다: `./collect-bundle.sh /data/offline-bundle images cicd`
- 끝에 `Bundle size`가 나온다(보통 70~100GB). `[WARN] Missing:`이 있으면 원인을 해결하고 해당 단계만 다시 실행한다.
- EPEL 등 다른 저장소를 쓰고 있었다면 `RPM_EXTRA_REPOS="epel"`을 붙인다.

### 1-3. 백업과 반입

- 업체 저장소·DB도 같이 옮기려면 [도메인 방식 재설치 가이드 2장](install-with-domain.md#2-재설치-전-백업-지금-서버에서-반드시)의 백업도 받는다.
- 반입 매체로 복사한 뒤 무결성을 확인한다(반입 후에도 같은 명령으로 확인).

```bash
cd /data/offline-bundle && sha256sum -c --quiet SHA256SUMS && echo OK
```

- 기관 반입 절차(백신 검사, 승인)를 따른다. 반입 목록은 `images/images.txt`, `charts/`, `files/`로 제출할 수 있다.

---

## 2. 부트스트랩 VM 구성 (폐쇄망)

1. Rocky Linux 9.7 **DVD ISO**로 최소 설치한다(고정 IP). 내부 DNS에 이름을 등록한다(예: `bootstrap.kpaas.example.co.kr`).
2. 반입한 묶음을 복사한다(예: `/data/offline-bundle`).
3. 묶음 안의 저장소에서 스크립트를 꺼내 실행한다.

```bash
git clone /data/offline-bundle/Saeoll-PaaS.bundle ~/Saeoll-PaaS
```

`git`이 없으면 먼저 설치 DVD 저장소로 설치한다(`dnf install -y git`).

```bash
cd ~/Saeoll-PaaS/offline
```

```bash
sudo BOOTSTRAP_HOST=bootstrap.kpaas.example.co.kr ./bootstrap-server.sh /data/offline-bundle
```

결과: dnf 저장소·파일 서버 `http://bootstrap...:8080/`, 레지스트리 `bootstrap...:5000`(HTTP), 재부팅 후에도 자동 실행.
이미지 업로드가 끝나면 `Bootstrap VM ready (N/N images)`가 나온다.

---

## 3. 서버 OS 설치와 노드 설정 (모든 서버)

### 3-1. OS 설치

Rocky Linux 9.7 최소 설치(고정 IP, 호스트명). 내부 DNS를 사용하도록 설정한다([도메인 가이드 3-2](install-with-domain.md#3-2-노드-공통-설정--dns-모든-서버)).

### 3-2. 스크립트 받기

```bash
curl -fO http://bootstrap.kpaas.example.co.kr:8080/Saeoll-PaaS.bundle
```

```bash
sudo dnf install -y git || true
```

(첫 실행 전에는 dnf가 아직 인터넷 저장소를 보므로 실패해도 된다. git이 없으면 3-3을 먼저 하고 다시 설치한다.)

```bash
git clone Saeoll-PaaS.bundle ~/Saeoll-PaaS
```

### 3-3. 노드 설정

모든 Kubernetes 노드와 관리 노드에서 실행한다. `--ntp`는 기관 시간 서버(없으면 생략).

```bash
cd ~/Saeoll-PaaS/offline
```

```bash
sudo BOOTSTRAP_HOST=bootstrap.kpaas.example.co.kr ./node-setup.sh --ntp 192.168.20.10
```

- dnf: 부트스트랩 저장소만 사용
- containerd: `/etc/containerd/certs.d/<레지스트리>/hosts.toml` (Kubernetes 설치 전에 만들어 두면 설치 후 그대로 사용)
- podman·buildah·skopeo: `/etc/containers/registries.conf.d/50-offline-mirror.conf`

### 3-4. Kubernetes 설치

**kubespray(이 저장소 standalone/single/multi)로 설치하는 경우** — 설정 조각을 출력해 `offline.yml`에 넣는다.

```bash
BOOTSTRAP_HOST=bootstrap.kpaas.example.co.kr ./node-setup.sh --kubespray
```

출력의 `files_repo`, `containerd_registries_mirrors`를 `inventory/<클러스터>/group_vars/all/offline.yml`에 넣고,
`inventory/sample/group_vars/all/offline.yml`의 `*_download_url` 줄(`{{ files_repo }}` 사용)을 복사해 주석을 푼다.
이미지 주소(`kube_image_repo` 등)는 **바꾸지 않는다** — containerd 미러가 받는다.

**다른 설치 도구(cluster.env 방식 등)인 경우** — 그 도구의 오프라인 설정에 따라 바이너리를 `http://bootstrap...:8080/files/`에서 받게 하고,
containerd는 3-3의 미러 설정을 그대로 쓴다(`/etc/containerd/config.toml`에 `config_path = "/etc/containerd/certs.d"` 필요, node-setup.sh가 확인).

설치 후 확인:

```bash
kubectl get nodes -o wide
```

```bash
sudo crictl pull docker.io/library/busybox:1.36
```

---

## 4. CP-Portal 설치

관리 노드에 묶음의 `files/`와 `charts/`를 둔다(예: `/opt/offline`, 반입 매체에서 복사 또는 부트스트랩 VM에서 `scp`).

1. 도구 — 인터넷 대신 묶음 파일로 설치:

```bash
cd ~/Saeoll-PaaS/cp-portal-deployment/istio_mc && OFFLINE_FILES=/opt/offline/files ./install_tools.sh
```

2. 차트 — 미리 두면 배포 스크립트가 받지 않는다:

```bash
mkdir -p ~/Saeoll-PaaS/cp-portal-deployment/charts ~/Saeoll-PaaS/cp-pipeline-deployment/charts
```

```bash
cp /opt/offline/charts/*.tgz ~/Saeoll-PaaS/cp-portal-deployment/charts/ && cp /opt/offline/charts/*.tgz ~/Saeoll-PaaS/cp-pipeline-deployment/charts/
```

3. helm-push 플러그인 — 묶음의 플러그인 폴더를 쓴다:

```bash
tar xzf /opt/offline/files/helm-push-plugin.tar.gz -C /opt/offline/files
```

4. 변수 설정과 배포 — [도메인 가이드 4장](install-with-domain.md#4-cp-portal-설치-도메인)과 같다. `K_PAAS_REGISTRY`는 **그대로** 둔다(미러가 받음).

```bash
cd ~/Saeoll-PaaS/cp-portal-deployment/script
```

```bash
HELM_PUSH_PLUGIN=/opt/offline/files/helm-push ./deploy-cp-portal.sh 2>&1 | tee cp-portal-deploy.log
```

---

## 5. Harbor 적재와 나머지 설치

### 5-1. 포털 이미지를 Harbor로

```bash
cd ~/Saeoll-PaaS/offline && ./load-to-harbor.sh /opt/offline
```

Harbor에 `cicd-portal`(콘솔·스캐너), `cicd-mirror`(Jenkins + 플러그인), `base-images`(앱 base 이미지) 프로젝트가 생기고,
마지막에 **CI/CD 포털 설정 값**이 출력된다(5-3에서 사용). 이 스크립트는 `/opt/offline`에 `images/`도 있어야 한다(묶음 전체 복사).

### 5-2. 소스 컨트롤, 파이프라인

```bash
cd ~/Saeoll-PaaS/cp-source-control-deployment/script && ./fetch-cp-source-control.sh /opt/offline/files/cp-source-control-deployment-*.tar.gz
```

이후 각 README대로 설치한다. 파이프라인 차트는 4-2에서 복사했다.

### 5-3. CI/CD 포털 (Jenkins, GitLab, Argo CD, 콘솔, 보안 검사)

`cicd-portal-deployment/script/cicd-vars.sh`에 5-1에서 출력된 값을 넣는다. 예:

```bash
CICD_CHART_DIR="/opt/offline/charts"
JENKINS_CHART_VERSION="5.8.10"
ARGOCD_CHART_VERSION="7.8.0"
GITLAB_RUNNER_CHART_VERSION="0.76.0"
JENKINS_IMAGE="harbor.kpaas.example.co.kr/cicd-mirror/jenkins:2.479.3-jdk17-plugins"
CICD_BASE_REGISTRY="harbor.kpaas.example.co.kr/base-images"
CONSOLE_IMAGE_TAG="1.0.0"
SECURITY_IMAGE_TAG="1.0.0"
CICD_NEXUS_URL="http://bootstrap.kpaas.example.co.kr:8081"     # 6장 Nexus
```

(숫자는 예시 — 5-1 출력 값을 쓴다.) 그다음 [CI/CD 포털 처음 설치하기](../cicd-portal-deployment/docs/getting-started.md)를 따르되,
**이미지 빌드 단계(`console-image`, `security-image`)는 실행하지 않는다** — 이미지가 이미 Harbor에 있다.

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script && ./deploy-cicd-portal.sh
```

```bash
./deploy-cicd-portal.sh console security
```

- Jenkins는 플러그인이 들어 있는 이미지로 뜨며 플러그인을 내려받지 않는다.
- GitLab CE·Runner·빌드 Pod 이미지는 미러로 받는다(runner helper 포함).
- 보안 검사의 Trivy는 DB 갱신에 실패하면 이미지에 든 DB로 자동 전환한다(`offline DB used`). DB를 새로 하려면 7장.

---

## 6. 사내 저장소 Nexus 3 (앱 빌드 의존성)

앱 빌드는 언어별 의존성(Maven Central, Gradle, npm, Packagist)을 내려받는다. 폐쇄망에서는 **부트스트랩 VM의 Nexus 3**가 이를 대신한다.

```text
[인터넷 쪽] collect-app-deps.sh ── 실제 빌드 도구로 의존성 해석 ──▶ appdeps/ (반입 묶음에 포함)
[부트스트랩 VM] nexus-setup.sh (Nexus 3, :8081) ◀── nexus-load.sh (appdeps 업로드)
[빌드] Jenkins · GitLab · Dockerfile ── cicd-deps.sh (NEXUS_URL) ──▶ maven-public / npm-public / composer-offline
```

| Nexus 저장소 | 형식 | 쓰는 곳 |
| --- | --- | --- |
| `maven-offline` → 그룹 `maven-public` | maven2 hosted | Maven, Gradle(플러그인 포함), Maven wrapper |
| `npm-offline` → 그룹 `npm-public` | npm hosted | npm (package-lock.json의 주소를 npm이 자동으로 바꿈) |
| `composer-offline` | raw hosted (`packages.json` + zip) | Composer (packagist.org 사용 안 함) |
| `files-offline` | raw hosted | Gradle wrapper 배포본 (`./gradlew`) |

폐쇄망 Nexus에는 인터넷 proxy가 없으므로, **반입한 의존성만** 있다. 새 라이브러리는 6-4 절차로 추가한다.

### 6-1. 의존성 수집 (인터넷 쪽, 1장과 함께)

`collect-bundle.sh`의 `appdeps` 단계가 시작 소스(starters), 샘플, **업체 앱 소스**의 의존성을 모은다. 업체 앱을 함께 넣는다:

```bash
APP_SOURCES="/data/src/saeoll-php-service /data/src/soft-vue-board" ./collect-bundle.sh /data/offline-bundle appdeps
```

`APP_SOURCES`에는 디렉터리 또는 git 주소를 공백으로 구분해 적는다(백업의 `repos/scm/*.git`도 된다). 앱마다 CI 이미지 안에서
실제 빌드(Maven `verify`, Gradle `build`·`test`)와 lock 파일 해석(npm, Composer)을 하므로 빌드에 필요한 플러그인까지 들어간다.
Composer 의존성이 많으면 GitHub API 한도에 걸릴 수 있다 — `GITHUB_TOKEN=<개인 토큰>`을 붙인다.

### 6-2. Nexus 구축 (부트스트랩 VM, 2장 다음)

```bash
cd ~/Saeoll-PaaS/offline
```

```bash
sudo NEXUS_ADMIN_PASSWORD='<12자 이상>' ./nexus-setup.sh
```

- 컨테이너 `nexus`(`:8081`, 데이터 `/srv/offline/nexus`), systemd 자동 시작, 방화벽 포트
- 초기 비밀번호를 `NEXUS_ADMIN_PASSWORD`로 바꾸고 초기 비밀번호 파일 삭제
- **익명 읽기 허용**(빌드는 인증 없이 받음), 업로드는 admin만
- 위 표의 저장소 생성(다시 실행해도 안전)

의존성을 올린다:

```bash
NEXUS_ADMIN_PASSWORD='...' ./nexus-load.sh /data/offline-bundle/appdeps
```

이미 있는 파일은 건너뛰고, Composer `packages.json`은 기존 것과 합친다.

### 6-3. 빌드 연결 (CI/CD 포털)

`cicd-portal-deployment/script/cicd-vars.sh`:

```bash
CICD_NEXUS_URL="http://bootstrap.kpaas.example.co.kr:8081"
```

반영:
- **GitLab**: `./deploy-cicd-portal.sh gitlab`을 다시 실행하면 인스턴스 변수 `CICD_NEXUS_URL`이 등록된다(템플릿이 사용).
- **새 앱**: 앱 추가 시 시작 소스에 `cicd-deps.sh`가 들어가고, Jenkinsfile·Dockerfile이 `NEXUS_URL`을 쓴다.
- **기존 앱**: 콘솔 앱 추가를 **기존 CI 파일 교체**로 다시 실행하면 새 Jenkinsfile과 `cicd-deps.sh`가 추가된다.
  Dockerfile은 업체 소스이므로 시작 소스(`cicd-portal-deployment/starters/<유형>/Dockerfile`)의 `ARG NEXUS_URL`, `cicd-deps.sh` 줄을 반영한다.

동작: `cicd-deps.sh`가 `NEXUS_URL`이 있을 때만 Maven(settings.xml mirror, Maven 3.8+ http 차단 해제), Gradle(init 스크립트, wrapper 배포본 주소),
npm(registry), Composer(저장소, packagist 끔)를 Nexus로 돌린다. `NEXUS_URL`이 비어 있으면 아무것도 바꾸지 않으므로 인터넷 환경에서도 같은 파일을 쓴다.
빌드 로그에 `[cicd-deps] dependencies from http://...:8081`이 나오면 연결된 것이다.

### 6-4. 운영

| 일 | 방법 |
| --- | --- |
| **새 라이브러리 반입** (업체 요청) | 인터넷 쪽에서 업체 앱 소스(새 의존성 반영)로 `collect-app-deps.sh <출력> <소스>` → 반입 → `nexus-load.sh <출력>`. 빌드 오류의 `Could not find artifact`, `404 Not Found - GET .../npm-public/...`가 신호 |
| 수동 업로드 (소수 파일) | Nexus 화면 `http://bootstrap...:8081` → admin 로그인 → Upload → `maven-offline`(jar+pom) 또는 `npm-offline`(tgz) |
| 백업 | 부트스트랩 VM의 `/srv/offline/nexus`(Nexus 데이터)를 정기 백업. 일관성을 위해 `systemctl stop container-nexus` 후 복사하거나 Nexus의 Tasks > *Admin - Export databases for backup* 사용 |
| 디스크 관리 | Administration > Repository > Cleanup Policies(오래된 버전 삭제) + Tasks > *Compact blob store* |
| 계정·권한 | admin은 운영 관리자만. 업로드 담당자는 Security > Users에서 `nx-repository-view-*-*-add`가 있는 별도 계정을 만들어 쓴다. 익명은 읽기만 |
| 상태 확인 | `curl -s http://bootstrap...:8081/service/rest/v1/status/writable` (200), `podman logs nexus` |
| Nexus 업그레이드 | 인터넷 쪽에서 `NEXUS_IMAGE`를 새 버전으로 바꿔 `collect-bundle.sh <묶음> images` → 반입 → `bootstrap-server.sh` → 데이터 백업 후 `podman rm -f nexus` → `nexus-setup.sh` |

PHP는 `vendor/`를 저장소에 커밋하는 방법도 계속 쓸 수 있다(설치된 상태면 Composer가 내려받지 않음).
K-PaaS 파이프라인(`cp-pipeline-deployment/php-sample`)의 composer는 이 설정을 쓰지 않으므로 `vendor/` 커밋 방식을 쓴다.

---

## 7. 정기 반입 (업데이트)

설치 후에는 인터넷 연결 클러스터가 없으므로, 인터넷 PC(Rocky 9.7)에서 이전 목록으로 새 묶음을 만든다.

```bash
IMAGES_FROM=/data/offline-bundle/images/images.txt ./collect-bundle.sh /data/offline-bundle-2 images files rpms appdeps repo
```

- 부트스트랩 VM에서 `bootstrap-server.sh <새 묶음>`을 다시 실행하면 추가·갱신된다. 앱 의존성은 `nexus-load.sh <새 묶음>/appdeps`.
- 보안 검사 DB 갱신: 인터넷 PC에서 스캐너 이미지를 다시 빌드(`security/scanner/Dockerfile`)하고 반입해 Harbor `cicd-portal/security-scanner`에 올린다(월 1회 이상 권장).
- OS 보안 패치: 새 묶음의 `rpms/` 반영 후 각 노드에서 `dnf update`.

---

## 8. 확인과 문제 해결

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| Pod `ImagePullBackOff`, 이벤트에 `docker.io/...` | 미러 설정 없음 또는 묶음에 이미지 없음 | 노드에서 `crictl pull <이미지>`, `/etc/containerd/certs.d` 확인. 없는 이미지는 `EXTRA_IMAGES`에 넣고 1-2 `images` 단계 재수집·반입 |
| `node-setup.sh`: config_path 경고 | containerd가 certs.d를 안 읽음 | `config.toml`의 registry 절에 `config_path = "/etc/containerd/certs.d"` 추가 후 `systemctl restart containerd` |
| dnf `Cannot download repomd.xml` | 부트스트랩 파일 서버 접근 불가 | `curl http://bootstrap...:8080/rpms/baseos/repodata/repomd.xml`, 방화벽(8080) |
| Jenkins가 플러그인을 받으려다 실패 | `JENKINS_IMAGE` 미설정 | 5-3 설정 후 `./deploy-cicd-portal.sh jenkins` |
| `chart ... not found (offline bundle charts/)` | 차트 버전 미고정 또는 파일 없음 | `charts/versions.env` 값을 cicd-vars.sh에 넣었는지 확인 |
| GitLab Runner 작업이 `gitlab-runner-helper` 이미지에서 멈춤 | helper 이미지 버전 불일치 | 묶음의 `images.txt`에 있는 helper 태그와 runner 버전 비교, 같은 차트 버전 사용 |
| 앱 빌드가 의존성 단계에서 실패 (`Could not find artifact`, npm 404) | Nexus에 그 의존성이 없음 | 6-4 새 라이브러리 반입 |
| 빌드가 `bootstrap...:8081`에 연결하지 못함 (timeout) | 빌드 Pod → 부트스트랩 VM 통신 차단 | 방화벽 8081, 업체 네임스페이스 NetworkPolicy의 egress 확인 |
| 빌드 로그에 `[cicd-deps]` 줄이 없음 | `CICD_NEXUS_URL` 미설정, 기존 앱의 Jenkinsfile·Dockerfile이 예전 것 | 6-3 |
| Maven `Blocked mirror for repositories` | 예전 settings.xml | 새 `cicd-deps.sh` 사용 (http 차단 해제 포함) |
