# CI/CD 포털 설치·설정·운영 전체 가이드 (신규 클러스터용)

K-PaaS 컨테이너 플랫폼이 설치된 **새 쿠버네티스 클러스터**에 `cicd-portal-deployment`를 처음 배포하는 사람을 위한
문서다. 명령을 위에서부터 순서대로 복사·실행하면 설치 → 업체 등록 → 앱 추가 → dev 배포 → 운영 배포까지 진행된다.
실제 구축 과정(192.168.20.151.nip.io, 업체 `saeoll`)에서 겪은 오류와 해결 방법도 [12장](#12-문제-해결)에 모았다.

| 문서 | 대상 |
| --- | --- |
| **이 문서** | 설치 담당자·운영 관리자 (처음부터 끝까지) |
| [README](../README.md) | 구성 요약, 변수, 설계 근거 |
| [운영 관리자 가이드](admin-guide.md) | 설치 이후 일상 운영 절차 (GitLab 기준) |
| [SCM 개발자 가이드](vendor-guide-scm.md) / [GitLab 개발자 가이드](vendor-guide.md) | 업체(개발자)에게 전달 |

---

## 목차

1. [CI/CD 포털이란](#1-cicd-포털이란)
2. [용어 정리](#2-용어-정리)
3. [사전 조건](#3-사전-조건)
4. [폴더·파일 구성과 sh 파일 설명](#4-폴더파일-구성과-sh-파일-설명)
5. [설치 전 설정 (cicd-vars.sh)](#5-설치-전-설정-cicd-varssh)
6. [설치](#6-설치)
7. [설치 후 확인과 로그인](#7-설치-후-확인과-로그인)
8. [업체 등록 (onboard-vendor.sh)](#8-업체-등록-onboard-vendorsh)
9. [앱 추가 (add-app.sh)](#9-앱-추가-add-appsh)
10. [개발 → dev 배포 → 운영 배포](#10-개발--dev-배포--운영-배포)
11. [일상 운영](#11-일상-운영)
12. [문제 해결](#12-문제-해결)
13. [삭제](#13-삭제)
14. [부록: 명령 모음](#14-부록-명령-모음)

---

## 1. CI/CD 포털이란

업체(유지보수사·내부 팀)가 소스를 올리면 **자동으로 빌드·테스트·이미지 생성·배포**까지 해 주는 시스템이다.
K-PaaS 기본 파이프라인(`cp-pipeline`)과 소스 컨트롤(`cp-source-control`)은 **건드리지 않고 옆에 별도로** 설치한다.
지원 언어: Java(Gradle·Maven), PHP, Node.js, Vue.

### 1-1. 두 가지 소스 방식

업체를 등록할 때 업체마다 하나를 고른다(`--source scm` 또는 `--source gitlab`). 두 방식을 함께 설치할 수 있다.

| 방식 | 소스 저장소 | 빌드(CI) | 누구에게 | 비고 |
| --- | --- | --- | --- | --- |
| `scm` | K-PaaS 소스 컨트롤 (`scm.<도메인>`, SCM-Manager 1.x) | **Jenkins** | 내부 팀, 기존 SCM 사용자 | 추가 자원 적음. **웹 화면에서 모든 저장소가 보이는 한계** |
| `gitlab` | GitLab CE (`gitlab.<도메인>`) | GitLab Runner | **외부 업체** | 업체 간 소스 분리, 코드 리뷰(MR). CPU 2·메모리 4Gi 이상 추가 필요 |

> **주의(실측)**: K-PaaS 소스 컨트롤 웹 화면은 로그인한 **모든 사용자에게 모든 저장소의 파일**을 보여 준다.
> git clone/push만 참여자 권한으로 막힌다. 외부 업체에 소스를 숨겨야 하면 `gitlab`을 쓴다.

### 1-2. 전체 흐름 (scm 방식)

```text
 개발자 PC
   │ git push (develop)
   ▼
 scm.<도메인>  K-PaaS 소스 컨트롤 ─ 저장소 <업체>-<앱>, <업체>-gitops
   │ Jenkins가 5분마다 확인(Poll SCM)
   ▼
 jenkins.<도메인>  Jenkins ─ 빌드용 Pod를 그때그때 생성 (빌드 도구 컨테이너 + kaniko)
   │ ① 빌드·테스트  ② 이미지 생성 → Harbor push  ③ gitops 저장소의 이미지 태그 변경
   ▼
 harbor.<도메인>  Harbor ─ 업체별 프로젝트에 이미지 저장
   │
 argocd.<도메인>  Argo CD ─ gitops 저장소를 3분마다 확인
   │ dev: 자동 배포 / prod: 운영 관리자가 SYNC 버튼으로 승인
   ▼
 <업체>-dev, <업체>-prod 네임스페이스 ─ https://<앱>-<업체>-dev.<도메인>, https://<앱>-<업체>.<도메인>
```

gitlab 방식은 `scm.`→`gitlab.`, Jenkins→GitLab Runner로 바뀔 뿐 Harbor·Argo CD 이후는 같다.

### 1-3. 설치되는 것 / 기존 시스템에 추가되는 것

| 구분 | 내용 | 네임스페이스 |
| --- | --- | --- |
| 새로 설치 | Jenkins (scm) | `cicd-jenkins` |
| 새로 설치 | GitLab CE + GitLab Runner (gitlab) | `cicd-gitlab`, `cicd-runner` |
| 새로 설치 | Argo CD (공통) | `cicd-argocd` |
| Keycloak `cp-realm`에 추가 | 클라이언트 `cicd-jenkins`·`cicd-gitlab`·`cicd-argocd`, 그룹 `cicd-admins`·`cicd-<업체>` | `keycloak` |
| Harbor에 추가 | 업체별 프로젝트, robot 계정 `robot$<업체>+cicd` | - |
| 업체별 생성 | 배포용 네임스페이스 `<업체>-dev`, `<업체>-prod` | - |

---

## 2. 용어 정리

| 용어 | 뜻 |
| --- | --- |
| CI | 소스를 받아 빌드·테스트하고 컨테이너 이미지를 만드는 과정 (Jenkins / GitLab Runner) |
| CD | 만든 이미지를 쿠버네티스에 배포하는 과정 (Argo CD) |
| GitOps | "어떤 이미지 버전을 배포할지"를 Git 저장소(gitops 저장소)에 적어 두고, Argo CD가 그대로 맞춰 주는 방식 |
| gitops 저장소 | 업체별 배포 설정 저장소 `<업체>-gitops`. `apps/<앱>/overlays/dev|prod/kustomization.yaml`의 `newTag`가 배포 버전 |
| kustomize | 쿠버네티스 YAML을 base(공통) + overlay(dev/prod 차이)로 나눠 관리하는 도구 |
| kaniko | Docker 데몬 없이 Pod 안에서 컨테이너 이미지를 만드는 도구 |
| Harbor | 사내 컨테이너 이미지 저장소 |
| Keycloak / SSO | K-PaaS 통합 로그인. Jenkins·Argo CD·GitLab이 같은 계정으로 로그인한다 |
| `cicd-admins` | 운영 관리자 Keycloak 그룹. Jenkins·Argo CD 관리자, **운영 배포 승인** 권한 |
| `cicd-<업체>` | 업체 Keycloak 그룹. 자기 업체 Jenkins 폴더·Argo CD 앱만 조회·빌드·dev 배포 |
| CI 계정 | Jenkins·Argo CD가 SCM 저장소에 접근할 때 쓰는 계정(기본 `jenkins-<업체>`) |
| Sync | Argo CD가 gitops 저장소 내용을 클러스터에 적용하는 것 |
| `none-yet` | 앱 추가 직후 gitops에 들어가는 임시 이미지 태그. 첫 빌드가 성공하면 실제 태그로 바뀐다 |

---

## 3. 사전 조건

### 3-1. 클러스터·K-PaaS 구성 요소

| 항목 | 확인 명령 | 기대 결과 |
| --- | --- | --- |
| K-PaaS 컨테이너 플랫폼 + CP-Portal 배포 완료 | `kubectl -n cp-portal get pod` | 모두 Running |
| Keycloak | `kubectl -n keycloak get pod` | Running |
| Harbor | 브라우저 `https://harbor.<도메인>` | admin 로그인 가능 |
| K-PaaS 소스 컨트롤 (scm 사용 시) | `kubectl -n cp-source-control get pod` | Running, `https://scm.<도메인>` 로그인 가능 |
| IngressClass | `kubectl get ingressclass` | `nginx` |
| StorageClass | `kubectl get storageclass` | `cp-storageclass` 등 (CP-Portal과 같은 것) |
| TLS secret | `kubectl -n cp-portal get secret <도메인>-tls` | 존재 |
| K-PaaS CA 인증서 | `ls ~/Saeoll-PaaS/cp-portal-deployment/certs/ca.crt` | 존재 |
| CP-Portal 변수 파일 | `ls ~/Saeoll-PaaS/cp-portal-deployment/script/cp-portal-vars.sh` | 존재 (도메인·Keycloak·Harbor 값을 여기서 읽음) |

K-PaaS 소스 컨트롤이 아직 없다면 [`cp-source-control-deployment`](../../cp-source-control-deployment/README.md)로 먼저 설치한다.

### 3-2. 작업 서버(Master Node) 도구

```bash
# Rocky Linux 9 기준
dnf install -y git curl python3
kubectl version --client && helm version && git --version && python3 --version
```

`kubectl`·`helm`은 K-PaaS 설치 때 이미 들어 있다. 스크립트는 `python3` 기본 라이브러리만 쓰므로 pip 설치는 필요 없다.

### 3-3. 자원

| 구성 | 요청(request) | 상한 | 디스크(PVC) |
| --- | --- | --- | --- |
| Jenkins (scm) | 0.5 CPU / 1Gi | 3Gi | 20Gi |
| Argo CD | 약 1Gi | - | - |
| GitLab (gitlab) | 2 CPU / 4Gi | 8Gi | 56Gi |
| 빌드 Pod (빌드할 때만) | 0.5 CPU / 1Gi | 최대 6Gi | - |
| 업체 네임스페이스 1개 | quota CPU 4 / 8Gi / Pod 30 (변경 가능) | | |

`kubectl top nodes`로 여유를 확인한다(metrics-server 필요).

### 3-4. 인터넷 접근 (설치·빌드 시)

| 대상 | 용도 |
| --- | --- |
| `charts.jenkins.io`, `updates.jenkins.io`, `get.jenkins.io` | Jenkins 차트·플러그인 |
| `argoproj.github.io`, `quay.io`, `ghcr.io` | Argo CD |
| Docker Hub (`docker.io`) | 빌드 도구 이미지(composer, gradle, node …), 베이스 이미지(php, nginx …) |
| `gcr.io` | kaniko |
| `packagist.org`, `registry.npmjs.org`, Maven Central 등 | 빌드 중 의존성 다운로드 |

폐쇄망이면 Harbor에 미러를 만들고 `CICD_DOCKERHUB`·`CICD_BASE_REGISTRY`를 Harbor 주소로 바꾼다([5장](#5-설치-전-설정-cicd-varssh)).

### 3-5. 미리 알아 둘 정보

| 정보 | 어디서 | 비고 |
| --- | --- | --- |
| 도메인 (`HOST_DOMAIN`) | `cp-portal-vars.sh` | 예: `192.168.20.151.nip.io` |
| Keycloak 관리자 계정 | `cp-portal-vars.sh` | 스크립트가 자동으로 읽음 |
| Harbor 관리자 계정 | `cp-portal-vars.sh` | 스크립트가 자동으로 읽음 |
| **SCM 관리자 `scmadmin` 비밀번호** (scm) | K-PaaS 설치 시 기본값 | K-PaaS가 내부적으로 쓰는 계정이므로 **함부로 바꾸지 않는다** |
| 운영 관리자 Keycloak 계정 | Keycloak `cp-realm` | `cicd-admins` 그룹에 들어갈 사람. CP-Portal 관리자는 자동 추가 |

> **비밀번호 입력 요령**: 명령줄에 비밀번호를 직접 쓰면 셸 기록(history)에 남는다. 아래처럼 입력받아 쓴다.
> ```bash
> read -rsp 'scmadmin 비밀번호: ' SCM_ADMIN_PASSWORD; echo; export SCM_ADMIN_PASSWORD
> ```

---

## 4. 폴더·파일 구성과 sh 파일 설명

```text
cicd-portal-deployment/
├── README.md                 구성 요약
├── docs/                     가이드 문서 (이 문서, 관리자·업체 가이드)
├── script/                   ★ 실행 스크립트 (항상 이 폴더에서 실행)
│   ├── cicd-vars.sh          설정 값 (설치 전 수정)
│   ├── lib.sh                공통 함수 (직접 실행하지 않음)
│   ├── cicd_api.py           Keycloak·Harbor·SCM·Jenkins·GitLab API 호출 도구 (직접 실행하지 않음)
│   ├── deploy-cicd-portal.sh 설치·재설정
│   ├── check-cicd-portal.sh  상태 점검 (읽기 전용)
│   ├── onboard-vendor.sh     업체 등록
│   ├── add-app.sh            업체에 앱(서비스) 추가
│   ├── migrate-vendor.sh     scm 업체를 gitlab으로 이전
│   └── uninstall-cicd-portal.sh 삭제
├── values_orig/              Helm 값 원본 (jenkins.yaml, jenkins-sso.yaml, argocd.yaml, gitlab-runner.yaml)
├── values/                   설치 시 values_orig에 실제 값을 채워 만든 파일 (자동 생성)
├── manifests/gitlab.yaml     GitLab CE 배포 YAML
├── starters/<유형>/           언어별 시작 소스: Dockerfile, Jenkinsfile, .gitlab-ci.yml, 샘플 앱
├── gitops-template/          앱별 배포 YAML 원본: base(Deployment·Service·Ingress) + overlays/dev,prod
└── ci-templates/             GitLab CI 공용 템플릿
```

### 4-1. sh 파일 한눈에 보기

| 파일 | 언제 | 하는 일 | 다시 실행해도 되나 |
| --- | --- | --- | --- |
| `cicd-vars.sh` | 설치 전 1회 수정 | 설치할 소스, 버전, 이미지 주소 등 설정 | (설정 파일) |
| `deploy-cicd-portal.sh` | 설치, 설정 변경 시 | Keycloak 클라이언트, Jenkins/GitLab/Argo CD 설치 | O |
| `check-cicd-portal.sh` | 설치 후, 매일 | Pod·접속·로그인·앱 상태 점검 | O (변경 없음) |
| `onboard-vendor.sh` | 업체 추가·인원 변경 | 업체 그룹·Harbor·네임스페이스·Jenkins 폴더·Argo CD 프로젝트 | O |
| `add-app.sh` | 앱 추가 | 시작 소스·gitops·Jenkins 잡·Argo CD 앱 | O (기존 파일은 덮어쓰지 않음) |
| `migrate-vendor.sh` | scm→gitlab 이전 | 저장소 이력째 복사, 배포 대상 전환 | O |
| `uninstall-cicd-portal.sh` | 삭제 | 구성 요소 삭제 | - |

모든 스크립트는 **실패한 지점부터 같은 명령을 다시 실행**하면 이어서 진행되도록 만들었다(멱등).

### 4-2. deploy-cicd-portal.sh (설치)

```text
사용법: [CICD_SOURCES="scm gitlab"] ./deploy-cicd-portal.sh [단계 ...]
단계 생략 시: preflight keycloak [jenkins] [gitlab bootstrap templates runner] argocd  (설치할 소스에 맞춰 자동)
```

| 단계 | 소스 | 하는 일 |
| --- | --- | --- |
| `preflight` | 공통 | 도구·StorageClass·TLS·CA·Keycloak·IngressClass 확인, SCM 실행·`scmadmin` 로그인 확인, 노드 자원 출력. 문제를 모두 모아 보여 주고 실패하면 중단 |
| `keycloak` | 공통 | `cp-realm`에 클라이언트(`cicd-jenkins`, `cicd-gitlab`, `cicd-argocd`)와 groups 매퍼 추가, 그룹 `cicd-admins` 생성 후 Keycloak 관리자 추가. 클라이언트 비밀값은 Secret `cicd-portal-secrets`에 저장 |
| `jenkins` | scm | Jenkins Helm 설치(`jenkins/jenkins` 공식 차트): K-PaaS SSO(oic-auth), 권한(projectMatrix), K-PaaS CA를 JVM에 등록, 플러그인 설치, Ingress. 설정 오류로 재시작 중인 Pod는 새 설정으로 다시 만든다 |
| `jenkins-token` | scm | (설치 후 1회) 스크립트가 쓸 Jenkins API 토큰을 Secret에 저장 |
| `gitlab` | gitlab | GitLab CE 배포 (`manifests/gitlab.yaml`) |
| `bootstrap` | gitlab | GitLab 기본 설정, 자동화 토큰, 인스턴스 CI 변수 |
| `templates` | gitlab | CI 공용 템플릿 프로젝트(`cicd/ci-templates`) 갱신 |
| `runner` | gitlab | GitLab Runner(Kubernetes executor) 설치·등록 |
| `argocd` | 공통 | Argo CD Helm 설치: K-PaaS SSO, `cicd-admins`=관리자, 모든 구성 요소 준비 대기 |

단계 하나만 다시 실행할 수 있다. 예: Jenkins 설정만 다시 적용 → `./deploy-cicd-portal.sh jenkins`

### 4-3. check-cicd-portal.sh (점검)

```bash
./check-cicd-portal.sh                                   # 기본 점검
SCM_ADMIN_PASSWORD="$SCM_ADMIN_PASSWORD" ./check-cicd-portal.sh   # SCM 로그인까지 점검
```
Pod 상태, 각 URL 응답, Keycloak 클라이언트, API 로그인, 업체별 소스, Argo CD 앱 상태를 확인하고 마지막에 `[RESULT] OK` 또는 실패 항목을 출력한다. 아무것도 바꾸지 않는다.

### 4-4. onboard-vendor.sh (업체 등록)

```text
사용법: [PM_USERS=pm1] ./onboard-vendor.sh [--source scm|gitlab] <업체ID> [사용자1,사용자2,...]
```

| 인자·환경변수 | 설명 |
| --- | --- |
| `--source` | `scm` 또는 `gitlab`. 처음 등록할 때만 필요(이후 기억됨). 바꾸려면 `migrate-vendor.sh` |
| `<업체ID>` | 영문 소문자·숫자·`-`, 30자 이내. Harbor 프로젝트·네임스페이스·Jenkins 폴더 이름이 된다 (예: `saeoll`) |
| `[사용자 목록]` | Keycloak 사용자 ID(쉼표 구분). 그룹 `cicd-<업체>`에 추가된다 |
| `SCM_ADMIN_PASSWORD` | (scm) `scmadmin`의 git 비밀번호 |
| `SCM_CI_USER` | (scm) CI 계정. 기본 `jenkins-<업체>`(자동 생성). 기존 계정을 쓰려면 지정(예: `saeoll`) |
| `SCM_CI_PASSWORD` | (scm) CI 계정의 **git 비밀번호**(SCM 내정보 관리에서 설정한 것) |
| `SCM_CREATE_GITOPS=0` | (scm) gitops 저장소를 자동 생성하지 않음 |
| `PM_USERS` | (gitlab) Maintainer 권한 사용자 |
| `QUOTA_CPU`, `QUOTA_MEMORY`, `QUOTA_PODS` | 업체 네임스페이스 자원 한도 (기본 4 / 8Gi / 30) |

할 일이 남으면(예: CI 계정 git 비밀번호 미설정) **목록을 출력하고 종료 코드 3**으로 끝난다. 처리 후 다시 실행한다.

### 4-5. add-app.sh (앱 추가)

```text
사용법: ./add-app.sh <업체ID> <앱이름> <java-gradle|java-maven|php|node|vue> [헬스체크경로]
```

| 환경변수 | 설명 |
| --- | --- |
| `SCM_ADMIN_PASSWORD` | (scm) 필수 |
| `SCM_REPO=<저장소>` | (scm) 소스 저장소 이름이 `<업체>-<앱>`이 아닐 때 (예: 기존 저장소 `saeoll`) |
| `REPLACE_CI=1` | 저장소의 기존 Jenkinsfile을 포털용으로 교체 |
| `SKIP_STARTER=1` | 시작 소스를 넣지 않음(자기 소스를 이미 올린 경우) |

헬스체크 경로 기본값: PHP `/healthz.php`, 그 외 `/healthz`.

### 4-6. migrate-vendor.sh / uninstall-cicd-portal.sh

```bash
SCM_ADMIN_PASSWORD=... PM_USERS=<PM> ./migrate-vendor.sh <업체> <개발자들>   # scm → gitlab 이전 (11-6)
./uninstall-cicd-portal.sh <scm|gitlab|all>                                 # 삭제 (13장)
```

---

## 5. 설치 전 설정 (cicd-vars.sh)

```bash
cd ~
git clone <이 저장소 주소> Saeoll-PaaS          # 이미 있으면: cd ~/Saeoll-PaaS && git pull
cd ~/Saeoll-PaaS/cicd-portal-deployment/script
vi cicd-vars.sh
```

대부분 기본값 그대로 쓴다. **도메인·StorageClass·Keycloak·Harbor는 `cp-portal-vars.sh`에서 자동으로 읽으므로 고치지 않는다.**

| 변수 | 기본값 | 바꾸는 경우 |
| --- | --- | --- |
| `CICD_SOURCES` | `"scm gitlab"` | 하나만 쓸 때 `"scm"` 또는 `"gitlab"`. 자원이 부족하면 `"scm"`부터 시작 |
| `SCM_ADMIN_USER` | `scmadmin` | K-PaaS 기본값 유지 |
| `JENKINS_CHART_VERSION` | (빈 값 = 최신) | 첫 설치 후 출력된 버전(예: `5.9.73`)으로 고정 권장 |
| `JENKINS_SSO` | `true` | SSO 장애 조사 시 일시적으로 `false` |
| `JENKINS_DATA_SIZE` | `20Gi` | 빌드 이력이 많으면 증가 |
| `ARGOCD_CHART_VERSION` | `7.8.0` | (Argo CD 2.14) |
| `GITLAB_IMAGE` | `gitlab/gitlab-ce:17.11.1-ce.0` | 최신 패치로 |
| `CICD_DOCKERHUB` | `docker.io/library` | 폐쇄망: `harbor.<도메인>/base-images` |
| `CICD_BASE_REGISTRY` | `docker.io/library` | 폐쇄망: `harbor.<도메인>/base-images` |
| `KANIKO_IMAGE` | `gcr.io/kaniko-project/executor:v1.23.2-debug` | 폐쇄망이면 Harbor 미러 |

변수는 파일 수정 대신 명령 앞에 붙여 일회성으로 바꿀 수도 있다. 예: `CICD_SOURCES=scm ./deploy-cicd-portal.sh`

---

## 6. 설치

이하 모든 명령은 `~/Saeoll-PaaS/cicd-portal-deployment/script`에서 실행한다.

### 6-1. (scm) scmadmin 비밀번호 준비

`scmadmin`의 비밀번호는 SCM 웹(`scm.<도메인>`)에서 쓰는 **git 비밀번호**다(Keycloak 비밀번호와 별개일 수 있음).

```bash
read -rsp 'scmadmin 비밀번호: ' SCM_ADMIN_PASSWORD; echo; export SCM_ADMIN_PASSWORD
```

### 6-2. 사전 점검

```bash
./deploy-cicd-portal.sh preflight
```

`[OK] Preflight passed`가 나와야 한다. `[WARN]` 항목이 있으면 [12-1](#12-1-설치-단계)을 보고 해결한 뒤 다시 실행한다.

### 6-3. 설치 실행

```bash
./deploy-cicd-portal.sh 2>&1 | tee cicd-portal-deploy.log
```

- 처음 실행 시 Jenkins 플러그인 다운로드로 **5~15분** 걸린다. GitLab은 첫 기동에 10분 이상 걸린다.
- 중간에 실패하면 원인을 해결하고 **같은 명령을 다시 실행**한다(이미 된 것은 건너뜀).
- 마지막에 각 시스템 주소와 비상 계정 조회 명령이 출력된다.

### 6-4. (scm) Jenkins API 토큰 등록 — 반드시 1회

`onboard-vendor.sh`·`add-app.sh`가 Jenkins에 폴더·잡을 만들 때 이 토큰을 쓴다.

1. 브라우저에서 `https://jenkins.<도메인>` → **K-PaaS SSO**로 `cicd-admins` 그룹 사용자(예: Keycloak `admin`)로 로그인
2. 오른쪽 위 사용자 이름 → **Security** → API Token **Add new Token** → 이름 입력 → **Generate** → 토큰 복사
   (창을 닫으면 다시 볼 수 없다)
3. 서버에서 등록:
   ```bash
   read -rsp 'Jenkins API 토큰: ' JENKINS_API_TOKEN; echo
   JENKINS_USER=admin JENKINS_API_TOKEN="$JENKINS_API_TOKEN" ./deploy-cicd-portal.sh jenkins-token
   ```
   `[OK] Jenkins API token stored for admin`이 나오면 완료.

### 6-5. Jenkins 차트 버전 고정 (권장)

설치 로그의 `[OK] Jenkins: https://... (chart jenkins-5.9.73)`에서 버전을 확인해 `cicd-vars.sh`에 적는다.
```bash
sed -i 's/^JENKINS_CHART_VERSION=""/JENKINS_CHART_VERSION="5.9.73"/' cicd-vars.sh
```
고정하지 않으면 나중에 `deploy-cicd-portal.sh jenkins`를 다시 실행할 때 예상치 못한 최신 버전으로 바뀔 수 있다.

---

## 7. 설치 후 확인과 로그인

### 7-1. 점검

```bash
./check-cicd-portal.sh
kubectl get pod -n cicd-jenkins; kubectl get pod -n cicd-argocd
```
`[RESULT] OK`, 모든 Pod Running이면 정상.

### 7-2. 로그인 확인

| 시스템 | 주소 | 로그인 | 비상 계정 |
| --- | --- | --- | --- |
| Jenkins | `https://jenkins.<도메인>` | K-PaaS SSO | (없음, `JENKINS_SSO=false`로 전환 시 로컬 admin) |
| Argo CD | `https://argocd.<도메인>` | **LOG IN VIA K-PAAS SSO** | `admin` / 아래 명령 |
| GitLab | `https://gitlab.<도메인>` | K-PaaS SSO | `root` / 아래 명령 |
| SCM | `https://scm.<도메인>` | K-PaaS 계정 | - |

```bash
kubectl -n cicd-argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n cicd-gitlab get secret cicd-portal-secrets -o jsonpath='{.data.root-password}' | base64 -d; echo
```

### 7-3. 운영 관리자 지정

Keycloak 관리 콘솔(`https://keycloak.<도메인>/admin`) → realm **cp-realm** → **Groups** → `cicd-admins` → **Members** → **Add member**.
추가된 사람은 Jenkins·Argo CD에서 **로그아웃 후 다시 로그인**해야 권한이 반영된다.

> 브라우저에 사설 인증서 경고("주의 요함")가 뜨는 것은 K-PaaS 사설 CA 때문이며 동작에는 문제없다.
> 경고를 없애려면 `cp-portal-deployment/certs/ca.crt`를 PC의 신뢰할 수 있는 루트 인증서로 등록한다.

---

## 8. 업체 등록 (onboard-vendor.sh)

예시: 업체 ID `saeoll`, 개발자 Keycloak 계정 `saeoll`.

### 8-1. 공통 준비: 업체 사용자 계정

Keycloak `cp-realm` → **Users** → **Add user**: Username, **Email(필수, GitLab 로그인에 필요)**, Email verified 켬 → 저장 →
**Credentials** → 임시 비밀번호(Temporary 켬). CP-Portal에서 만든 사용자를 그대로 써도 된다.

### 8-2. scm 업체 등록

**방법 A: 전용 CI 계정 사용 (권장, 기본값)**

```bash
# 1차 실행: Keycloak에 CI 계정 jenkins-saeoll 생성 후 "남은 할 일"을 출력하고 종료(코드 3)
./onboard-vendor.sh --source scm saeoll saeoll
```
출력된 할 일:
1. 출력된 명령으로 `jenkins-saeoll`의 Keycloak 임시 비밀번호 확인
2. 그 계정으로 `https://scm.<도메인>` **최초 로그인** → 오른쪽 위 계정 → **내정보 관리** → **비밀번호 변경**
   (이것이 git 비밀번호. 변경하지 않으면 git 접근 불가)
3. 2차 실행:
   ```bash
   read -rsp 'jenkins-saeoll git 비밀번호: ' SCM_CI_PASSWORD; echo; export SCM_CI_PASSWORD
   ./onboard-vendor.sh saeoll saeoll
   ```

**방법 B: 기존 계정을 CI 계정으로 사용** (계정이 이미 SCM에 로그인해 git 비밀번호를 설정해 둔 경우)

```bash
read -rsp 'saeoll git 비밀번호: ' SCM_CI_PASSWORD; echo; export SCM_CI_PASSWORD
SCM_CI_USER=saeoll ./onboard-vendor.sh --source scm saeoll saeoll
```
이 계정의 git 비밀번호를 나중에 바꾸면 같은 명령을 다시 실행해 Jenkins·Argo CD에 저장된 비밀번호를 갱신한다.

**만들어지는 것**

| 시스템 | 생성물 |
| --- | --- |
| Keycloak | 그룹 `cicd-saeoll`(지정 사용자 포함), (방법 A) 사용자 `jenkins-saeoll` |
| Harbor | 비공개 프로젝트 `saeoll`, robot 계정 `robot$saeoll+cicd` |
| Kubernetes | `saeoll-dev`, `saeoll-prod` (quota, 기본 메모리 512Mi, 이미지 pull secret `harbor-cicd`, TLS) |
| SCM | 배포 설정 저장소 `saeoll-gitops`(없으면 자동 생성, CI 계정 쓰기 권한) |
| Jenkins | 폴더 `saeoll`(그룹 `cicd-saeoll`만 조회·빌드), 폴더 credential `saeoll-harbor`, `saeoll-scm` |
| Argo CD | 프로젝트 `saeoll`(배포 대상 2개 네임스페이스로 제한, 업체는 dev만 Sync) |

> `saeoll-gitops`는 SCM-Manager API로 만들기 때문에 `scm.` 화면의 저장소 목록에는 나오지 않는다(정상).
> SCM-Manager 관리 화면(`https://scm-manager.<도메인>/scm`, scmadmin)에서는 보인다.

### 8-3. gitlab 업체 등록

1. 업체 사용자가 `https://gitlab.<도메인>`에 **한 번 로그인**(K-PaaS SSO) → GitLab 계정 생성
2. 실행:
   ```bash
   PM_USERS=saeoll-pm ./onboard-vendor.sh --source gitlab saeoll saeoll-hong,saeoll-kim
   ```
   `GitLab user ... not found` 경고는 아직 로그인하지 않은 사용자다. 로그인 후 같은 명령을 다시 실행한다.

자세한 내용: [운영 관리자 가이드 4장](admin-guide.md#4-업체-등록)

---

## 9. 앱 추가 (add-app.sh)

### 9-1. scm: 새 저장소로 시작

1. `https://scm.<도메인>`에서 저장소 `saeoll-homepage` 생성(유형 Git)
2. 참여자 추가: CI 계정(`jenkins-saeoll` 또는 `saeoll`) **보기 권한**, 개발자 **쓰기 권한**
3. 실행:
   ```bash
   ./add-app.sh saeoll homepage php        # SCM_ADMIN_PASSWORD 가 export 되어 있어야 함
   ```

### 9-2. scm: 이미 있는 저장소 사용 (실제 사례: 저장소 `saeoll`, 앱 `php-service`)

```bash
SCM_REPO=saeoll REPLACE_CI=1 ./add-app.sh saeoll php-service php
```
- 저장소에 `main`이 없고 `master`만 있으면 `master` 이력으로 `main`·`develop`을 만든다(`master`는 그대로 둔다).
- 시작 소스 파일(Dockerfile, Jenkinsfile, 샘플)은 **없는 파일만** 추가된다. 기존 Dockerfile은 바뀌지 않으므로
  [9-4 저장소 규칙](#9-4-저장소-규칙-업체에-전달)에 맞는지 확인한다.
- `REPLACE_CI=1`: 예전 K-PaaS 파이프라인용 Jenkinsfile을 포털용으로 교체한다.

### 9-3. 만들어지는 것

| 대상 | 내용 |
| --- | --- |
| 소스 저장소 | 시작 소스를 `main`에 push, `develop` 브랜치 생성 |
| gitops 저장소 | `apps/<앱>/base` (Deployment·Service·Ingress) + `overlays/dev`, `overlays/prod` (이미지 태그 `none-yet`) |
| Jenkins | `saeoll/<앱>-dev` (develop 5분 폴링) + **첫 빌드 자동 실행**, `saeoll/<앱>-release` (RELEASE_TAG 입력) |
| Argo CD | `saeoll-<앱>-dev` (자동 Sync), `saeoll-<앱>-prod` (수동 Sync) |
| URL | dev `https://<앱>-saeoll-dev.<도메인>`, prod `https://<앱>-saeoll.<도메인>` |

> 첫 빌드가 성공하기 전까지 dev 앱은 **Degraded / ImagePullBackOff**(이미지 `none-yet` not found)로 보인다. 정상이다.

### 9-4. 저장소 규칙 (업체에 전달)

| 파일 | 규칙 |
| --- | --- |
| `Dockerfile` | 컨테이너가 **8080 포트**로 서비스, `FROM ${BASE_REGISTRY}/...` 형식 |
| 헬스 체크 | `GET /healthz`(PHP는 `/healthz.php`)가 200 응답 |
| `Jenkinsfile` | `starters/<유형>/Jenkinsfile` 기반. 상단 `buildScript`, `testScript`, `buildImage`, `junitReports`만 수정 |
| PHP 베이스 이미지 | `php:8.3-apache-bookworm` 사용 (trixie 기반 `php:8.3-apache`는 kaniko에서 실패, [12-3](#12-3-빌드-jenkins)) |

---

## 10. 개발 → dev 배포 → 운영 배포

### 10-1. 개발자 PC 준비 (scm)

```bash
git config --global http.https://scm-manager.<도메인>/.sslCAInfo ~/kpaas-ca.crt     # ca.crt 를 받아 둔 경로
git clone -b develop https://scm-manager.<도메인>/scm/git/saeoll-homepage            # ID / git 비밀번호
```
SCM 저장소의 기본 브랜치는 `master`로 표시되므로 **반드시 `-b develop`**으로 받는다.
`master`에 push하면 빌드되지 않는다(실제로 겪은 실수).

### 10-2. dev 배포 (자동)

```bash
git checkout develop
# ... 수정 ...
git commit -am "기능 추가" && git push origin develop
```

| 순서 | 어디서 확인 | 기대 결과 |
| --- | --- | --- |
| 1 | Jenkins `saeoll` → `<앱>-dev` | 5분 안에 새 빌드 시작(급하면 **Build Now**). Stage: Checkout → Build → Test → Image → Deploy |
| 2 | 빌드 Console Output 끝 | `Pushed harbor.<도메인>/saeoll/<앱>:dev-xxxxxxxx-N`, `gitops ... -> dev-...`, `Finished: SUCCESS` |
| 3 | Harbor 프로젝트 `saeoll` | 저장소 `saeoll/<앱>`에 태그 `dev-...` |
| 4 | Argo CD `saeoll-<앱>-dev` | 3분 안에 Synced / **Healthy** (급하면 ⟳ REFRESH) |
| 5 | `kubectl -n saeoll-dev get pod` | Running |
| 6 | `https://<앱>-saeoll-dev.<도메인>` | 서비스 응답 |

### 10-3. 운영 배포 (관리자 승인)

1. (업체) `develop`을 `main`에 합치고 태그 생성:
   ```bash
   git checkout main && git pull && git merge --no-ff develop
   git tag -a v1.0.0 -m "v1.0.0" && git push origin main --follow-tags
   ```
2. (업체 또는 관리자) Jenkins `saeoll/<앱>-release` → **Build with Parameters** → `RELEASE_TAG=v1.0.0` → **Build**
   → 성공 시 Harbor에 `v1.0.0` 이미지, gitops `overlays/prod` 태그 갱신
3. (관리자, `cicd-admins`) Argo CD `saeoll-<앱>-prod` → ⟳ REFRESH → **SYNC** → 옵션은 기본값 그대로 → **SYNCHRONIZE**
4. Healthy / Synced 확인 → `https://<앱>-saeoll.<도메인>` 확인

> 업체 계정으로 prod SYNC를 누르면 `permission denied: applications, sync, saeoll/saeoll-<앱>-prod`가 나온다.
> **설계된 동작**이다(운영 배포는 `cicd-admins`만). release 빌드 전에 SYNC하면 `none-yet` 이미지로 실패하므로 순서를 지킨다.

### 10-4. (선택) 운영도 자동 배포로 바꾸기 — 소스 수정 없이

release 빌드가 끝나면 바로 운영에 반영되게 할 수 있다. 이때 **승인 지점이 "release 잡 실행"으로 바뀌므로**,
release 잡을 관리자만 실행하도록 함께 설정한다.

**① prod 자동 Sync 켜기** — Argo CD 앱 → **DETAILS** → SYNC POLICY **ENABLE AUTO-SYNC**(PRUNE·SELF HEAL 켬), 또는:
```bash
kubectl -n cicd-argocd patch applications.argoproj.io saeoll-<앱>-prod --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```
되돌리기: `--type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'`

**② release 잡을 관리자 전용으로** — Jenkins(admin) → `saeoll` → `<앱>-release` → **Configure** →
**Enable project-based security** → Inheritance Strategy **Do not inherit permission grants from other ACLs** →
그룹 `cicd-admins`에 Job Read·Build·Cancel, Run Replay 체크 → **Save**

주의: `add-app.sh`를 다시 실행하면 prod는 수동 Sync로 돌아간다(①만 다시 설정). 자동 Sync 중에는 Argo CD
History Rollback 대신 이전 태그로 release를 다시 빌드해 롤백한다.

### 10-5. 롤백

| 대상 | 방법 |
| --- | --- |
| dev | `git revert` 후 develop push, 또는 Jenkins 이전 성공 빌드의 **Replay** |
| prod (수동 Sync) | Argo CD → **HISTORY AND ROLLBACK** → 이전 리비전 **Rollback**, 이후 gitops `overlays/prod` `newTag`도 이전 값으로 커밋 |
| prod (자동 Sync) | `<앱>-release`를 이전 태그(`RELEASE_TAG=v1.0.0`)로 다시 빌드 |

---

## 11. 일상 운영

### 11-1. 정기 작업

| 주기 | 작업 | 명령·위치 |
| --- | --- | --- |
| 매일 | 상태 점검 | `SCM_ADMIN_PASSWORD=... ./check-cicd-portal.sh` |
| 매주 | Jenkins 백업 | Jenkins PVC(`kubectl -n cicd-jenkins get pvc`) 스냅샷, 또는 `kubectl -n cicd-jenkins exec jenkins-0 -c jenkins -- tar czf - --exclude=workspace -C /var/jenkins_home . > jenkins-home.tgz` |
| 매주 | GitLab 백업 (gitlab) | `kubectl -n cicd-gitlab exec deploy/gitlab -- gitlab-backup create` |
| 매월 | Harbor 취약점 스캔 확인, 베이스 이미지 갱신 | Harbor 화면 |
| 분기 | Jenkins 플러그인·보안 업데이트 | `./deploy-cicd-portal.sh jenkins` (차트 버전 올릴 때는 `JENKINS_CHART_VERSION` 변경) |

SCM 저장소는 K-PaaS 소스 컨트롤 PVC에, 배포 설정은 gitops 저장소에 있으므로 Argo CD는 별도 백업이 필요 없다.

### 11-2. 인원 변경

| 작업 | 방법 |
| --- | --- |
| 업체 개발자 추가 | Keycloak 사용자 생성 → `./onboard-vendor.sh saeoll <기존,신규>` 재실행 (또는 Keycloak 그룹 `cicd-saeoll`에 직접 추가) → SCM 저장소 참여자 추가 |
| 업체 개발자 제외 | Keycloak 그룹 `cicd-saeoll`에서 제거, SCM 참여자 제거 |
| 운영 관리자 추가 | Keycloak 그룹 `cicd-admins`에 추가 |
| 권한 반영 | 그룹 변경 후 해당 사용자는 Jenkins·Argo CD **로그아웃 → 재로그인** |

### 11-3. 비밀번호·토큰 변경

| 대상 | 바꾼 뒤 할 일 |
| --- | --- |
| CI 계정 git 비밀번호 | `SCM_CI_PASSWORD=<새 값> ./onboard-vendor.sh <업체>` |
| Jenkins API 토큰 (만료·폐기) | 6-4 다시 수행 |
| Harbor robot | `./onboard-vendor.sh <업체>` 재실행(재발급, Jenkins credential·pull secret 자동 갱신) |
| `scmadmin` | 바꾸지 않는 것을 권장(K-PaaS 내부 사용). 바꿨다면 이후 스크립트 실행 시 새 값 사용 |

### 11-4. 업체 자원 한도 변경

```bash
QUOTA_CPU=8 QUOTA_MEMORY=16Gi QUOTA_PODS=50 ./onboard-vendor.sh saeoll
```

### 11-5. 업체 종료

1. Argo CD 앱 `saeoll-*` 삭제, 프로젝트 `saeoll` 삭제
2. `kubectl delete ns saeoll-dev saeoll-prod`
3. Jenkins 폴더 `saeoll` 삭제 (필요 시 백업 후)
4. Harbor 프로젝트·robot 삭제, Keycloak 그룹·사용자 정리, SCM 저장소 보관/삭제

### 11-6. scm 업체를 gitlab으로 이전

```bash
PM_USERS=<PM> ./migrate-vendor.sh saeoll <개발자들>      # SCM_ADMIN_PASSWORD 필요, gitlab 설치되어 있어야 함
```
저장소를 이력째 GitLab으로 복사하고 Argo CD가 GitLab gitops를 보도록 바꾼 뒤 Jenkins 잡을 비활성화한다.
SCM 저장소는 지우지 않는다. 자세한 단계: [운영 관리자 가이드 4-4](admin-guide.md#4-4-scm--gitlab-이전)

### 11-7. 포털 업데이트 (이 저장소가 갱신되었을 때)

```bash
cd ~/Saeoll-PaaS && git pull && git log --oneline -3
cd cicd-portal-deployment/script
./deploy-cicd-portal.sh jenkins          # Jenkins 설정(플러그인·권한) 변경 시
./deploy-cicd-portal.sh argocd           # Argo CD 설정 변경 시
# 시작 소스(Jenkinsfile)가 바뀐 경우, 앱별로:
SCM_REPO=<저장소> REPLACE_CI=1 ./add-app.sh <업체> <앱> <유형>
```
`git pull`을 빠뜨려 이전 버전으로 계속 동작하는 경우가 많았다. 적용 전 `git log`로 최신인지 확인한다.

---

## 12. 문제 해결

**먼저 볼 곳**

| 무엇이 | 어디서 |
| --- | --- |
| 빌드 실패 원인 | Jenkins → 잡 → 빌드 번호 → **Console Output** 마지막 40줄 |
| 배포 실패 원인 | `kubectl -n <업체>-dev describe pod -l app=<앱> \| tail -15` (Events) |
| 앱 오류 | `kubectl -n <업체>-dev logs deploy/<앱>` |
| Jenkins 자체 | `kubectl -n cicd-jenkins logs jenkins-0 -c jenkins --tail=100` |
| 이미지 존재 여부 | Harbor → 프로젝트 `<업체>` → 저장소 수 |

### 12-1. 설치 단계

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| preflight `git is not installed` | git 미설치 | `dnf install -y git` |
| preflight `Keycloak is not running` (실제로는 Running) | 예전 스크립트의 검사 오류 | `git pull` 후 재실행 |
| preflight `SCM-Manager REST API login failed ... HTTP 401` | `SCM_ADMIN_PASSWORD`가 틀림 | `scm.` 내정보 관리에서 설정한 **git 비밀번호** 사용. 계정이 `scmadmin`인지 확인 |
| preflight `TLS ... does not verify` | CA 경로 오류 | `CA_FILE=<ca.crt 경로>` 지정 |
| Jenkins Pod `CrashLoopBackOff` | JCasC 설정 오류 | `kubectl -n cicd-jenkins logs jenkins-0 -c jenkins --tail=100`에서 `ConfiguratorException`/`UnknownAttributesException` 확인 → `git pull` 후 `./deploy-cicd-portal.sh jenkins` (재시작 중 Pod는 자동 재생성) |
| Jenkins `Waiting for Jenkins` 오래 걸림 | 첫 기동 플러그인 다운로드 | 최대 20분 대기. `updates.jenkins.io` 접근 확인 |
| `argocd-repo-server` not ready | 구성 요소 기동 중 | 잠시 후 `./check-cicd-portal.sh` 재실행 |

### 12-2. 업체 등록·앱 추가

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| 종료 코드 3 + 할 일 목록 | CI 계정 git 비밀번호 미설정 등 | 목록대로 처리 후 재실행 |
| `Jenkins API ... HTTP 302` / 로그인 페이지로 이동 | API 토큰 미등록, 또는 예전 SSO 설정 | 6-4 토큰 등록, `git pull` 후 `./deploy-cicd-portal.sh jenkins` (`allowTokenAccessWithoutOicSession`) |
| Harbor robot `409 Conflict` | 같은 이름 robot이 이미 존재 (예전 스크립트가 못 찾음) | `git pull` 후 재실행(기존 robot 삭제 후 재생성) |
| `NameError: name 'SCM' is not defined` | 예전 버전 버그 | `git pull` |
| `saeoll-gitops ... not found` | gitops 저장소 없음(예전 버전) | 최신 버전은 자동 생성. `git pull` 후 재실행 |
| `SCM_CI_USER`를 줬는데 `jenkins-<업체>`가 생김 | 서버 소스가 예전 버전 | `git pull` |
| `scm-check ... not found / no permission` | 저장소 없음 또는 CI 계정이 참여자 아님 | `scm.`에서 저장소 생성, CI 계정 보기 권한 |

### 12-3. 빌드 (Jenkins)

| Console Output | 원인 | 조치 |
| --- | --- | --- |
| `No such DSL method 'junit'` | JUnit 플러그인 없음 + 예전 Jenkinsfile | `./deploy-cicd-portal.sh jenkins` (junit 설치) + `REPLACE_CI=1 ./add-app.sh ...` (새 Jenkinsfile은 플러그인이 없어도 건너뜀) |
| `fatal: detected dubious ownership in repository` | 빌드 컨테이너(root)와 작업 폴더 소유자 불일치 | 경고일 뿐 빌드 영향 없음. 새 Jenkinsfile은 `safe.directory`로 제거 |
| Image 단계 `xz: Failed to enable the sandbox` / `tar: Child returned status 1` | `php:8.3-apache`(Debian trixie)의 xz 샌드박스가 kaniko 안에서 실패 | Dockerfile을 `FROM ${BASE_REGISTRY}/php:8.3-apache-bookworm`으로 변경 후 develop push |
| Image 단계 `UNAUTHORIZED` | Harbor robot 인증 실패 | `./onboard-vendor.sh <업체>` 재실행 |
| Image 단계 `x509: certificate signed by unknown authority` | CA Secret 문제 | `kubectl -n cicd-jenkins get secret cicd-ca` 확인, `./deploy-cicd-portal.sh jenkins` |
| Image 단계 `manifest unknown` (베이스 이미지) | `CICD_BASE_REGISTRY`에 이미지 없음 | Harbor 미러에 이미지 등록 |
| Deploy 단계 `overlays/... not found` | gitops에 앱 매니페스트 없음 | `./add-app.sh <업체> <앱> <유형>` 재실행 |
| Deploy 단계 push 거부(403) | CI 계정에 gitops 쓰기 권한 없음 | SCM-Manager에서 `<업체>-gitops` 권한 확인, `onboard-vendor.sh` 재실행 |
| develop push 후 빌드가 안 돎 | ① `master`에 push ② 예전 Jenkinsfile이 첫 빌드 때 Poll SCM 트리거를 지움 (잡 **Configure** → Build Triggers의 Poll SCM이 꺼져 있음) | ① `git branch -vv`로 develop 확인 ② `git pull` 후 `SCM_REPO=<저장소> REPLACE_CI=1 ./add-app.sh <업체> <앱> <유형>` (main·develop의 Jenkinsfile 교체) → 이후 빌드 1회 실행되면 폴링 복구. 급하면 **Build Now** |

### 12-4. 배포 (Argo CD)

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| dev Degraded, Pod `ImagePullBackOff`, 이미지 `...:none-yet` `not found` | 첫 빌드가 아직 성공하지 않음 | 12-3으로 빌드를 성공시키면 자동 해결. Harbor 저장소 수가 0인지로 확인 |
| 빌드는 성공했는데 그대로 | Argo CD 확인 주기(3분) | 앱 카드 ⟳ REFRESH (안 되면 ⋮ → Hard Refresh) |
| `ImagePullBackOff` + `401 Unauthorized` | pull secret 문제 | `./onboard-vendor.sh <업체>` 재실행(`harbor-cicd` 갱신) |
| Pod 재시작 반복 (Degraded) | 헬스 체크 실패, 포트 불일치, 메모리 부족 | `kubectl logs`, 8080 포트·헬스 경로 확인, 메모리는 overlay에서 상향 |
| prod SYNC `permission denied` | 업체 계정은 prod Sync 불가 (설계) | `cicd-admins` 계정 또는 Argo CD admin으로 Sync |
| prod Missing / OutOfSync | 아직 운영 배포 전 (정상) | 10-3 절차 |
| `exceeded quota` | 업체 자원 한도 초과 | 11-4 |

### 12-5. 로그인·권한

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| 업체 계정 Jenkins 대시보드가 비어 있음 | (1) 그룹 미포함 또는 그룹 추가 전 로그인 (2) 권한 방식이 globalMatrix (예전 버전) | `https://jenkins.<도메인>/whoAmI/`의 Authorities에 `cicd-<업체>`가 있는지 확인. 없으면 그룹 추가 후 재로그인. 있으면 `git pull` → `./deploy-cicd-portal.sh jenkins` (Jenkins 관리 → Security가 "Project-based Matrix Authorization Strategy"여야 함) |
| `/whoAmI/`에 `/cicd-saeoll`처럼 `/`가 붙음 | Keycloak groups 매퍼의 Full group path 켜짐 | 클라이언트 `cicd-jenkins`/`cicd-argocd` → Mappers → groups → Full group path OFF |
| Argo CD에서 업체 앱이 안 보임 | 그룹 미포함 | Keycloak `cicd-<업체>` 확인 → 재로그인 |
| GitLab 로그인 "Email can't be blank" | Keycloak 사용자 Email 없음 | Email 입력, Email verified 켬 |
| git clone 401 | 로그인 비밀번호를 사용 | SCM 내정보 관리에서 설정한 **git 비밀번호** 사용 |
| git clone 403 / not found | 저장소 참여자 아님 | SCM 저장소 참여자 추가 |

### 12-6. 진단 명령 모음

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script
# Jenkins 잡 빌드 목록 (curl -g: 주소 안의 [ ] 를 그대로 전달)
bash -c 'source ./lib.sh; load_portal_vars
U=$(get_secret jenkins-user); T=$(get_secret jenkins-api-token)
curl -gsk -u "$U:$T" "$JENKINS_URL/job/saeoll/job/php-service-dev/api/json?tree=builds[number,result,building]"; echo
curl -gsk -u "$U:$T" "$JENKINS_URL/job/saeoll/job/php-service-dev/lastBuild/consoleText" | tail -40'

# Jenkins 폴더 권한
bash -c 'source ./lib.sh; load_portal_vars
U=$(get_secret jenkins-user); T=$(get_secret jenkins-api-token)
curl -gsk -u "$U:$T" "$JENKINS_URL/job/saeoll/config.xml" | grep -E "permission|inheritance"'

# 적용된 Jenkins 권한 방식 (projectMatrix 여야 함)
kubectl -n cicd-jenkins get cm -o yaml | grep -n "globalMatrix\|projectMatrix"

# Argo CD 앱 상태·이미지
kubectl -n cicd-argocd get applications.argoproj.io
kubectl -n cicd-argocd get app saeoll-php-service-dev -o jsonpath='{.status.sync.revision}{"\n"}{.status.summary.images}{"\n"}'

# 업체 그룹에 사용자 추가 (재실행 안전)
bash -c 'source ./lib.sh; load_portal_vars; $API kc-group cicd-saeoll --members saeoll'
```

---

## 13. 삭제

```bash
./uninstall-cicd-portal.sh scm      # Jenkins (잡·credential·빌드 이력)
./uninstall-cicd-portal.sh gitlab   # GitLab CE (모든 저장소·데이터) + Runner
./uninstall-cicd-portal.sh all      # 위 둘 + Argo CD (모든 앱)
```
- 그 소스를 쓰는 업체가 남아 있으면 거부된다(`FORCE=1`로 강제).
- 업체 네임스페이스(`<업체>-dev/prod`), Harbor 프로젝트, SCM 저장소, K-PaaS 구성 요소는 **남는다**. 필요하면 11-5로 정리한다.

---

## 14. 부록: 명령 모음

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script
read -rsp 'scmadmin 비밀번호: ' SCM_ADMIN_PASSWORD; echo; export SCM_ADMIN_PASSWORD

# 설치
./deploy-cicd-portal.sh preflight
./deploy-cicd-portal.sh 2>&1 | tee cicd-portal-deploy.log
JENKINS_USER=admin JENKINS_API_TOKEN='<토큰>' ./deploy-cicd-portal.sh jenkins-token
./check-cicd-portal.sh

# 업체 등록 (scm, 기존 계정을 CI 계정으로)
read -rsp 'CI 계정 git 비밀번호: ' SCM_CI_PASSWORD; echo; export SCM_CI_PASSWORD
SCM_CI_USER=saeoll ./onboard-vendor.sh --source scm saeoll saeoll

# 앱 추가
./add-app.sh saeoll homepage php                                   # 새 저장소 saeoll-homepage
SCM_REPO=saeoll REPLACE_CI=1 ./add-app.sh saeoll php-service php   # 기존 저장소 saeoll

# 운영 배포 (관리자): Jenkins <앱>-release RELEASE_TAG=vX.Y.Z → Argo CD <업체>-<앱>-prod SYNC

# 업데이트 반영
cd ~/Saeoll-PaaS && git pull && cd cicd-portal-deployment/script && ./deploy-cicd-portal.sh jenkins
```

### 이름 규칙 요약

| 대상 | 이름 (업체 `saeoll`, 앱 `homepage`) |
| --- | --- |
| Keycloak 그룹 | `cicd-saeoll` (관리자 `cicd-admins`) |
| CI 계정 | `jenkins-saeoll` (또는 `SCM_CI_USER`) |
| SCM 저장소 | 소스 `saeoll-homepage`, 배포 설정 `saeoll-gitops` |
| Harbor | 프로젝트 `saeoll`, 이미지 `saeoll/homepage:dev-<커밋>-<빌드>` / `:v1.0.0`, robot `robot$saeoll+cicd` |
| Jenkins | 폴더 `saeoll`, 잡 `homepage-dev`, `homepage-release`, credential `saeoll-harbor`, `saeoll-scm` |
| Argo CD | 프로젝트 `saeoll`, 앱 `saeoll-homepage-dev`, `saeoll-homepage-prod` |
| 네임스페이스 | `saeoll-dev`, `saeoll-prod` |
| URL | `https://homepage-saeoll-dev.<도메인>`, `https://homepage-saeoll.<도메인>` |
