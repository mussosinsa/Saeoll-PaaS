# CI/CD 포털 배포 (GitLab / K-PaaS SCM + Argo CD)

K-PaaS 파이프라인(`cp-pipeline`)과 소스 컨트롤(`cp-source-control`) 배포는 **변경하지 않고**,
Java(Gradle/Maven)·PHP·Node.js·Vue 서비스를 위한 CI/CD를 별도로 구축한다.

두 소스를 함께 설치하고(`CICD_SOURCES`, 기본 `"scm gitlab"`), **업체를 등록할 때 업체별로 선택**한다
(`onboard-vendor.sh --source scm|gitlab`). Argo CD·Harbor·namespace·배포 구조는 공용이다.

| 소스 | 소스 저장소 | CI | 대상 | 업체 문서 |
| --- | --- | --- | --- | --- |
| `gitlab` | GitLab CE (`gitlab.<도메인>`) 비공개 그룹 | GitLab Runner | **외부 업체**: 업체 간 소스 분리, 코드 리뷰(MR) | [업체 개발자 가이드](docs/vendor-guide.md) |
| `scm` | K-PaaS 소스 컨트롤 (`scm.<도메인>`, SCM-Manager 1.x) | Jenkins (`jenkins.<도메인>`) | **내부 팀**, 기존 SCM 서비스 | [SCM 개발자 가이드](docs/vendor-guide-scm.md) |

> **외부 업체는 `gitlab`으로 등록한다.** K-PaaS 소스 컨트롤 웹 화면은 참여자가 아닌 사용자에게도 모든 저장소 목록과
> 파일 내용을 보여 준다(git clone/push만 참여자 권한으로 막힘, 실측 확인). `scm`은 신뢰할 수 있는 내부 사용자만 쓴다.
> `scm` 업체는 `migrate-vendor.sh`로 이력째 `gitlab`으로 옮길 수 있다.
>
> 운영 절차: [운영 관리자 가이드](docs/admin-guide.md)

아래 1~9장은 `scm`(Jenkins) 구성, [11장](#11-gitlab-구성)은 `gitlab` 구성이다.

```text
scm.<도메인>       K-PaaS SCM (기존) ── 업체 저장소 <업체>-<앱>, <업체>-gitops
                     │ Poll SCM 5분 (클러스터 내부 http)
jenkins.<도메인>   Jenkins (cicd-jenkins) ── 업체 폴더, 빌드는 Kubernetes Pod(빌드 도구 + kaniko)
                     │ build → test → 이미지 → Harbor push → <업체>-gitops 이미지 태그 갱신
harbor.<도메인>    Harbor (기존) ── 업체별 프로젝트, robot 계정
argocd.<도메인>    Argo CD (cicd-argocd) ── gitops 감시: dev 자동 Sync / prod 수동 Sync(cicd-admins)
                     ▼
                   <업체>-dev, <업체>-prod namespace
```

기존 시스템에는 다음만 **추가**한다.

| 대상 | 추가 내용 |
| --- | --- |
| Keycloak `cp-realm` | 클라이언트 `cicd-jenkins`, `cicd-argocd`(groups 매퍼), 그룹 `cicd-admins`·`cicd-<업체>`, 사용자 `jenkins-<업체>` |
| K-PaaS SCM | 저장소 `<업체>-gitops`, `<업체>-<앱>` (운영자가 `scm.` 화면에서 생성), 시작 소스·매니페스트 push |
| Harbor | 업체별 프로젝트, robot 계정 `robot$<업체>+cicd` |

## 1. 사전 조건

- CP-Portal, K-PaaS 소스 컨트롤(`cp-source-control-deployment`) 배포 완료
- `cp-portal-deployment/certs/ca.crt`(K-PaaS CA), `cp-portal` namespace의 TLS secret
- Master Node: `kubectl`, `helm`, `git`, `curl`, `python3`
- 자원: Jenkins 요청 0.5 CPU / 1Gi(상한 3Gi), PVC 20Gi + Argo CD 약 1Gi + 빌드 Pod(빌드당 최대 6Gi)
- 인터넷 접근: `charts.jenkins.io`·`updates.jenkins.io`(플러그인), Docker Hub(빌드 이미지), `gcr.io`(kaniko),
  `quay.io`·`ghcr.io`(Argo CD), `argoproj.github.io`. 폐쇄망이면 `CICD_DOCKERHUB`·`CICD_BASE_REGISTRY`를 Harbor 미러로 지정
- SCM 관리자 `scmadmin`(K-PaaS가 SCM-Manager 관리자로 사용하는 계정)의 비밀번호(`SCM_ADMIN_PASSWORD`).
  다른 계정을 쓰면 `SCM_ADMIN_USER=<계정>`을 함께 지정한다

## 2. 설정

`script/cicd-vars.sh`. 도메인·StorageClass·Keycloak·Harbor 값은 `cp-portal-vars.sh`에서 읽는다.

| 변수 | 기본값 | 설명 |
| --- | --- | --- |
| `CICD_SOURCES` | `scm gitlab` | 설치할 소스(공백 구분). 하나만 쓰면 `scm` 또는 `gitlab`. 환경변수로도 지정 가능 |
| `JENKINS_CHART_VERSION` | (최신) | 첫 설치 후 출력되는 차트 버전으로 고정 권장 |
| `JENKINS_SSO` | `true` | `false`면 차트 기본 로컬 admin (SSO 문제 해결용) |
| `SCM_ADMIN_USER` | `scmadmin` | SCM-Manager 관리자 (비밀번호는 환경변수 `SCM_ADMIN_PASSWORD`, 계정도 환경변수로 변경 가능) |
| `ARGOCD_CHART_VERSION` | `7.8.0` | Argo CD 2.14 |
| `CICD_DOCKERHUB` / `CICD_BASE_REGISTRY` | `docker.io/library` | 빌드 도구 이미지 / Dockerfile `BASE_REGISTRY` |
| `KANIKO_IMAGE` | `gcr.io/kaniko-project/executor:v1.23.2-debug` | 이미지 빌드 (원 프로젝트는 보관 상태, 필요 시 교체) |

## 3. 설치

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script
SCM_ADMIN_PASSWORD='<scmadmin 비밀번호>' ./deploy-cicd-portal.sh preflight
./deploy-cicd-portal.sh 2>&1 | tee cicd-portal-deploy.log      # preflight keycloak jenkins gitlab bootstrap templates runner argocd
```

| 단계 | 내용 |
| --- | --- |
| `preflight` | 도구, StorageClass, TLS secret, CA, Keycloak, IngressClass, SCM 실행·로그인, 노드 자원 |
| `keycloak` | 클라이언트 `cicd-jenkins`·`cicd-argocd` 생성, 그룹 `cicd-admins`에 포털 관리자 추가 |
| `jenkins` | Jenkins Helm 설치: K-PaaS SSO(oic-auth), `cicd-admins`=관리자, JVM에 K-PaaS CA 등록, Ingress |
| `argocd` | Argo CD Helm 설치: K-PaaS SSO, `cicd-admins`=관리자 |
| `jenkins-token` | (설치 후 1회) 스크립트용 Jenkins API 토큰 저장 |

설치 후 **Jenkins API 토큰 등록**(업체 등록·앱 추가 스크립트가 사용):

1. `cicd-admins` 그룹 사용자(예: `admin`)로 `https://jenkins.<도메인>` 로그인(K-PaaS SSO)
2. 우측 상단 사용자 → **Security** → API Token **Add new Token** → 복사
3. `JENKINS_USER=admin JENKINS_API_TOKEN='<토큰>' ./deploy-cicd-portal.sh jenkins-token`

생성된 비밀값은 `cicd-jenkins/cicd-portal-secrets`에 저장된다(OIDC secret, Jenkins API 토큰, `jenkins-<업체>` Keycloak 비밀번호).

## 4. 로그인

| 시스템 | 로그인 | 권한 |
| --- | --- | --- |
| SCM `https://scm.<도메인>` | Keycloak `cp-realm` 계정 | 저장소별 참여자(쓰기/보기) |
| Jenkins `https://jenkins.<도메인>` | **K-PaaS SSO** | `cicd-admins`: 관리자 / `cicd-<업체>`: 업체 폴더 조회·빌드 / 그 외: 읽기 |
| Argo CD `https://argocd.<도메인>` | **LOG IN VIA K-PAAS SSO** | `cicd-admins`: 관리자 / `cicd-<업체>`: 업체 앱 조회·dev Sync |

- Argo CD 비상 계정: `admin` / `kubectl -n cicd-argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`
- Jenkins SSO가 실패하면 `JENKINS_SSO=false ./deploy-cicd-portal.sh jenkins`로 로컬 admin 모드 전환 후 원인 확인
  (`kubectl -n cicd-jenkins get secret jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d`)
- Keycloak 그룹 변경 후에는 Jenkins·Argo CD에서 로그아웃/로그인한다.

## 5. 업체 등록

### 5-1. SCM 준비 (운영 관리자, `scm.<도메인>`)

| 항목 | 내용 |
| --- | --- |
| gitops 저장소 | **레파지토리 신규생성** → 이름 `<업체>-gitops`, 유형 Git |
| CI 계정 | `jenkins-<업체>`: `onboard-vendor.sh`가 Keycloak에 생성 → 그 계정으로 `scm.` **최초 로그인** → 내정보 관리에서 **git 비밀번호 설정** |
| 권한 | `<업체>-gitops` 참여자: `jenkins-<업체>` **쓰기 권한** |

저장소·권한은 반드시 `scm.` 화면에서 만든다(SCM-Manager 관리 화면에서 직접 만들면 K-PaaS 화면에 나오지 않는다).

### 5-2. 실행

```bash
export SCM_ADMIN_PASSWORD='<scmadmin 비밀번호>'
./onboard-vendor.sh --source scm saeoll saeoll,vendor-dev1   # 1차: Keycloak 사용자 jenkins-saeoll 생성 + 남은 할 일 출력
SCM_CI_PASSWORD='<jenkins-saeoll git 비밀번호>' ./onboard-vendor.sh saeoll saeoll,vendor-dev1   # 재실행 시 --source 생략 가능
```

SCM 준비가 덜 됐으면 할 일 목록을 출력하고 종료 코드 3으로 끝난다. 완료 후 다시 실행한다(재실행 안전).

| 생성물 | 내용 |
| --- | --- |
| Keycloak | 그룹 `cicd-saeoll`(+ 개발자), 사용자 `jenkins-saeoll` |
| Harbor | 프로젝트 `saeoll`, robot `robot$saeoll+cicd` |
| namespace | `saeoll-dev`, `saeoll-prod` (quota CPU 4 / 메모리 8Gi / Pod 30, pull secret `harbor-cicd`, TLS) |
| SCM | `saeoll-gitops` 초기화(README, main) |
| Jenkins | 폴더 `saeoll`(그룹 `cicd-saeoll` 조회·빌드), 폴더 credential `saeoll-harbor`, `saeoll-scm` |
| Argo CD | 프로젝트 `saeoll`(dev만 업체 Sync, prod는 `cicd-admins`), gitops 저장소 인증 |

## 6. 서비스 추가

1. `scm.` 화면에서 저장소 `<업체>-<앱>` 생성(Git), 참여자: `jenkins-<업체>` **보기**, 개발자 **쓰기**
2. 실행:

```bash
./add-app.sh saeoll homepage php            # java-gradle | java-maven | php | node | vue  [헬스 체크 경로]
```

| 생성물 | 내용 |
| --- | --- |
| 소스 `saeoll-homepage` | 시작 소스(Dockerfile, Jenkinsfile, 샘플 앱)를 `main`에 push, `develop` 브랜치 생성. 기존 파일은 덮어쓰지 않음 |
| gitops `saeoll-gitops` | `apps/homepage/base` + `overlays/dev,prod` (kustomize) |
| Jenkins | `saeoll/homepage-dev`(develop 폴링) 생성 후 첫 빌드 실행, `saeoll/homepage-release`(RELEASE_TAG) |
| Argo CD | `saeoll-homepage-dev`(자동 Sync), `saeoll-homepage-prod`(수동 Sync) |
| URL | dev `https://homepage-saeoll-dev.<도메인>`, prod `https://homepage-saeoll.<도메인>` |

기존 소스를 쓰려면 `main`에 먼저 push하고 `SKIP_STARTER=1 ./add-app.sh ...`. 저장소에는 8080 포트 Dockerfile,
헬스 체크 경로(기본 `/healthz`, PHP `/healthz.php`), `starters/<유형>/Jenkinsfile`을 추가한다.

## 7. 개발·배포 흐름

```bash
git clone -b develop https://scm-manager.<도메인>/scm/git/saeoll-homepage   # 사용자 / 내정보 관리의 git 비밀번호
```

SCM-Manager 1.x 저장소의 기본 브랜치(HEAD)는 `master`라서 `-b develop`(또는 `-b main`)으로 clone한다.

| 동작 | Jenkins | 배포 |
| --- | --- | --- |
| `develop` push | `<앱>-dev` (5분 내 자동): build → test → 이미지 `dev-<sha>-<번호>` | gitops dev 태그 갱신 → Argo CD 자동 Sync → `<업체>-dev` |
| 릴리스 | `git tag v1.0.0 && git push origin v1.0.0` → `<앱>-release`를 `RELEASE_TAG=v1.0.0`으로 실행 | gitops prod 태그 갱신 → **`cicd-admins`가 Argo CD에서 Sync** → `<업체>-prod` |
| 롤백 | - | Argo CD → History and Rollback, 또는 gitops overlay의 `newTag`를 이전 값으로 되돌림 |

Jenkinsfile은 저장소에 있으므로 빌드 명령·이미지를 서비스별로 수정할 수 있다(상단 `buildScript`, `testScript`, `buildImage`).

## 8. 점검과 삭제

```bash
SCM_ADMIN_PASSWORD='...' ./check-cicd-portal.sh   # Pod, SCM·Jenkins·Argo CD·Keycloak, API 로그인, Argo CD 앱 상태
./uninstall-cicd-portal.sh scm|gitlab|all         # 구성별 삭제 (사용 중인 업체가 있으면 거부, SCM 저장소·업체 namespace·Harbor 유지)
```

## 9. 운영 참고

- **네트워크**: Jenkins 빌드 Pod와 Argo CD는 SCM에 클러스터 내부 주소
  `http://cp-source-control-manager-service.cp-source-control.svc.cluster.local:8080/scm/git/<저장소>`로 접근한다
  (`cp-source-control` namespace는 K-PaaS Kyverno 기본 NetworkPolicy 대상에서 제외되어 있음).
- **사설 인증서**: K-PaaS CA를 Jenkins JVM truststore(초기화 컨테이너), Argo CD OIDC `rootCA`, 빌드 Pod(`/etc/cicd-ca/ca.crt`,
  kaniko `--registry-certificate`)에 넣는다.
- **격리**: 업체 credential은 Jenkins 폴더 범위라 다른 업체 job에서 쓸 수 없다. 단, 빌드 Pod는 공통 namespace(`cicd-jenkins`)에서
  실행되며 Jenkinsfile은 업체가 수정할 수 있으므로, 업체 수가 늘면 업체별 에이전트 namespace 분리를 검토한다.
- **SCM 제약**: 코드 리뷰(MR)·브랜치 보호·webhook이 없다. 운영 반영은 Argo CD 수동 Sync(`cicd-admins`)로 통제하고,
  빌드는 5분 폴링으로 시작한다. **웹 화면에서는 참여자가 아니어도 모든 저장소의 파일이 보이므로** 업체 간 소스 분리가
  필요하면 GitLab 모드를 쓴다. 웹의 "사용자 정보수정" 비밀번호는 SCM-Manager(git) 비밀번호만 바꾸고 Keycloak은 바꾸지 않는다.
- **백업**: Jenkins PVC(`cicd-jenkins`), SCM(K-PaaS 소스 컨트롤 PVC), gitops 저장소. Argo CD는 이 저장소와 gitops로 재현된다.

## 10. SCM-Manager 업그레이드 검토

**결론: K-PaaS 소스 컨트롤의 SCM-Manager(1.x)를 그 자리에서 최신(3.x)으로 올리는 것은 권장하지 않는다.**

| 항목 | 내용 |
| --- | --- |
| SCM-Manager 자체 | 1.60 이상이면 3.x로 데이터 이전 가능(사용자·그룹·저장소·권한). 3.x는 namespace/이름 구조로 바뀌어 첫 기동 시 이름 지정 마법사가 뜬다 |
| K-PaaS 연동 | K-PaaS 소스 컨트롤 API/UI는 1.x REST API(`/scm/api/rest/...`)를 쓰는 것으로 보인다(서버 로그·API 응답으로 확인). 3.x에는 이 API가 없어 **`scm.` 화면의 저장소 생성·사용자 등록·권한이 동작하지 않을 가능성이 크다** |
| 이미지 | `cp-source-control-manager:latest`는 K-PaaS가 빌드한 이미지라 공식 이미지로 바꾸면 K-PaaS 구성이 빠진다 |
| clone 주소 | `/scm/git/<이름>` → `/scm/repo/<namespace>/<이름>`으로 바뀌어 Jenkins·Argo CD·개발자 설정을 모두 고쳐야 한다 |
| SSO | 3.x에 공식 OIDC(Keycloak) 플러그인이 확인되지 않는다(제3자 플러그인만 존재) |

서버에서 버전과 API 사용을 확인하는 방법:

```bash
kubectl -n cp-source-control exec deploy/cp-source-control-manager-deployment -- \
  sh -c 'find / -name "scm-core-*.jar" 2>/dev/null | head -3'
kubectl -n cp-source-control logs deploy/cp-source-control-api-deployment --tail=500 | grep -m5 "api/rest"
```

최신 SCM이 필요하면 K-PaaS 소스 컨트롤은 그대로 두고 **별도로 구축**한다. 이 경우 Keycloak SSO·MR·webhook을 모두 갖춘
GitLab CE([11장](#11-gitlab-구성))가 SCM-Manager 3.x 별도 설치보다 적합하다. Argo CD·gitops·Dockerfile은 그대로 재사용된다.

## 11. GitLab 구성

`CICD_SOURCES`에 `gitlab`이 있으면 GitLab CE(Omnibus 단일 Pod) + GitLab Runner를 설치한다.

```bash
./deploy-cicd-portal.sh gitlab bootstrap templates runner        # 이미 scm·Argo CD가 설치된 경우 GitLab만 추가
PM_USERS=saeoll-pm ./onboard-vendor.sh --source gitlab saeoll saeoll-hong,saeoll-kim   # PM=Maintainer, 나머지=Developer
./add-app.sh saeoll homepage php
SCM_ADMIN_PASSWORD='...' PM_USERS=<PM> ./migrate-vendor.sh <scm 업체> <개발자들>      # scm 업체를 gitlab으로 이전
```

| 항목 | 내용 |
| --- | --- |
| 자원 | GitLab 요청 CPU 2 / 4Gi(상한 8Gi), PVC 56Gi, 빌드당 최대 4Gi |
| 로그인 | GitLab **K-PaaS SSO** (Keycloak 사용자에 이메일 필수). 비상: `root` / `cicd-gitlab/cicd-portal-secrets`의 `root-password` |
| CI | `cicd/ci-templates`의 언어별 템플릿을 `.gitlab-ci.yml`에서 include ([ci-templates](ci-templates/README.md)) |
| 흐름 | `develop` → dev 자동, 보호 태그 `vX.Y.Z`(Maintainer) → prod 태그 갱신 → Argo CD 수동 Sync |
| 백업 | `kubectl -n cicd-gitlab exec deploy/gitlab -- gitlab-backup create` + `/etc/gitlab` |
| 한계 | 단일 Pod(HA 아님). OIDC 그룹이 GitLab 그룹으로 동기화되지 않아 멤버십은 `onboard-vendor.sh`로 관리 |
| 운영 절차 | [운영 관리자 가이드](docs/admin-guide.md), [업체 개발자 가이드](docs/vendor-guide.md) |

소스 하나를 쓰지 않게 되면 `./uninstall-cicd-portal.sh scm`(또는 `gitlab`)으로 삭제한다. 그 소스를 쓰는 업체가 남아
있으면 거부된다. 전체 삭제는 `./uninstall-cicd-portal.sh all`.
