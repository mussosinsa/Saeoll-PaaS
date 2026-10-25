# CI/CD 포털 설치·관리 가이드 (신규 서버, 초보자용)

K-PaaS 컨테이너 플랫폼이 설치된 **새 서버(쿠버네티스 클러스터)** 에 `cicd-portal-deployment`를 처음 적용하고,
업체 등록 → 앱 추가 → DB 연결 → dev·운영 배포 → 일상 운영까지 관리자가 할 일을 순서대로 정리한 문서다.
실제 구축(도메인 `192.168.20.151.nip.io`, 업체 `saeoll`, 앱 `php-service`)에서 겪은 오류와 해결 방법을 모두 반영했다.

| 함께 보는 문서 | 내용 |
| --- | --- |
| [SCM/GitLab](guide-scm-gitlab.md) · [Harbor](guide-harbor.md) · [Jenkins](guide-jenkins.md) · [Argo CD](guide-argocd.md) | 솔루션별 적용·운영 가이드 |
| [웹 화면 가이드](web-ui-guide.md) | Jenkins·Argo CD 화면 사용법 |
| [SCM 개발자 가이드](vendor-guide-scm.md) / [GitLab 개발자 가이드](vendor-guide.md) | 업체 개발자에게 전달 |
| [PHP + MariaDB 게시판 샘플](../samples/php-board/README.md) | DB 연동 예제와 테스트 절차 |
| [README](../README.md) / [운영 관리자 가이드](admin-guide.md) | 구성 요약, GitLab 업체 운영 |

---

## 목차

- [0. 전체 순서 한눈에 보기](#0-전체-순서-한눈에-보기)
- [1. 개념 이해](#1-개념-이해)
- [2. 용어](#2-용어)
- [3. 사전 준비](#3-사전-준비)
- [4. 폴더 구성](#4-폴더-구성)
- [5. 스크립트별 상세 설명](#5-스크립트별-상세-설명)
- [6. 관리자 절차: 설치](#6-관리자-절차-설치)
- [7. 관리자 절차: 업체 등록](#7-관리자-절차-업체-등록)
- [8. 관리자 절차: 앱 추가](#8-관리자-절차-앱-추가)
- [9. 관리자 절차: DB 연결](#9-관리자-절차-db-연결)
- [10. 관리자 절차: 배포 운영 (dev · 운영)](#10-관리자-절차-배포-운영-dev--운영)
- [11. 개발자 작업 흐름 (업체에 안내)](#11-개발자-작업-흐름-업체에-안내)
- [12. 일상 운영](#12-일상-운영)
- [13. 문제 해결](#13-문제-해결)
- [14. 삭제](#14-삭제)
- [15. 부록](#15-부록)

---

## 0. 전체 순서 한눈에 보기

| 단계 | 누가 | 무엇을 | 명령 / 화면 | 소요 |
| --- | --- | --- | --- | --- |
| 0 | 관리자 | 사전 준비 확인 (K-PaaS, StorageClass, 도구) | [3장](#3-사전-준비) | 10분 |
| 1 | 관리자 | 소스 받기, 설정 확인 | `git clone`, `cicd-vars.sh` | 5분 |
| 2 | 관리자 | 사전 점검 | `./deploy-cicd-portal.sh preflight` | 1분 |
| 3 | 관리자 | 설치 | `./deploy-cicd-portal.sh` | 15~30분 |
| 4 | 관리자 | Jenkins API 토큰 등록 (1회) | Jenkins 화면 + `jenkins-token` | 5분 |
| 5 | 관리자 | 설치 점검·운영 관리자 지정 | `./check-cicd-portal.sh`, Keycloak | 5분 |
| 6 | 관리자 | 업체 등록 | `./onboard-vendor.sh` | 10분 |
| 7 | 관리자 | 앱 추가 (첫 dev 빌드 자동 실행) | `./add-app.sh` | 5분 + 빌드 |
| 8 | 관리자 | (선택) DB 연결 | `./add-db.sh` | 5분 |
| 9 | 개발자 | 개발 → develop push → dev 자동 배포 | git, Jenkins, Argo CD | - |
| 10 | 업체 PM / 관리자 | 태그 → release 빌드 → **운영 승인 SYNC** | Jenkins, Argo CD | - |

> **모든 스크립트는 다시 실행해도 안전하다(멱등).** 중간에 실패하면 원인을 고치고 같은 명령을 다시 실행한다.

---

## 1. 개념 이해

### 1-1. 무엇을 하는 시스템인가

업체(유지보수사·내부 팀)가 소스를 올리면 **빌드 → 테스트 → 이미지 생성 → 배포**를 자동으로 해 주는 시스템이다.
K-PaaS 기본 파이프라인(`cp-pipeline`)과 소스 컨트롤(`cp-source-control`)은 **변경하지 않고 옆에 따로** 설치한다.
지원 유형: `java-gradle`, `java-maven`, `php`, `node`, `vue`.

### 1-2. 전체 흐름

```text
 개발자 PC ──git push(develop)──▶ ① 소스 저장소  saeoll                     (K-PaaS SCM, scm.<도메인>)
                                      │ Jenkins가 5분마다 확인(Poll SCM)
                                      ▼
                                 ② Jenkins  saeoll/php-service-dev          (jenkins.<도메인>)
                                      │ 빌드용 Pod를 그때마다 생성: 빌드·테스트 → kaniko로 이미지 생성
                                      ├──이미지 push──▶ ③ Harbor  saeoll/php-service:dev-<커밋>-<번호>
                                      └──태그 변경 커밋──▶ ④ 배포 설정 저장소  saeoll-gitops (main)
                                                              │ Argo CD가 3분마다 확인
                                                              ▼
                                                         ⑤ Argo CD  saeoll-php-service-dev / -prod
                                                              │ dev: 자동 배포, prod: 관리자 SYNC(승인)
                                                              ▼
                                                         ⑥ 네임스페이스 saeoll-dev / saeoll-prod
                                                            https://php-service-saeoll-dev.<도메인>
```

### 1-3. 저장소가 두 개인 이유 (중요)

| 구분 | 소스 저장소 `saeoll` (또는 `<업체>-<앱>`) | 배포 설정 저장소 `<업체>-gitops` |
| --- | --- | --- |
| 내용 | 앱 소스, `Dockerfile`, `Jenkinsfile` | 쿠버네티스 YAML: `apps/<앱>/base`, `overlays/dev`, `overlays/prod` |
| 수정하는 사람 | 개발자 | Jenkins(이미지 태그 자동 변경), 관리자(DB·설정) |
| 감시하는 시스템 | **Jenkins** (develop 브랜치) | **Argo CD** (main 브랜치) |
| push하면 | 빌드 → 이미지 → gitops 태그 변경 | 클러스터에 바로 반영 (Jenkins는 동작하지 않음 — 정상) |
| 브랜치 | `develop`(dev), `main`(운영 기준), 태그 `vX.Y.Z` | `main` |

### 1-4. 소스 방식 두 가지

업체를 등록할 때 업체마다 하나를 고른다(`--source scm|gitlab`). 둘 다 설치할 수 있다.

| 방식 | 소스 저장소 / 빌드 | 대상 | 비고 |
| --- | --- | --- | --- |
| `scm` | K-PaaS 소스 컨트롤 + **Jenkins** | 내부 팀, 기존 SCM 사용자 | 자원 적음. **SCM 웹 화면은 로그인한 누구에게나 모든 저장소 파일을 보여 줌(실측)** |
| `gitlab` | GitLab CE + GitLab Runner | **외부 업체** | 업체 간 소스 분리, 코드 리뷰. CPU 2·메모리 4Gi 추가 |

이 문서는 `scm` 방식 기준이다. `gitlab`은 [운영 관리자 가이드](admin-guide.md)를 함께 본다.

### 1-5. 권한 구조

| 대상 | Keycloak 그룹 | Jenkins | Argo CD |
| --- | --- | --- | --- |
| 운영 관리자 | `cicd-admins` | 전체 관리 | 전체 관리, **prod SYNC(운영 배포 승인)** |
| 업체 개발자 | `cicd-<업체>` | 자기 업체 폴더만: 조회·빌드 실행 | 자기 업체 앱만: 조회·로그·**dev SYNC** |
| 그 외 로그인 사용자 | - | 빈 대시보드 | 앱 안 보임 |

Jenkins는 **Project-based Matrix** 권한 방식을 쓴다(폴더별 권한). 그룹을 바꾼 뒤에는 **로그아웃 → 다시 로그인**해야 반영된다.

---

## 2. 용어

| 용어 | 뜻 |
| --- | --- |
| CI / CD | CI: 빌드·테스트·이미지 생성(Jenkins). CD: 배포(Argo CD) |
| GitOps | 배포할 버전을 Git(gitops 저장소)에 적어 두면 Argo CD가 클러스터를 그대로 맞추는 방식 |
| kustomize | YAML을 base(공통) + overlay(dev/prod 차이)로 관리하는 도구. `overlays/<환경>/kustomization.yaml`의 `newTag`가 배포 버전 |
| kaniko | Docker 없이 Pod 안에서 이미지를 만드는 도구 |
| Poll SCM | Jenkins가 저장소를 주기적으로(5분) 확인해 새 커밋이 있으면 빌드하는 기능 |
| Sync | Argo CD가 gitops 내용을 클러스터에 적용하는 것 |
| `none-yet` | 앱 추가 직후 gitops에 들어가는 임시 이미지 태그. 첫 빌드 성공 시 실제 태그로 바뀜 |
| CI 계정 | Jenkins·Argo CD가 SCM 저장소에 접근할 때 쓰는 계정 (기본 `jenkins-<업체>`, 또는 기존 계정) |
| git 비밀번호 | SCM 웹 → 내정보 관리에서 설정한 비밀번호. **Keycloak 로그인 비밀번호와 별개** |
| `scmadmin` | K-PaaS가 쓰는 SCM-Manager 관리자. 스크립트가 저장소를 만들 때 사용. **비밀번호를 함부로 바꾸지 않는다** |
| StorageClass | 볼륨(PVC)을 만드는 방식. 클러스터마다 이름이 다름(예: `nfs-client`) |

---

## 3. 사전 준비

### 3-1. K-PaaS 구성 요소 확인

```bash
kubectl -n cp-portal get pod          # CP-Portal: 모두 Running
kubectl -n keycloak get pod           # Keycloak: Running
kubectl -n cp-source-control get pod  # K-PaaS 소스 컨트롤(scm 방식): Running
kubectl get ingressclass              # nginx
kubectl get storageclass              # ★ 이름과 (default) 표시 확인
ls ~/Saeoll-PaaS/cp-portal-deployment/certs/ca.crt               # K-PaaS CA 인증서
ls ~/Saeoll-PaaS/cp-portal-deployment/script/cp-portal-vars.sh   # 도메인·Keycloak·Harbor 값
```

| 항목 | 확인 내용 |
| --- | --- |
| Harbor | `https://harbor.<도메인>`에 admin으로 로그인 가능 |
| SCM | `https://scm.<도메인>` 로그인 가능, `scmadmin` 비밀번호(git 비밀번호)를 알고 있음 |
| TLS | `kubectl -n cp-portal get secret <도메인>-tls` 존재 |
| **StorageClass** | `cp-portal-vars.sh`의 `K8S_STORAGECLASS` 값이 `kubectl get storageclass` 목록에 **실제로 있는지** 확인. 실제 구축 서버는 `nfs-client`(default)·`local-path`만 있고 `cp-storageclass`는 없었다 |

```bash
grep K8S_STORAGECLASS ~/Saeoll-PaaS/cp-portal-deployment/script/cp-portal-vars.sh
```
목록에 없는 이름이면 `cicd-vars.sh`의 `K8S_STORAGECLASS="nfs-client"`처럼 실제 이름을 넣는다(5-1).

### 3-2. 작업 서버 도구

```bash
dnf install -y git curl python3       # Rocky Linux 9
kubectl version --client; helm version; git --version; python3 --version
```
스크립트는 `python3` 기본 라이브러리만 쓴다(pip 설치 불필요).

### 3-3. 자원

| 구성 | 요청 | 상한 | 디스크 |
| --- | --- | --- | --- |
| Jenkins | 0.5 CPU / 1Gi | 3Gi | 20Gi |
| Argo CD | 약 1Gi | - | - |
| GitLab (gitlab 방식) | 2 CPU / 4Gi | 8Gi | 56Gi |
| 빌드 Pod (빌드 중에만) | 0.5 CPU / 1Gi | 최대 6Gi | - |
| 업체 네임스페이스 (각각) | quota CPU 4 / 메모리 8Gi / Pod 30 / PVC 10 | | |
| 앱 전용 MariaDB (DB 연결 시) | 0.1 CPU / 256Mi | 1Gi | 2Gi |

### 3-4. 인터넷 접근

| 대상 | 용도 |
| --- | --- |
| `charts.jenkins.io`, `updates.jenkins.io`, `get.jenkins.io` | Jenkins 차트·플러그인 |
| `argoproj.github.io`, `quay.io`, `ghcr.io` | Argo CD |
| `docker.io` (Docker Hub) | 빌드 도구(composer, gradle, node…), 베이스 이미지(php, nginx…), mariadb |
| `gcr.io` | kaniko |
| `packagist.org`, `registry.npmjs.org`, Maven Central | 빌드 중 의존성 |

폐쇄망이면 Harbor에 미러를 만들고 `CICD_DOCKERHUB`, `CICD_BASE_REGISTRY`, `KANIKO_IMAGE`, `MARIADB_IMAGE`를 바꾼다.

### 3-5. 비밀번호 입력 요령

명령줄에 비밀번호를 쓰면 셸 기록에 남는다. 항상 아래처럼 입력받는다.

```bash
read -rsp 'scmadmin 비밀번호: ' SCM_ADMIN_PASSWORD; echo; export SCM_ADMIN_PASSWORD
```

---

## 4. 폴더 구성

```text
cicd-portal-deployment/
├── script/                    ★ 실행 위치 (항상 이 폴더에서 실행)
│   ├── cicd-vars.sh           설정 값
│   ├── deploy-cicd-portal.sh  설치·재설정
│   ├── check-cicd-portal.sh   점검 (읽기 전용)
│   ├── onboard-vendor.sh      업체 등록
│   ├── add-app.sh             앱 추가
│   ├── add-db.sh              앱에 DB 연결
│   ├── migrate-vendor.sh      scm 업체 → gitlab 이전
│   ├── uninstall-cicd-portal.sh 삭제
│   ├── lib.sh                 공통 함수 (직접 실행 안 함)
│   └── cicd_api.py            Keycloak·Harbor·SCM·Jenkins·GitLab API 도구 (직접 실행 안 함)
├── values_orig/               Helm 값 원본: jenkins.yaml, jenkins-sso.yaml, argocd.yaml, gitlab-runner.yaml
├── values/                    설치 시 실제 값으로 채워 만든 파일 (자동 생성)
├── starters/<유형>/            시작 소스: Dockerfile, Jenkinsfile, .gitlab-ci.yml, 샘플 앱
├── gitops-template/           앱별 배포 YAML 원본: base + overlays/dev, prod
├── db-template/mariadb.yaml   앱 전용 MariaDB 원본 (add-db.sh)
├── samples/php-board/         PHP + MariaDB 게시판 샘플
├── manifests/gitlab.yaml      GitLab CE
├── ci-templates/              GitLab CI 공용 템플릿
└── docs/                      문서
```

---

## 5. 스크립트별 상세 설명

### 5-1. cicd-vars.sh — 설정 파일

도메인·Keycloak·Harbor·StorageClass는 `cp-portal-vars.sh`에서 자동으로 읽는다. 아래는 바꿀 수 있는 값이다.

| 변수 | 기본값 | 바꾸는 경우 |
| --- | --- | --- |
| `CICD_SOURCES` | `"scm gitlab"` | 하나만 쓸 때 `"scm"` 또는 `"gitlab"` (자원이 부족하면 `scm`부터) |
| `K8S_STORAGECLASS` | (빈 값 = CP-Portal 값) | CP-Portal 값이 클러스터에 없을 때 실제 이름(`nfs-client` 등) |
| `SCM_ADMIN_USER` | `scmadmin` | K-PaaS 기본값 유지 |
| `JENKINS_CHART_VERSION` | (빈 값 = 최신) | 첫 설치 후 출력된 버전으로 고정(6-6) |
| `JENKINS_SSO` | `true` | SSO 장애 조사 시만 `false` |
| `JENKINS_DATA_SIZE` | `20Gi` | 빌드 이력이 많을 때 |
| `ARGOCD_CHART_VERSION` | `7.8.0` | Argo CD 2.14 |
| `GITLAB_IMAGE` | `gitlab/gitlab-ce:17.11.1-ce.0` | gitlab 방식 |
| `CICD_DOCKERHUB` / `CICD_BASE_REGISTRY` | `docker.io/library` | 폐쇄망: `harbor.<도메인>/base-images` |
| `KANIKO_IMAGE` | `gcr.io/kaniko-project/executor:v1.23.2-debug` | 폐쇄망 미러 |
| `MARIADB_IMAGE` | `docker.io/library/mariadb:11.4` | 앱 전용 DB 이미지 |
| `DB_SIZE` | `2Gi` | 앱 전용 DB 볼륨 크기 |

명령 앞에 붙여 일회성으로 바꿀 수도 있다: `CICD_SOURCES=scm ./deploy-cicd-portal.sh`

### 5-2. deploy-cicd-portal.sh — 설치·재설정

```text
사용법: ./deploy-cicd-portal.sh [단계 ...]       단계 생략 = 설치할 소스에 맞춰 전체
단계  : preflight keycloak jenkins jenkins-token gitlab bootstrap templates runner argocd
```

| 단계 | 하는 일 (순서대로) |
| --- | --- |
| `preflight` | 도구(kubectl·helm·curl·python3·git), StorageClass, TLS secret, CA 파일, Keycloak Running, IngressClass, SCM Running과 `scmadmin` 로그인(`SCM_ADMIN_PASSWORD` 지정 시), 노드 자원을 검사. **문제를 모두 모아 출력**하고 하나라도 있으면 중단 |
| `keycloak` | `cp-realm`에 클라이언트 `cicd-jenkins`·`cicd-argocd`(+`cicd-gitlab`) 생성, groups 매퍼 추가, 그룹 `cicd-admins` 생성 후 Keycloak 관리자 추가. 클라이언트 비밀값은 Secret `cicd-portal-secrets`에 저장. 기존 클라이언트는 바꾸지 않음 |
| `jenkins` | 네임스페이스 `cicd-jenkins`, TLS·CA Secret 복사 → `values_orig/jenkins*.yaml`을 값으로 채워 `values/`에 생성 → Helm 설치(공식 `jenkins/jenkins` 차트). 내용: K-PaaS SSO(oic-auth), **projectMatrix 권한**(`cicd-admins` 관리자), JVM에 K-PaaS CA 등록, 플러그인(oic-auth, matrix-auth, credentials-binding, pipeline-stage-view, timestamper, **junit**), Ingress. 재시작 반복 중인 Pod는 새 설정으로 다시 만든 뒤 준비될 때까지 대기(최대 20분) |
| `jenkins-token` | `JENKINS_USER`·`JENKINS_API_TOKEN`으로 로그인 확인 후 Secret에 저장 (onboard·add-app이 사용) |
| `argocd` | 네임스페이스 `cicd-argocd` → Helm 설치(Argo CD 2.14): K-PaaS SSO, `cicd-admins`=관리자, K-PaaS CA → 모든 구성 요소(server, repo-server, controller, redis) 준비 대기 |
| `gitlab` `bootstrap` `templates` `runner` | gitlab 방식: GitLab CE 배포, 기본 설정·자동화 토큰, CI 템플릿, Runner 등록 |

설정만 다시 적용할 때는 해당 단계만 실행한다. 예: `./deploy-cicd-portal.sh jenkins`

### 5-3. check-cicd-portal.sh — 점검 (아무것도 바꾸지 않음)

```bash
./check-cicd-portal.sh                         # 기본
SCM_ADMIN_PASSWORD=... ./check-cicd-portal.sh  # SCM 로그인까지
```
① Pod 상태 ② 각 주소 응답 ③ Keycloak 클라이언트 ④ API 로그인 ⑤ 업체별 소스·Argo CD 앱 상태를 확인하고
마지막에 `[RESULT] OK` 또는 `[RESULT] FAIL`을 출력한다.

### 5-4. onboard-vendor.sh — 업체 등록

```text
사용법: [PM_USERS=pm1] ./onboard-vendor.sh [--source scm|gitlab] <업체ID> [사용자1,사용자2,...]
```

| 인자 / 환경변수 | 설명 |
| --- | --- |
| `--source` | 처음 등록 때만 필요(Argo CD 프로젝트에 기록되어 이후 자동). 변경은 `migrate-vendor.sh`로만 |
| `<업체ID>` | 영문 소문자·숫자·`-`, 30자 이내. Harbor 프로젝트·네임스페이스·Jenkins 폴더 이름 |
| `[사용자 목록]` | 업체 개발자 Keycloak ID. 그룹 `cicd-<업체>`에 추가 |
| `SCM_ADMIN_PASSWORD` | (scm) `scmadmin` git 비밀번호 |
| `SCM_CI_USER` | (scm) CI 계정. 생략 시 `jenkins-<업체>`를 Keycloak에 자동 생성. 기존 계정 사용 가능(예: `saeoll`, 이후 기억됨) |
| `SCM_CI_PASSWORD` | (scm) CI 계정의 **git 비밀번호** |
| `SCM_CREATE_GITOPS=0` | (scm) gitops 저장소 자동 생성 안 함 |
| `QUOTA_CPU` `QUOTA_MEMORY` `QUOTA_PODS` | 업체 네임스페이스 한도 (기본 4 / 8Gi / 30) |

**내부 동작 (scm)**

1. Keycloak 그룹 `cicd-<업체>` 생성, 사용자 추가
2. Harbor 비공개 프로젝트 `<업체>`, robot 계정 `robot$<업체>+cicd`(push/pull) 생성(재실행 시 재발급)
3. 네임스페이스 `<업체>-dev`, `<업체>-prod`: ResourceQuota, LimitRange(기본 메모리 512Mi), 이미지 pull secret `harbor-cicd`, TLS secret
4. CI 계정 준비(필요 시 Keycloak에 `jenkins-<업체>` 생성) → SCM-Manager에 gitops 저장소 `<업체>-gitops` 생성(CI 계정 쓰기 권한) → README로 `main` 초기화
5. Jenkins 폴더 `<업체>`(그룹 `cicd-<업체>`: 조회·빌드), 폴더 credential `<업체>-harbor`(robot), `<업체>-scm`(CI 계정)
6. Argo CD 프로젝트 `<업체>`(배포 대상 2개 네임스페이스로 제한, 업체는 dev만 SYNC) + gitops 저장소 접속 정보 `repo-creds-<업체>-gitops`

할 일이 남으면(예: CI 계정 git 비밀번호 미입력) **목록을 출력하고 종료 코드 3**으로 끝난다 → 처리 후 재실행.

### 5-5. add-app.sh — 앱 추가

```text
사용법: ./add-app.sh <업체ID> <앱이름> <java-gradle|java-maven|php|node|vue> [헬스체크경로]
```

| 환경변수 | 설명 |
| --- | --- |
| `SCM_ADMIN_PASSWORD` | (scm) 필수 |
| `SCM_REPO=<저장소>` | 소스 저장소 이름이 `<업체>-<앱>`이 아닐 때 (예: 기존 저장소 `saeoll`) |
| `REPLACE_CI=1` | 저장소의 Jenkinsfile을 포털 최신 버전으로 교체 (**main과 기존 develop 모두**, 다른 파일은 유지) |
| `SKIP_STARTER=1` | 시작 소스를 넣지 않음 (자기 소스를 이미 올린 경우) |
| `DB=dedicated\|shared\|external` | 앱 추가와 함께 dev에 DB 연결 (`add-db.sh` 호출) |

헬스체크 경로 기본값: PHP `/healthz.php`, 그 외 `/healthz`.

**내부 동작 (scm)**

1. 소스 저장소 확인(CI 계정 보기 권한) → clone. `main`이 없고 `master`만 있으면 `master` 이력으로 `main` 생성(`master`는 그대로)
2. 시작 소스(Dockerfile, Jenkinsfile, 샘플)를 **없는 파일만** 추가해 `main`에 push. `REPLACE_CI=1`이면 Jenkinsfile 교체
3. gitops `<업체>-gitops`에 `apps/<앱>/base`(Deployment·Service·Ingress) + `overlays/dev`, `overlays/prod`(태그 `none-yet`) push (이미 있으면 유지)
4. Jenkins 잡 `<앱>-dev`(develop, Poll SCM 5분), `<앱>-release`(파라미터 `RELEASE_TAG`) 생성
5. `develop` 브랜치 생성(있으면 유지, `REPLACE_CI=1`이면 develop의 Jenkinsfile도 교체)
6. Argo CD 앱 `<업체>-<앱>-dev`(자동 Sync), `<업체>-<앱>-prod`(수동 Sync) 생성
7. (`DB=` 지정 시) `add-db.sh` 실행
8. 첫 dev 빌드 실행 (이 빌드가 Jenkinsfile 안의 Poll SCM 설정을 잡에 등록)

### 5-6. add-db.sh — 앱에 DB 연결

```text
사용법: ./add-db.sh <업체ID> <앱이름> [dev|prod|all] [dedicated|shared|external]
        (기본: dev, dedicated)
```

| 방식 | 하는 일 | 용도 |
| --- | --- | --- |
| `dedicated` | 앱 전용 MariaDB(StatefulSet `<앱>-mariadb`, PVC `DB_SIZE`)를 gitops로 추가 | 업체·환경별 분리 DB (권장) |
| `shared` | K-PaaS 공용 MariaDB(`mariadb` 네임스페이스)에 DB·계정 `<업체>_<앱>_<환경>` 생성, 그 DB에만 권한 | 빠른 연결 확인 |
| `external` | 이미 있는 DB: 환경변수 `DB_HOST DB_NAME DB_USER DB_PASSWORD [DB_PORT]` | 관리형·외부 DB |

**내부 동작**

1. Secret `<앱>-db`(`<업체>-<환경>`) 생성: `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`. 비밀번호는 자동 생성되어
   **Secret에만 저장**(화면·명령줄·Git에 남지 않음). dedicated는 root용 `<앱>-mariadb-root`도 생성
2. (shared) 공용 MariaDB에 DB·계정 생성. root 비밀번호(`cp-portal-vars.sh`의 `DATABASE_USER_PASSWORD`)는 stdin으로 전달
3. gitops `overlays/<환경>/kustomization.yaml`에 Deployment `envFrom: <앱>-db` 패치 추가. dedicated는 `mariadb.yaml` 생성·등록
4. StorageClass: `DB_STORAGECLASS` → `K8S_STORAGECLASS`(클러스터에 있을 때) → 없으면 **클러스터 기본값**
5. push → Argo CD가 반영 (dev 자동, prod는 관리자 SYNC)

**안전장치**: Secret이 이미 있으면 유지(`DB_SECRET_UPDATE=1`로 shared·external 재생성). dedicated MariaDB는 처음 만든
비밀번호를 계속 쓰므로 Secret을 바꾸지 않으며, Secret 없이 볼륨만 남아 있으면 데이터 손실 경고와 함께 중단한다.

앱은 환경변수 `DB_HOST`·`DB_PORT`·`DB_NAME`·`DB_USER`·`DB_PASSWORD`로 접속하도록 작성한다(예제: `samples/php-board`).

### 5-7. migrate-vendor.sh / uninstall-cicd-portal.sh

```bash
PM_USERS=<PM> ./migrate-vendor.sh <업체> <개발자들>   # scm 업체를 gitlab으로 이전 (이력째 복사, Argo CD 대상 전환, Jenkins 잡 비활성화)
./uninstall-cicd-portal.sh <scm|gitlab|all>          # 삭제 (14장)
```

---

## 6. 관리자 절차: 설치

이하 명령은 모두 **Master Node(예: k8s-cp01)** 에서 실행한다.

### STEP 1. 소스 받기

```bash
cd ~
git clone -b claude/stoic-edison-jc393z https://github.com/mussosinsa/Saeoll-PaaS.git   # 이미 있으면: cd ~/Saeoll-PaaS && git pull
cd ~/Saeoll-PaaS/cicd-portal-deployment/script
git log --oneline -1
```

### STEP 2. 설정 확인

```bash
vi cicd-vars.sh
```
- `CICD_SOURCES`: 처음이면 `"scm"`만으로 시작해도 된다.
- `kubectl get storageclass`에 CP-Portal의 StorageClass가 없으면 `K8S_STORAGECLASS="nfs-client"`처럼 실제 이름 입력.

### STEP 3. 사전 점검

```bash
read -rsp 'scmadmin 비밀번호: ' SCM_ADMIN_PASSWORD; echo; export SCM_ADMIN_PASSWORD
./deploy-cicd-portal.sh preflight
```
`[OK] Preflight passed`가 나와야 한다. `[WARN]` 항목은 [13-1](#13-1-설치)을 보고 해결 후 재실행.

### STEP 4. 설치

```bash
./deploy-cicd-portal.sh 2>&1 | tee cicd-portal-deploy.log
```
- Jenkins 첫 기동은 플러그인 다운로드로 5~15분 걸린다.
- 실패하면 원인을 고치고 같은 명령을 다시 실행한다.
- 끝에 각 주소와 비상 계정 조회 명령이 출력된다.

### STEP 5. Jenkins API 토큰 등록 (1회, 필수)

`onboard-vendor.sh`·`add-app.sh`가 Jenkins에 폴더·잡을 만들 때 쓴다.

1. `https://jenkins.<도메인>` → K-PaaS SSO로 `cicd-admins` 사용자(예: `admin`) 로그인
2. 오른쪽 위 사용자 → **Security** → API Token **Add new Token** → **Generate** → 복사(다시 볼 수 없음)
3. 등록:
   ```bash
   read -rsp 'Jenkins API 토큰: ' JENKINS_API_TOKEN; echo
   JENKINS_USER=admin JENKINS_API_TOKEN="$JENKINS_API_TOKEN" ./deploy-cicd-portal.sh jenkins-token
   ```
   `[OK] Jenkins API token stored for admin`

### STEP 6. 차트 버전 고정 (권장)

설치 로그의 `(chart jenkins-5.9.73)`에서 버전을 확인해 고정한다. 고정하지 않으면 재실행 때 최신 차트로 바뀔 수 있다.
```bash
sed -i 's/^JENKINS_CHART_VERSION=""/JENKINS_CHART_VERSION="5.9.73"/' cicd-vars.sh
```

### STEP 7. 점검과 로그인 확인

```bash
./check-cicd-portal.sh            # [RESULT] OK
```

| 시스템 | 주소 | 로그인 |
| --- | --- | --- |
| Jenkins | `https://jenkins.<도메인>` | K-PaaS SSO |
| Argo CD | `https://argocd.<도메인>` | **LOG IN VIA K-PAAS SSO** (비상: `admin`) |
| SCM | `https://scm.<도메인>` | K-PaaS 계정 |

```bash
# Argo CD 비상 계정 admin 비밀번호
kubectl -n cicd-argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

Jenkins → 관리(⚙) → **Security**의 Authorization이 **Project-based Matrix Authorization Strategy**인지 확인한다.

### STEP 8. 운영 관리자 지정

Keycloak 관리 콘솔(`https://keycloak.<도메인>/admin`) → realm **cp-realm** → **Groups** → `cicd-admins` → **Members** → 추가.
추가된 사람은 Jenkins·Argo CD에서 **로그아웃 후 다시 로그인**한다.

> 브라우저의 "주의 요함"은 K-PaaS 사설 인증서 때문이며 동작에는 문제없다(PC에 `ca.crt`를 신뢰 루트로 등록하면 사라짐).

---

## 7. 관리자 절차: 업체 등록

예: 업체 `saeoll`, 개발자 Keycloak 계정 `saeoll`.

### STEP 1. 업체 사용자 계정 (Keycloak)

`cp-realm` → **Users** → **Add user**: Username, **Email(필수)**, Email verified 켬 → **Credentials**에서 임시 비밀번호.
CP-Portal에서 만든 사용자를 그대로 써도 된다.

### STEP 2. 등록 실행 — 방법 A: 전용 CI 계정 (권장)

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script
export SCM_ADMIN_PASSWORD        # 6장에서 입력한 값 (새 셸이면 다시 read)
./onboard-vendor.sh --source scm saeoll saeoll        # 1차: jenkins-saeoll 생성 후 할 일 출력 (종료 코드 3)
```
1. 출력된 명령으로 `jenkins-saeoll`의 Keycloak 임시 비밀번호 확인
2. 그 계정으로 `https://scm.<도메인>` **최초 로그인** → 오른쪽 위 계정 → **내정보 관리** → **비밀번호 변경**(= git 비밀번호)
3. 2차 실행:
   ```bash
   read -rsp 'jenkins-saeoll git 비밀번호: ' SCM_CI_PASSWORD; echo; export SCM_CI_PASSWORD
   ./onboard-vendor.sh saeoll saeoll
   ```

### STEP 2. 등록 실행 — 방법 B: 기존 계정을 CI 계정으로 (실제 구축 방식)

계정이 이미 SCM에 로그인해 git 비밀번호를 설정해 둔 경우.
```bash
read -rsp 'saeoll git 비밀번호: ' SCM_CI_PASSWORD; echo; export SCM_CI_PASSWORD
SCM_CI_USER=saeoll ./onboard-vendor.sh --source scm saeoll saeoll
```
> 이 계정의 git 비밀번호를 바꾸면 Jenkins·Argo CD가 저장소에 접근하지 못한다. 바꾼 뒤에는 같은 명령을 다시 실행한다.

### STEP 3. 결과 확인

| 확인 | 기대 결과 |
| --- | --- |
| 출력 마지막 | `Vendor saeoll onboarded.` |
| Harbor | 프로젝트 `saeoll`(비공개), 로봇 계정 `robot$saeoll+cicd` |
| `kubectl get ns saeoll-dev saeoll-prod` | 두 네임스페이스 존재 |
| Jenkins (admin) | 폴더 `saeoll`, 폴더 → Credentials에 `saeoll-harbor`, `saeoll-scm` |
| Argo CD | Settings → Projects → `saeoll` |
| SCM-Manager (`https://scm-manager.<도메인>/scm`, scmadmin) | 저장소 `saeoll-gitops` (`scm.` 화면 목록에는 안 나옴 — 정상) |

업체 사용자 화면에서 Jenkins 폴더가 보이는지는 그 사용자가 **로그아웃 → 재로그인** 후 확인한다
(`https://jenkins.<도메인>/whoAmI/`의 Authorities에 `cicd-saeoll`).

---

## 8. 관리자 절차: 앱 추가

### 경우 A. 새 저장소로 시작

1. `https://scm.<도메인>`에서 저장소 `saeoll-homepage`(Git) 생성
2. 참여자: CI 계정(`jenkins-saeoll` 또는 `saeoll`) **보기**, 개발자 **쓰기**
3. 실행:
   ```bash
   ./add-app.sh saeoll homepage php
   ```

### 경우 B. 이미 있는 저장소 사용 (실제 구축: 저장소 `saeoll`, 앱 `php-service`)

```bash
SCM_REPO=saeoll REPLACE_CI=1 ./add-app.sh saeoll php-service php
```
- 기존 소스는 유지되고 없는 파일만 추가된다. **기존 Dockerfile은 바뀌지 않으므로** 아래 저장소 규칙을 확인한다.
- `REPLACE_CI=1`: 예전 Jenkinsfile을 포털용으로 교체(main·develop). 이후 개발자는 `git pull` 후 작업.

### 결과 확인

| 확인 | 기대 결과 |
| --- | --- |
| Jenkins `saeoll` 폴더 | `<앱>-dev`, `<앱>-release`, dev 첫 빌드 실행 중/완료 |
| SCM-Manager 저장소 커밋 (Branches: develop) | `Add php starter (cicd-portal)` 등 |
| Argo CD | `saeoll-<앱>-dev`, `saeoll-<앱>-prod` |
| 첫 빌드 전 dev 앱 | **Degraded / ImagePullBackOff (`none-yet` not found)** — 정상, 첫 빌드 성공 후 해결 |

### 저장소 규칙 (업체에 전달)

| 파일 | 규칙 |
| --- | --- |
| `Dockerfile` | **8080 포트**, `FROM ${BASE_REGISTRY}/...` 형식 |
| PHP | `FROM ${BASE_REGISTRY}/php:8.3-apache-bookworm` + `docker-php-ext-install pdo_mysql` (trixie 기반 `php:8.3-apache`는 kaniko에서 실패) |
| 헬스 체크 | `GET /healthz`(PHP `/healthz.php`) 200. **DB를 쓰지 않는 페이지**로 (DB 장애가 Pod 재시작으로 번지지 않게) |
| `Jenkinsfile` | 포털 버전 사용. 상단 `buildScript`, `testScript`, `buildImage`, `junitReports`만 수정 |
| 브랜치 | `develop`(dev 배포), `main`(운영 기준) — **master에 push하면 빌드되지 않음** |

---

## 9. 관리자 절차: DB 연결

앱이 DB를 쓰는 경우에만 한다. 예: 게시판 샘플(`samples/php-board`)을 `saeoll` 저장소에 적용한 경우.

### STEP 1. dev에 앱 전용 MariaDB 연결

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script
export SCM_ADMIN_PASSWORD
./add-db.sh saeoll php-service dev
```
출력: `Secrets saeoll-dev/php-service-db, ...`, `gitops apps/php-service/overlays/{dev}: MariaDB php-service-mariadb + envFrom php-service-db`

### STEP 2. 반영 확인 (2~3분)

```bash
kubectl -n saeoll-dev get pod,pvc
#  pvc data-php-service-mariadb-0   Bound   ...   nfs-client
#  php-service-mariadb-0            1/1 Running   (첫 기동 약 1분)
#  php-service-xxxx                 1/1 Running   (envFrom 추가로 새 Pod)
kubectl -n saeoll-dev get deploy php-service -o jsonpath='{.spec.template.spec.containers[0].envFrom}{"\n"}'
```
- Argo CD `saeoll-php-service-dev`: Healthy / Synced, 트리에 `sts php-service-mariadb`
- 게시판 샘플이면 `https://php-service-saeoll-dev.<도메인>/dbcheck.php` → `"status": "ok"`

### STEP 3. 운영에 연결 (dev 확인 후)

```bash
./add-db.sh saeoll php-service prod                 # dev와 다른 비밀번호의 Secret + overlays/prod
```
→ Argo CD `saeoll-php-service-prod` → **APP DIFF** 확인 → **SYNC** (관리자).

### 다른 방식

```bash
./add-db.sh saeoll php-service dev shared            # K-PaaS 공용 MariaDB에 전용 DB·계정 (빠른 확인용)
DB_HOST=db.example.com DB_NAME=shop DB_USER=shop DB_PASSWORD="$PW" \
  ./add-db.sh saeoll php-service prod external       # 이미 있는 DB
```

### DB 관리 명령

```bash
# 비밀번호 확인
kubectl -n saeoll-dev get secret php-service-db -o jsonpath='{.data.DB_PASSWORD}' | base64 -d; echo
# DB 접속 (dedicated)
kubectl -n saeoll-dev exec -it php-service-mariadb-0 -- sh -c 'mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'
# 백업
kubectl -n saeoll-prod exec php-service-mariadb-0 -- sh -c \
  'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction "$MARIADB_DATABASE"' > php-service-$(date +%F).sql
```

> Secret 값을 바꾼 뒤에는 앱 Pod를 재시작해야 적용된다: `kubectl -n saeoll-dev rollout restart deploy/php-service`

---

## 10. 관리자 절차: 배포 운영 (dev · 운영)

### 10-1. dev 배포 (자동)

개발자가 `develop`에 push → 5분 안에 Jenkins `<앱>-dev` → 이미지 → gitops dev 태그 → Argo CD 자동 배포.

| 확인 위치 | 기대 결과 |
| --- | --- |
| Jenkins `<앱>-dev` | 새 빌드 `#N dev dev-<커밋>-<N>`, Stage 모두 초록 |
| Console Output 끝 | `Pushed harbor.<도메인>/<업체>/<앱>:dev-...`, `gitops ... -> dev-...`, `Finished: SUCCESS` |
| Harbor | `<업체>/<앱>`에 `dev-...` 태그 |
| Argo CD `<업체>-<앱>-dev` | 3분 안에 Synced / Healthy (급하면 ⟳ REFRESH) |

### 10-2. 운영 배포 (관리자 승인)

1. (업체 PM) `develop` → `main` 머지, 태그 push:
   ```bash
   git checkout main && git pull && git merge --no-ff develop
   git tag -a v1.0.0 -m "v1.0.0" && git push origin main --follow-tags
   ```
2. (업체 PM 또는 관리자) Jenkins `<앱>-release` → **Build with Parameters** → `RELEASE_TAG=v1.0.0` → **Build**
3. (관리자, `cicd-admins` 계정) Argo CD `<업체>-<앱>-prod` → ⟳ REFRESH → **APP DIFF**(이미지 태그만 바뀌는지) →
   **SYNC** → 옵션 기본값 그대로 → **SYNCHRONIZE**
4. Healthy / Synced 확인 → `https://<앱>-<업체>.<도메인>` 확인 → 업체에 완료 통보

> 업체 계정으로 prod SYNC를 누르면 `permission denied`가 나온다(설계). release 빌드 전에 SYNC하면 `none-yet`으로 실패한다.

### 10-3. (선택) 운영도 자동 배포로 — 소스 수정 없이

release 빌드가 끝나면 바로 운영에 반영되게 하려면:

1. Argo CD `<업체>-<앱>-prod` → **DETAILS** → **ENABLE AUTO-SYNC**(PRUNE·SELF HEAL 켬), 또는
   ```bash
   kubectl -n cicd-argocd patch applications.argoproj.io saeoll-php-service-prod --type merge \
     -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
   ```
2. 승인 지점이 "release 빌드 실행"으로 바뀌므로 release 잡을 관리자 전용으로: Jenkins → `<앱>-release` → **Configure** →
   **Enable project-based security** → Inheritance **Do not inherit permission grants from other ACLs** →
   그룹 `cicd-admins`에 Job Read·Build·Cancel, Run Replay → **Save**

`add-app.sh`를 다시 실행하면 prod는 수동 Sync로 돌아간다(1번 다시 설정).

### 10-4. 롤백

| 대상 | 방법 |
| --- | --- |
| dev | `git revert` 후 develop push, 또는 Jenkins 이전 빌드 **Replay** |
| prod (수동 Sync) | Argo CD → **HISTORY AND ROLLBACK** → 이전 리비전 **Rollback** → gitops `overlays/prod`의 `newTag`도 이전 값으로 커밋 |
| prod (자동 Sync) | `<앱>-release`를 이전 태그로 다시 빌드 |

---

## 11. 개발자 작업 흐름 (업체에 안내)

### 11-1. PC 준비

```bash
git config --global http.https://scm-manager.<도메인>/.sslCAInfo ~/kpaas-ca.crt   # 관리자에게 받은 ca.crt
git config --global user.name "홍길동"; git config --global user.email "hong@example.com"
git clone -b develop https://scm-manager.<도메인>/scm/git/saeoll        # 아이디 / git 비밀번호
```
- SCM 저장소의 기본 브랜치는 `master`로 표시되므로 **반드시 `-b develop`**.
- 아이디 오타(예: `saeoll8455`)면 `Authentication failed`가 난다.

### 11-2. 일상 작업

```bash
git pull origin develop               # 시작 전 항상 (관리자가 Jenkinsfile을 갱신했을 수 있음)
# ... 수정 ...
git add -A && git commit -m "기능 추가" && git push origin develop
```
→ 5분 안에 Jenkins 빌드 → dev 자동 배포. 확인은 [웹 화면 가이드](web-ui-guide.md).

### 11-3. 게시판 샘플을 기존 저장소에 적용한 예

```bash
cd ~/php-sample && git checkout -B develop origin/develop
cp -r ~/php-board-app/public ~/php-board-app/src ~/php-board-app/sql .    # composer.json·Jenkinsfile은 기존 유지
grep -n "FROM\|pdo_mysql" Dockerfile                                       # bookworm, pdo_mysql 확인
git add public src sql && git commit -m "MariaDB 게시판" && git push origin develop
```

---

## 12. 일상 운영

### 12-1. 정기 작업

| 주기 | 작업 |
| --- | --- |
| 매일 | `./check-cicd-portal.sh` |
| 매주 | Jenkins 백업: PVC 스냅샷 또는 `kubectl -n cicd-jenkins exec jenkins-0 -c jenkins -- tar czf - --exclude=workspace -C /var/jenkins_home . > jenkins-home.tgz` |
| 매주 | 운영 DB 백업 (9장 백업 명령) |
| 매월 | Harbor 취약점 스캔, 베이스 이미지 갱신 |
| 분기 | `./deploy-cicd-portal.sh jenkins` (플러그인·보안 업데이트, 차트 버전 고정 상태에서) |

### 12-2. 인원·권한

| 작업 | 방법 |
| --- | --- |
| 업체 개발자 추가 | Keycloak 사용자 → `./onboard-vendor.sh saeoll <기존,신규>` 또는 그룹 `cicd-saeoll`에 추가 → SCM 저장소 참여자 추가 |
| 제외 | Keycloak 그룹·SCM 참여자에서 제거 |
| 운영 관리자 추가 | Keycloak 그룹 `cicd-admins` |
| 반영 | 해당 사용자 **로그아웃 → 재로그인** |

### 12-3. 비밀번호·토큰 변경 후 할 일

| 대상 | 할 일 |
| --- | --- |
| CI 계정 git 비밀번호 | `SCM_CI_PASSWORD=<새 값> ./onboard-vendor.sh <업체>` (기존 계정이면 `SCM_CI_USER`도) |
| Jenkins API 토큰 | 6장 STEP 5 다시 |
| Harbor robot | `./onboard-vendor.sh <업체>` (재발급·자동 반영) |
| 앱 DB 비밀번호 | dedicated: DB에서 `ALTER USER` 후 Secret 수정 → 앱 재시작. shared: `DB_SECRET_UPDATE=1 ./add-db.sh ... shared` |
| `scmadmin` | 바꾸지 않는 것을 권장 (K-PaaS 내부 사용) |

### 12-4. 포털 업데이트 반영

```bash
cd ~/Saeoll-PaaS && git pull && git log --oneline -3      # ★ 빠뜨리면 이전 버전으로 계속 동작
cd cicd-portal-deployment/script
./deploy-cicd-portal.sh jenkins                           # Jenkins 설정(플러그인·권한) 변경 시
./deploy-cicd-portal.sh argocd                            # Argo CD 설정 변경 시
SCM_REPO=<저장소> REPLACE_CI=1 ./add-app.sh <업체> <앱> <유형>   # Jenkinsfile 변경 시 (앱별)
```

### 12-5. 업체 자원·종료

```bash
QUOTA_CPU=8 QUOTA_MEMORY=16Gi QUOTA_PODS=50 ./onboard-vendor.sh saeoll     # 한도 변경
```
업체 종료: Argo CD 앱·프로젝트 삭제 → `kubectl delete ns saeoll-dev saeoll-prod` → Jenkins 폴더 삭제 → Harbor 프로젝트·robot, Keycloak 그룹, SCM 저장소 정리.

---

## 13. 문제 해결

**먼저 볼 곳**

| 무엇 | 어디 |
| --- | --- |
| 빌드 실패 원인 | Jenkins → 빌드 → **Console Output** 마지막 40줄 |
| 배포 실패 원인 | `kubectl -n <업체>-dev describe pod <Pod> \| tail -15` (Events) |
| 볼륨 문제 | `kubectl -n <업체>-dev describe pvc <PVC> \| tail -6` |
| Argo CD 적용 오류 | 앱 화면 **SYNC STATUS** / `kubectl -n cicd-argocd get app <앱> -o jsonpath='{.status.operationState.message}'` |
| 앱 로그 | `kubectl -n <업체>-dev logs deploy/<앱>` |

### 13-1. 설치

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| preflight `git is not installed` | git 없음 | `dnf install -y git` |
| preflight `StorageClass not found` | CP-Portal 값이 클러스터에 없음 | `cicd-vars.sh`의 `K8S_STORAGECLASS`에 실제 이름 |
| preflight `SCM ... HTTP 401` | `scmadmin` 비밀번호 오류 | SCM 내정보 관리의 **git 비밀번호** 사용 |
| Jenkins `CrashLoopBackOff` | 설정(JCasC) 오류 | `kubectl -n cicd-jenkins logs jenkins-0 -c jenkins --tail=100` → `git pull` 후 `./deploy-cicd-portal.sh jenkins` |
| Jenkins 기동이 오래 걸림 | 첫 플러그인 다운로드 | 최대 20분 대기 |

### 13-2. 업체 등록·앱 추가

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| 종료 코드 3 + 할 일 목록 | CI 계정 git 비밀번호 미입력 등 | 목록 처리 후 재실행 |
| `Jenkins API ... HTTP 302` | 토큰 미등록 | 6장 STEP 5 |
| Harbor robot `409` / `NameError` / gitops `not found` | 예전 스크립트 | `git pull` 후 재실행 |
| `scm-check ... no permission` | CI 계정이 저장소 참여자 아님 | SCM에서 보기 권한 |

### 13-3. 빌드 (Jenkins)

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| **develop push 후 빌드가 시작되지 않음** | ① `master`에 push ② 예전 Jenkinsfile이 첫 빌드 때 Poll SCM을 지움(잡 Configure → Build Triggers에서 꺼져 있음) | ① `git branch -vv`로 develop 확인 ② `git pull` 후 `SCM_REPO=<저장소> REPLACE_CI=1 ./add-app.sh ...` → 다음 빌드부터 복구. 급하면 **Build Now** |
| `No such DSL method 'junit'` | JUnit 플러그인 없음 + 예전 Jenkinsfile | `./deploy-cicd-portal.sh jenkins` + `REPLACE_CI=1` |
| `detected dubious ownership` | 예전 Jenkinsfile (경고, 결과 무관) | `REPLACE_CI=1` |
| Image 단계 `xz: Failed to enable the sandbox` | trixie 기반 `php:8.3-apache`가 kaniko에서 실패 | `php:8.3-apache-bookworm` |
| Image 단계 `UNAUTHORIZED` | Harbor robot | `./onboard-vendor.sh <업체>` |
| Deploy 단계 push 거부 | CI 계정 gitops 쓰기 권한 | `onboard-vendor.sh` 재실행 |
| `RELEASE_TAG must look like v1.2.0` / `Couldn't find any revision` | 태그 형식 / 태그 미 push | `vX.Y.Z`, `git push origin vX.Y.Z` |

### 13-4. 배포 (Argo CD)

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| dev Degraded, `...:none-yet not found` | 첫 빌드 미성공 | 빌드 성공시키면 자동 해결 (Harbor 저장소 수로 확인) |
| gitops push 후 Jenkins가 동작 안 함 | **정상** (gitops는 Argo CD가 감시) | Argo CD에서 반영 확인 |
| gitops clone 후 폴더가 비어 있음 | 기본 브랜치가 `master`인데 `main`만 있음 | `git checkout main` (처음부터 `git clone -b main ...`) |
| PVC Pending, `storageclass ... not found` | 없는 StorageClass 이름 | `kubectl get storageclass` 확인 → gitops `mariadb.yaml`의 `storageClassName` 삭제/수정 후 push → ↓ |
| Sync 오류 `StatefulSet ... spec: Forbidden: updates to statefulset spec ...` | StatefulSet 볼륨 설정은 변경 불가 | Argo CD revision이 새 커밋인지 확인 후 `kubectl -n <ns> delete sts <이름>` + `delete pvc <PVC>`(데이터 없을 때) → Argo CD가 재생성 |
| 앱 Pod `CreateContainerConfigError` | Secret `<앱>-db` 없음 | `./add-db.sh ...` |
| `dbcheck`: `db_host 127.0.0.1` | envFrom 미연결 | `./add-db.sh ...` (빠진 부분만 채움) |
| `dbcheck`: `2002` | MariaDB 미기동 | `kubectl -n <ns> get pod,pvc` |
| `dbcheck`: `1045` | Secret과 DB 계정 불일치 | MariaDB는 첫 기동 때 값만 사용 — 12-3 |
| `ImagePullBackOff` + `401` | pull secret | `./onboard-vendor.sh <업체>` |
| prod SYNC `permission denied` | 업체 계정 (설계) | 관리자 계정으로 |
| `exceeded quota` | 업체 한도 초과 | 12-5 |

### 13-5. 로그인·권한

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| 업체 계정 Jenkins 대시보드가 비어 있음 | 그룹 미포함/재로그인 안 함, 또는 권한 방식이 globalMatrix(예전) | `/whoAmI/`에 `cicd-<업체>` 확인 → 없으면 그룹 추가·재로그인, 있으면 `git pull` 후 `./deploy-cicd-portal.sh jenkins` |
| Argo CD에 업체 앱이 안 보임 | 그룹 미포함 | Keycloak 그룹 확인 → 재로그인 |
| git 401 | 로그인 비밀번호 사용 / 아이디 오타 | SCM **git 비밀번호**, 아이디 확인 |
| git 403 / not found | 참여자 아님 | SCM 참여자 추가 |

### 13-6. 진단 명령

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script
# Jenkins 빌드 목록·콘솔 (curl -g: 주소의 [ ] 를 그대로 전달)
bash -c 'source ./lib.sh; load_portal_vars
U=$(get_secret jenkins-user); T=$(get_secret jenkins-api-token); J="$JENKINS_URL/job/saeoll/job/php-service-dev"
curl -gsk -u "$U:$T" "$J/api/json?tree=builds[number,result,building]"; echo
curl -gsk -u "$U:$T" "$J/lastBuild/consoleText" | tail -40'
# Jenkins 권한 방식 (projectMatrix 여야 함)
kubectl -n cicd-jenkins get cm -o yaml | grep -n "globalMatrix\|projectMatrix"
# Argo CD 앱 상태
kubectl -n cicd-argocd get app saeoll-php-service-dev -o jsonpath='{.status.sync.revision}{"  "}{.status.sync.status}{"  "}{.status.health.status}{"\n"}{.status.operationState.message}{"\n"}'
# 업체 네임스페이스
kubectl -n saeoll-dev get pod,pvc,svc
# 업체 그룹에 사용자 추가 (재실행 안전)
bash -c 'source ./lib.sh; load_portal_vars; $API kc-group cicd-saeoll --members saeoll'
```

---

## 14. 삭제

```bash
./uninstall-cicd-portal.sh scm      # Jenkins (잡·credential·빌드 이력)
./uninstall-cicd-portal.sh gitlab   # GitLab + Runner
./uninstall-cicd-portal.sh all      # 위 둘 + Argo CD
```
- 그 소스를 쓰는 업체가 있으면 거부된다(`FORCE=1`로 강제).
- 업체 네임스페이스, Harbor, SCM 저장소, 앱 DB, K-PaaS 구성 요소는 **남는다**.

---

## 15. 부록

### 15-1. 명령 모음

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script
read -rsp 'scmadmin 비밀번호: ' SCM_ADMIN_PASSWORD; echo; export SCM_ADMIN_PASSWORD

# 설치
./deploy-cicd-portal.sh preflight
./deploy-cicd-portal.sh 2>&1 | tee cicd-portal-deploy.log
JENKINS_USER=admin JENKINS_API_TOKEN='<토큰>' ./deploy-cicd-portal.sh jenkins-token
./check-cicd-portal.sh

# 업체 (기존 계정을 CI 계정으로)
read -rsp 'CI 계정 git 비밀번호: ' SCM_CI_PASSWORD; echo; export SCM_CI_PASSWORD
SCM_CI_USER=saeoll ./onboard-vendor.sh --source scm saeoll saeoll

# 앱
./add-app.sh saeoll homepage php                                   # 새 저장소 saeoll-homepage
SCM_REPO=saeoll REPLACE_CI=1 ./add-app.sh saeoll php-service php   # 기존 저장소 saeoll

# DB
./add-db.sh saeoll php-service dev
./add-db.sh saeoll php-service prod

# 업데이트 반영
cd ~/Saeoll-PaaS && git pull && cd cicd-portal-deployment/script && ./deploy-cicd-portal.sh jenkins
```

### 15-2. 이름 규칙 (업체 `saeoll`, 앱 `php-service`)

| 대상 | 이름 |
| --- | --- |
| Keycloak 그룹 | `cicd-saeoll`, 관리자 `cicd-admins` |
| CI 계정 | `jenkins-saeoll` (또는 `SCM_CI_USER`) |
| SCM 저장소 | 소스 `saeoll-php-service` (또는 `SCM_REPO`), 배포 설정 `saeoll-gitops` |
| Harbor | 프로젝트 `saeoll`, 이미지 `saeoll/php-service:dev-<커밋>-<빌드>` / `:v1.0.0`, robot `robot$saeoll+cicd` |
| Jenkins | 폴더 `saeoll`, 잡 `php-service-dev`, `php-service-release`, credential `saeoll-harbor`, `saeoll-scm` |
| Argo CD | 프로젝트 `saeoll`, 앱 `saeoll-php-service-dev`, `saeoll-php-service-prod` |
| 네임스페이스 | `saeoll-dev`, `saeoll-prod` |
| DB | Secret `php-service-db`, `php-service-mariadb-root`, StatefulSet `php-service-mariadb`, PVC `data-php-service-mariadb-0` |
| URL | `https://php-service-saeoll-dev.<도메인>`, `https://php-service-saeoll.<도메인>` |

### 15-3. 비밀값이 저장되는 곳

| 비밀값 | 위치 |
| --- | --- |
| Jenkins OIDC secret, API 토큰, `jenkins-<업체>` Keycloak 비밀번호 | `cicd-jenkins/cicd-portal-secrets` |
| Argo CD OIDC secret | `cicd-argocd/cicd-portal-secrets` |
| gitops 저장소 접속 정보 | `cicd-argocd/repo-creds-<업체>-gitops` |
| Harbor robot, CI 계정 git 비밀번호 (빌드용) | Jenkins 폴더 credential `<업체>-harbor`, `<업체>-scm` |
| 이미지 pull | `<업체>-dev|prod/harbor-cicd` |
| 앱 DB | `<업체>-<환경>/<앱>-db`, `<앱>-mariadb-root` |
| Argo CD 비상 admin | `cicd-argocd/argocd-initial-admin-secret` |

비밀값은 Git에 넣지 않는다. 조회 예: `kubectl -n <ns> get secret <이름> -o jsonpath='{.data.<키>}' | base64 -d`
