# Harbor 이미지 백업 → 다른 K-PaaS(폐쇄망) Harbor 등록

> 폐쇄망 **RKE2** K-PaaS에 CI/CD 포털까지 설치하는 전체 순서(백업 → 반입 → Harbor 등록 → 노드 미러 → 설치)는
> [폐쇄망 RKE2 K-PaaS에 CI/CD 포털 설치하기](offline-cicd-install-rke2.md)를 따른다. 이 문서는 백업·등록 스크립트의 상세 설명이다.
> `harbor-export.sh`는 이제 Argo CD·GitLab 등 다른 레지스트리 이미지(`mirror/<레지스트리>/...`)와 차트(`charts/`)도 함께 백업한다.

지금 쓰는 K-PaaS의 Harbor에서 **CI/CD 포털 이미지**와 **앱 언어별 base 이미지(php, java, node.js, vue)**,
**DB 이미지(MariaDB, PostgreSQL)** 를 백업해서, 인터넷이 없는 다른 K-PaaS의 Harbor에 등록하고
CI/CD 포털을 배포하는 방법이다.

```
[지금 K-PaaS: harbor.<지금 도메인>]                     [폐쇄망 K-PaaS: harbor.<새 도메인>]
  ① offline/harbor-export.sh  ──► harbor-export-<날짜>.tar ──(USB·망연계)──► ③ offline/load-to-harbor.sh
     (Harbor + 없으면 docker.io)      + .sha256                                 ④ cicd-vars.sh 설정
                                                                                ⑤ deploy-cicd-portal.sh
```

> Argo CD, GitLab, Jenkins 차트, Kubernetes 자체 이미지처럼 **Harbor 밖에서 받는 이미지와 Helm 차트**는 이 문서 범위가 아니다.
> 폐쇄망 전체 설치는 [폐쇄망 설치](install-offline.md)(부트스트랩 VM 미러 + `collect-bundle.sh`)를 따른다.
> 이 문서는 그중 **Harbor에 들어가는 이미지**만 따로 옮기거나, 이미 설치된 다른 K-PaaS에 옮길 때 쓴다.

---

## 1. 옮기는 이미지

| 새 Harbor 위치 | 용도 | 언어/구분 |
|---|---|---|
| `cicd-portal/cicd-console:<태그>` | CI/CD 콘솔 (비공개) | CI/CD |
| `cicd-portal/security-scanner:<태그>` | 보안 검사 (비공개) | CI/CD |
| `cicd-mirror/jenkins:<버전>-plugins` | Jenkins + 지금 설치된 플러그인 전부 (공개) | CI/CD (scm 업체) |
| `cicd-mirror/jenkins:lts-jdk17` | Jenkins 초기화(keytool) | CI/CD |
| `cicd-mirror/kaniko-executor:<태그>` | Jenkins에서 앱 이미지 빌드 | CI/CD |
| `base-images/php:8.3-apache-bookworm`, `base-images/composer:2` | PHP 앱 실행·빌드 | PHP |
| `base-images/eclipse-temurin:17-jre`, `base-images/maven:3.9-eclipse-temurin-17`, `base-images/gradle:8.10-jdk17` | Java 앱 실행·빌드 | Java |
| `base-images/node:20-alpine` | Node.js 앱 실행, Vue 빌드 | Node.js / Vue |
| `base-images/nginx:1.27-alpine` | Vue(정적 파일) 실행 | Vue |
| `base-images/mariadb:11.4` | 앱 전용 DB (`add-db.sh` dedicated) | DB |
| `base-images/postgres:16-alpine` | PostgreSQL을 쓰는 앱 | DB |
| `base-images/alpine:3.20` | 파이프라인 보조 단계 | 공통 |

- 목록은 고정이 아니다. `starters/*/Dockerfile`의 `FROM` 줄과 `cicd-vars.sh`(`MARIADB_IMAGE`, `KANIKO_IMAGE`,
  `JENKINS_TOOL_IMAGE`) 값을 읽어 자동으로 정한다. 버전을 바꿨으면 그 버전이 옮겨진다.
- Harbor 프로젝트 `cicd-portal`, `cicd-mirror`, `base-images`에 있는 이미지는 저장소마다 **최근 3개 태그**까지 함께 옮긴다.
- **Harbor에 없는 이미지는 docker.io 등 원래 레지스트리에서** 받는다(지금 서버가 인터넷에 연결돼 있어야 한다).

---

## 2. 백업 (지금 K-PaaS의 관리 노드)

### 2-1. 준비

| 항목 | 확인 |
|---|---|
| 도구 | `skopeo`, `python3` (`sudo dnf install -y skopeo`). Jenkins 이미지까지 만들려면 `podman`, `kubectl` |
| 설정 | `cp-portal-deployment/script/cp-portal-vars.sh`(도메인, Harbor 관리자 계정), `cp-portal-deployment/certs/ca.crt` |
| 디스크 | 약 **5~8 GB** (base 이미지 3~4 GB + 콘솔·스캐너·Jenkins). `df -h ~` 로 확인 |
| 최신 이미지 | 콘솔·스캐너를 최신 스크립트로 다시 만들어 두면 좋다: `cd ~/Saeoll-PaaS/cicd-portal-deployment/script && ./deploy-cicd-portal.sh security-image console-image` |

### 2-2. 실행

```bash
cd ~/Saeoll-PaaS/offline
```

```bash
./harbor-export.sh ~/harbor-export-$(date +%Y%m%d) 2>&1 | tee harbor-export.log
```

끝나면 다음 파일이 생긴다.

| 파일 | 내용 |
|---|---|
| `~/harbor-export-<날짜>/images/oci/` | 이미지 (OCI 형식, 같은 레이어는 한 번만 저장) |
| `~/harbor-export-<날짜>/images/harbor-images.txt` | 새 Harbor에 넣을 위치 목록 |
| `~/harbor-export-<날짜>/images/sources.txt` | 각 이미지를 어디서 받았는지 |
| `~/harbor-export-<날짜>.tar`, `.tar.sha256` | **반입할 파일** |

마지막에 `[WARN] not exported` 목록이 나오면 그 이미지만 실패한 것이다(종료 코드 3). 원인을 고치고 다시 실행하면 된다.

### 2-3. 옵션

| 환경 변수 | 기본값 | 설명 |
|---|---|---|
| `HARBOR_PROJECTS` | `cicd-portal cicd-mirror base-images` | 통째로 옮길 Harbor 프로젝트. 업체 앱 이미지도 옮기려면 추가 (예: `"cicd-portal cicd-mirror base-images soft"`) |
| `KEEP_TAGS` | `3` | 저장소마다 옮길 최근 태그 수 |
| `DB_IMAGES` | `mariadb:11.4 postgres:16-alpine` | DB 이미지 (docker.io/library 기준 이름) |
| `EXTRA_BASE_IMAGES` | (없음) | 더 넣을 base 이미지, 예: `"python:3.12-slim openjdk:21-jdk-slim"` |
| `FROM_DOCKERHUB` | `1` | `0`: Harbor에 있는 것만 (지금 서버도 인터넷이 없을 때) |
| `JENKINS_PLUGINS` | `1` | Harbor에 `cicd-mirror/jenkins:*-plugins`가 없으면 실행 중인 Jenkins의 플러그인을 넣은 이미지를 만든다 |
| `PACK` | `1` | `0`: tar로 묶지 않음 |

예: 업체 `soft`의 앱 이미지까지, 태그는 최근 5개.

```bash
HARBOR_PROJECTS="cicd-portal cicd-mirror base-images soft" KEEP_TAGS=5 ./harbor-export.sh ~/harbor-export-$(date +%Y%m%d)
```

> 비밀번호는 명령줄이나 로그에 나오지 않는다. Harbor 계정은 0600 임시 파일로만 쓰고 끝나면 지운다.

---

## 3. 반입 (폐쇄망)

1. `harbor-export-<날짜>.tar`와 `.tar.sha256`을 승인된 매체(USB, 망연계 시스템)로 폐쇄망 **관리 노드**에 복사한다.
2. 파일이 온전한지 확인한다.

```bash
cd /opt && sha256sum -c harbor-export-*.tar.sha256
```

`OK`가 나와야 한다. 그다음 압축을 푼다.

```bash
sudo tar -xf /opt/harbor-export-*.tar -C /opt
```

---

## 4. 새 Harbor에 등록 (폐쇄망 관리 노드)

### 4-1. 전제

- 새 K-PaaS에 **CP-Portal(Harbor)이 설치**돼 있다 (`https://harbor.<새 도메인>` 로그인 가능).
- `~/Saeoll-PaaS/cp-portal-deployment/script/cp-portal-vars.sh`가 **새 환경 값**(새 도메인, Harbor 관리자 계정)이다.
- `~/Saeoll-PaaS/cp-portal-deployment/certs/ca.crt`가 **새 환경의 CA**다.
- `skopeo`가 설치돼 있다(폐쇄망: 부트스트랩 dnf 저장소에서 `sudo dnf install -y skopeo`).

### 4-2. 등록

```bash
cd ~/Saeoll-PaaS/offline
```

```bash
./load-to-harbor.sh /opt/harbor-export-<날짜>
```

- Harbor에 프로젝트가 없으면 만든다: `cicd-portal`(비공개), `cicd-mirror`·`base-images`(공개), 업체 프로젝트(비공개).
- 이미 있는 이미지는 덮어써도 내용이 같다(다시 실행해도 된다).
- 마지막에 **`cicd-vars.sh`에 넣을 값**이 출력된다. 예:

```
CI/CD portal settings for the closed network - put them in cicd-portal-deployment/script/cicd-vars.sh:
  JENKINS_IMAGE="harbor.new.example.kr/cicd-mirror/jenkins:2.479.3-jdk17-plugins"
  CICD_BASE_REGISTRY="harbor.new.example.kr/base-images"
  MARIADB_IMAGE="harbor.new.example.kr/base-images/mariadb:11.4"
  KANIKO_IMAGE="harbor.new.example.kr/cicd-mirror/kaniko-executor:v1.23.2-debug"
  JENKINS_TOOL_IMAGE="harbor.new.example.kr/cicd-mirror/jenkins:lts-jdk17"
  CICD_DOCKERHUB="harbor.new.example.kr/base-images"   # CI tool images (maven, gradle, node, composer, alpine)
  CONSOLE_IMAGE_TAG="1.0.0"
  SECURITY_IMAGE_TAG="1.0.0"
  (PostgreSQL for the applications: image harbor.new.example.kr/base-images/postgres:16-alpine)
```

### 4-3. 확인

Harbor 화면(`https://harbor.<새 도메인>` → 프로젝트)에서 `cicd-portal`, `cicd-mirror`, `base-images`의 저장소와 태그를 본다.
노드에서 실제로 받아지는지도 한 번 확인한다(워커 노드에서).

```bash
sudo crictl pull harbor.<새 도메인>/base-images/node:20-alpine
```

`x509: certificate signed by unknown authority`가 나오면 그 노드에 새 CA가 설치되지 않은 것이다 → 6장.

---

## 5. CI/CD 포털 설정과 배포 (폐쇄망)

1. `~/Saeoll-PaaS/cicd-portal-deployment/script/cicd-vars.sh`를 열어 4-2에서 출력된 줄을 **그대로** 바꿔 넣는다
   (같은 이름의 기존 줄을 고친다).
2. 사전 점검을 한다.

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script && ./deploy-cicd-portal.sh preflight
```

3. 배포한다. **이미지 빌드 단계(`console-image`, `security-image`)는 실행하지 않는다** — 이미지가 이미 Harbor에 있다.

```bash
./deploy-cicd-portal.sh
```

콘솔과 보안 검사를 쓸 때(이미지 빌드 없이 배포 단계만):

```bash
SCM_ADMIN_PASSWORD='<SCM 관리자 git 비밀번호>' ./deploy-cicd-portal.sh console security
```

4. 앱을 추가하면 빌드가 Harbor의 base 이미지를 쓴다.
   - Dockerfile의 `FROM ${BASE_REGISTRY}/...` → `CICD_BASE_REGISTRY`
   - 빌드 도구 컨테이너(maven, gradle, node, composer) → `CICD_DOCKERHUB`
   - 이미지 빌드 → `KANIKO_IMAGE`
   - 앱 전용 MariaDB(`DB 연결` → 전용) → `MARIADB_IMAGE`
5. PostgreSQL을 쓰는 앱은 매니페스트(gitops 저장소의 overlay)에서 이미지를
   `harbor.<새 도메인>/base-images/postgres:16-alpine`으로 지정한다.

> 앱 빌드에 필요한 Maven/npm/Composer **라이브러리**는 이미지가 아니라 Nexus로 옮긴다 → [폐쇄망 설치 6장](install-offline.md#6-사내-저장소-nexus-3-앱-빌드-의존성).

---

## 6. 문제 해결

| 증상 | 원인 | 조치 |
|---|---|---|
| 백업 중 `[ERROR] https://harbor...: certificate verify failed` | `cp-portal-deployment/certs/ca.crt`가 지금 Harbor의 CA가 아님 | 지금 환경의 CA를 그 위치에 둔다 |
| 백업 중 `HTTP 401` | `cp-portal-vars.sh`의 Harbor 계정·비밀번호가 다름 | `REPOSITORY_USERNAME`, `REPOSITORY_PASSWORD` 확인 |
| `base-images/...: not in harbor... nor docker.io` | Harbor에도 없고 인터넷도 안 됨 | 인터넷 되는 PC에서 `FROM_DOCKERHUB=1`로 다시 실행하거나, 그 이미지를 지금 Harbor `base-images`에 먼저 넣는다 |
| `Jenkins image with plugins not built` | Jenkins base 이미지(docker.io)를 받지 못함 | 인터넷 연결 확인. scm 업체를 쓰지 않으면 무시 (`JENKINS_PLUGINS=0`) |
| 등록 중 `Cannot create Harbor project` | 새 Harbor 관리자 계정이 다름 | 새 환경 `cp-portal-vars.sh` 확인 |
| 등록 중 `push failed` | 새 Harbor 디스크 부족, 인증서 | Harbor 화면의 **시스템 → 저장소 사용량**, 새 `ca.crt` 확인 후 다시 실행 |
| 파드 `ErrImagePull` / `x509` | 노드에 새 CA 미설치 | 새 환경의 CA를 노드에 설치 후 containerd 재시작 (제어 노드 포함). `./deploy-cicd-portal.sh preflight`의 harbor-pull 점검으로 확인 |
| 파드 `ErrImagePull` / `not found` (`docker.io/...`) | `cicd-vars.sh`에 4-2 값이 반영되지 않음 | 값을 넣고 해당 단계를 다시 배포, 앱은 **앱 추가**를 다시 실행 (gitops 이미지 경로 갱신) |
| `cicd-portal/...` pull `unauthorized` | 비공개 프로젝트 | 정상: 콘솔·스캐너는 배포 스크립트가 만든 robot 계정으로 받는다. 배포를 다시 실행한다 |

---

## 7. 한눈에 보기

```bash
# 지금 K-PaaS
cd ~/Saeoll-PaaS/offline && ./harbor-export.sh ~/harbor-export-$(date +%Y%m%d)
# → harbor-export-<날짜>.tar + .sha256 을 폐쇄망 /opt 로 반입

# 폐쇄망 K-PaaS (CP-Portal 설치 후)
cd /opt && sha256sum -c harbor-export-*.tar.sha256 && sudo tar -xf harbor-export-*.tar -C /opt
cd ~/Saeoll-PaaS/offline && ./load-to-harbor.sh /opt/harbor-export-<날짜>
# → 출력 값을 cicd-portal-deployment/script/cicd-vars.sh 에 반영
cd ~/Saeoll-PaaS/cicd-portal-deployment/script && ./deploy-cicd-portal.sh preflight && ./deploy-cicd-portal.sh
```
