# 소스 저장소 적용 가이드: K-PaaS SCM / GitLab

CI/CD 포털에서 **소스 코드와 배포 설정(gitops)을 보관하는 저장소**의 적용·운영 방법이다.
업체마다 `scm` 또는 `gitlab` 중 하나를 쓴다(`onboard-vendor.sh --source`).

| 솔루션 가이드 | |
| --- | --- |
| **소스 저장소 (이 문서)** | K-PaaS SCM(SCM-Manager 1.x) / GitLab CE |
| [Harbor](guide-harbor.md) | 이미지 저장소 |
| [Jenkins](guide-jenkins.md) | 빌드 (scm 업체) |
| [Argo CD](guide-argocd.md) | 배포 |
| [설치·관리 전체 가이드](install-guide.md) | 처음부터 끝까지 순서 |

---

## 1. 두 방식 비교

| 항목 | K-PaaS SCM (`scm`) | GitLab CE (`gitlab`) |
| --- | --- | --- |
| 설치 | K-PaaS 소스 컨트롤 패키지(`cp-source-control-deployment`) | 포털이 설치(`deploy-cicd-portal.sh gitlab ...`) |
| 웹 주소 | `https://scm.<도메인>` (K-PaaS 화면) | `https://gitlab.<도메인>` |
| git 주소 | `https://scm-manager.<도메인>/scm/git/<저장소>` | `https://gitlab.<도메인>/<업체>/<앱>.git` |
| 로그인 | Keycloak 계정 + **별도 git 비밀번호** | Keycloak SSO + 개인 액세스 토큰(git) |
| 빌드 | Jenkins | GitLab Runner |
| 업체 간 소스 분리 | **안 됨** — 웹 화면은 로그인한 누구에게나 모든 저장소 파일을 보여 줌(git만 권한 제한) | 됨 (비공개 그룹) |
| 코드 리뷰(MR)·브랜치 보호·webhook | 없음 (5분 폴링) | 있음 |
| 자원 | 기존 K-PaaS 사용 (추가 없음) | CPU 2 / 메모리 4Gi(상한 8Gi), 디스크 56Gi |
| 권장 대상 | 내부 팀, 기존 SCM 사용자 | **외부 업체** |

---

# 1부. K-PaaS SCM (SCM-Manager 1.x)

## 2. 구성

```text
scm.<도메인>               K-PaaS 소스 컨트롤 UI  ── 사용자·저장소·참여자 관리 (평소 사용)
scm-manager.<도메인>/scm   SCM-Manager 1.x       ── git clone/push, REST API(/scm/api/rest), 관리 화면(scmadmin)
cp-source-control          네임스페이스: cp-source-control-api / -manager / -ui Pod
클러스터 내부 git 주소     http://cp-source-control-manager-service.cp-source-control.svc.cluster.local:8080/scm/git/<저장소>
                           (Jenkins 빌드 Pod·Argo CD가 사용)
```

설치·점검: [`cp-source-control-deployment/README.md`](../../cp-source-control-deployment/README.md)

```bash
cd ~/Saeoll-PaaS/cp-source-control-deployment/script
./deploy-cp-source-control.sh                         # 설치 (패키지 자동 다운로드)
SCM_ADMIN_PASSWORD='...' ./check-cp-source-control.sh  # 점검
```

## 3. 계정과 비밀번호 (가장 헷갈리는 부분)

| 계정 | 용도 | 비밀번호 |
| --- | --- | --- |
| 일반 사용자 (Keycloak `cp-realm`) | `scm.` 로그인 | Keycloak 비밀번호 |
| 같은 사용자의 **git** 접근 | clone/push | `scm.` → 오른쪽 위 계정 → **내정보 관리** → 비밀번호 변경으로 설정한 **git 비밀번호** (Keycloak과 별개) |
| `scmadmin` | SCM-Manager 관리자. 포털 스크립트가 저장소 생성·확인에 사용 | K-PaaS 설치 기본값. **K-PaaS 내부에서 쓰므로 함부로 바꾸지 않는다** |
| CI 계정 (`jenkins-<업체>` 또는 기존 계정) | Jenkins·Argo CD가 저장소 접근 | CI 계정의 git 비밀번호 (포털이 Jenkins credential·Argo CD에 저장) |

- 사용자는 `scm.`에 **최초 1회 로그인**해야 SCM 계정이 생긴다. 그 전에는 참여자로 추가할 수 없다.
- `scm.` 웹의 "사용자 정보 수정"에서 바꾼 비밀번호는 git 비밀번호만 바뀌고 Keycloak은 바뀌지 않는다.
- CI 계정의 git 비밀번호를 바꾸면 `onboard-vendor.sh`를 다시 실행해야 한다(Jenkins·Argo CD에 저장된 값 갱신).

## 4. 포털이 쓰는 저장소

| 저장소 | 만드는 곳 | 권한 | 내용 |
| --- | --- | --- | --- |
| 소스 `<업체>-<앱>` (또는 기존 이름, `SCM_REPO`) | 관리자가 `scm.` 화면에서 | CI 계정 **보기**, 개발자 **쓰기** | 앱 소스, Dockerfile, Jenkinsfile. 브랜치 `develop`(dev), `main`(운영), 태그 `vX.Y.Z` |
| 배포 설정 `<업체>-gitops` | `onboard-vendor.sh`가 SCM-Manager API로 자동 생성 | CI 계정 **쓰기** | `apps/<앱>/base`, `overlays/dev`, `overlays/prod`. 브랜치 `main` |

- `<업체>-gitops`는 SCM-Manager에 직접 만들기 때문에 **`scm.` 화면 목록에는 나오지 않는다**(정상).
  SCM-Manager 관리 화면(`https://scm-manager.<도메인>/scm`, `scmadmin`)에서 보인다.
- 반대로 소스 저장소는 반드시 `scm.` 화면에서 만든다(SCM-Manager에서 직접 만들면 `scm.`에 안 나옴).
- SCM-Manager 1.x 저장소의 기본 브랜치(HEAD)는 항상 `master`다. 그래서
  - 소스: `git clone -b develop ...`
  - gitops: `git clone -b main ...` (그냥 clone하면 `remote HEAD refers to nonexistent ref` 경고와 함께 빈 폴더)

## 5. 관리자 작업

### 5-1. 새 앱의 소스 저장소 준비

1. `https://scm.<도메인>` → 레파지토리 → **신규생성** (유형 Git, 이름 `<업체>-<앱>`)
2. 저장소 상세 → **참여자 추가**: CI 계정 **보기 권한**, 업체 개발자 **쓰기 권한**
3. `./add-app.sh <업체> <앱> <유형>` (기존 이름이면 `SCM_REPO=<저장소>`)

### 5-2. 저장소 상태 확인

| 확인 | 방법 |
| --- | --- |
| 브랜치별 커밋 | SCM-Manager 관리 화면 → Repositories → 저장소 → **Commits** → 오른쪽 위 **Branches**에서 `develop` 선택 (기본은 master만 보임) |
| 사용자 등록 | `SCM_ADMIN_PASSWORD=... SCM_CHECK_USER=saeoll ./check-cp-source-control.sh` |
| git 접근 | `git ls-remote https://scm-manager.<도메인>/scm/git/<저장소>` |
| REST API | `curl -sk -u scmadmin https://scm-manager.<도메인>/scm/api/rest/repositories.json` |

### 5-3. 개발자 PC 설정 (업체에 안내)

```bash
git config --global http.https://scm-manager.<도메인>/.sslCAInfo ~/kpaas-ca.crt   # K-PaaS ca.crt
git clone -b develop https://scm-manager.<도메인>/scm/git/<저장소>                # ID / git 비밀번호
```

### 5-4. 백업

SCM 데이터는 `cp-source-control` 네임스페이스의 PVC와 MariaDB `cp_scm` DB에 있다. PVC 스냅샷과 DB 덤프를 함께 백업한다.

### 5-5. 업그레이드

K-PaaS SCM-Manager(1.x)를 3.x로 그 자리에서 올리는 것은 **권장하지 않는다**(K-PaaS UI가 1.x API 사용, 저장소 주소 변경,
SSO 플러그인 부재). 최신 기능이 필요하면 GitLab 방식을 쓰고 `migrate-vendor.sh`로 업체를 옮긴다(README 10장).

## 6. 문제 해결 (SCM)

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| git `Authentication failed` (401) | 로그인 비밀번호 사용, 아이디 오타, git 비밀번호 미설정 | 내정보 관리에서 git 비밀번호 설정 후 그 값 사용 |
| git 403 / `not found` | 참여자 아님 | `scm.`에서 참여자 추가 |
| `scm-manager.` 화면 `ERR_TOO_MANY_REDIRECTS` | 같은 브라우저의 `scm.`·Keycloak 쿠키 | 시크릿 창 사용 |
| 다른 사람 저장소가 웹에서 보임 | SCM 웹의 구조적 한계 | 외부 업체는 GitLab 사용 |
| 저장소를 만들었는데 `scm.` 목록에 없음 | SCM-Manager에서 직접 생성 | `scm.` 화면에서 생성 (gitops는 예외, 정상) |
| clone 후 폴더가 비어 있음 | 기본 브랜치 `master` 없음 | `git checkout main` / `-b develop` |
| preflight `SCM ... HTTP 401` | `scmadmin` 비밀번호 오류 | git 비밀번호 확인 |
| `/scm/api/v2` 404 | 1.x에는 v2 API 없음 | 정상 |

---

# 2부. GitLab CE

## 7. 구성

| 항목 | 내용 |
| --- | --- |
| 배포 | `manifests/gitlab.yaml` (Omnibus 단일 Pod, 네임스페이스 `cicd-gitlab`), 이미지 `GITLAB_IMAGE` |
| 디스크 | data 50Gi, config 1Gi, logs 5Gi (`cicd-vars.sh`) |
| 로그인 | Keycloak `cp-realm` 클라이언트 `cicd-gitlab` (OIDC). 회원가입 비활성화 |
| 비상 계정 | `root` / `kubectl -n cicd-gitlab get secret cicd-portal-secrets -o jsonpath='{.data.root-password}' \| base64 -d` |
| 자동화 토큰 | root의 개인 토큰 `cicd-automation` (364일), Secret `automation-token` |
| Runner | `gitlab-runner` 차트(`cicd-runner`), Kubernetes executor, 동시 4개, 빌드당 최대 4Gi |
| CI 템플릿 | 프로젝트 `cicd/ci-templates` (내부 공개), 앱의 `.gitlab-ci.yml`이 include |
| 인스턴스 CI 변수 | `HARBOR_HOST`, `CICD_DOCKERHUB`, `CICD_BASE_REGISTRY`, `KANIKO_IMAGE`, `CICD_CA_FILE`, `GITOPS_HOST`, `CICD_HOST_DOMAIN` |

설치 단계(`deploy-cicd-portal.sh`):

| 단계 | 하는 일 |
| --- | --- |
| `gitlab` | 매니페스트 적용 → 재시작 → 준비 대기(첫 기동 5~15분) |
| `bootstrap` | root 자동화 토큰 생성(gitlab-rails), 회원가입 끄기, 인스턴스 CI 변수 |
| `templates` | `ci-templates/` → `cicd/ci-templates` 동기화, 태그 `v*` 보호 |
| `runner` | Runner 등록 토큰 생성 → 차트 설치 → online 확인 |

## 8. 업체·앱 단위로 만들어지는 것

| 스크립트 | GitLab 생성물 |
| --- | --- |
| `onboard-vendor.sh --source gitlab` | 비공개 그룹 `<업체>`(개발자 Developer, `PM_USERS` Maintainer), 프로젝트 `<업체>/gitops`, 프로젝트 토큰(CI 쓰기용·Argo CD 읽기용), 그룹 CI 변수 `GITOPS_TOKEN`·`HARBOR_USER`·`HARBOR_PASSWORD` |
| `add-app.sh` | 프로젝트 `<업체>/<앱>`(시작 소스·`.gitlab-ci.yml`), `develop` 브랜치, 태그 `v*` 보호, gitops `apps/<앱>` |

업체 사용자는 **GitLab에 한 번 로그인**해야 계정이 생기고, 그 뒤 `onboard-vendor.sh`를 다시 실행해야 그룹 멤버가 된다.
Keycloak 사용자에 **Email이 없으면 로그인 실패**("Email can't be blank").

## 9. 관리자 작업

| 작업 | 방법 |
| --- | --- |
| CI 템플릿 수정 | `ci-templates/` 수정 → `./deploy-cicd-portal.sh templates` (모든 앱에 즉시 적용 — dev에서 먼저 확인) |
| Runner 상태 | GitLab **Admin → CI/CD → Runners** (`cicd-k8s` online), `kubectl -n cicd-runner logs deploy/gitlab-runner` |
| 멤버 변경 | GitLab 그룹 → Manage → Members, 또는 `onboard-vendor.sh` 재실행 |
| 백업 | `kubectl -n cicd-gitlab exec deploy/gitlab -- gitlab-backup create` + `/etc/gitlab/gitlab-secrets.json` 보관 |
| 업그레이드 | `GITLAB_IMAGE`를 [업그레이드 경로](https://docs.gitlab.com/update/upgrade_paths/)대로 한 단계씩 → `./deploy-cicd-portal.sh gitlab` |
| 토큰 갱신(연 1회) | 자동화 토큰 만료 시 `./deploy-cicd-portal.sh bootstrap`, gitops 토큰은 `onboard-vendor.sh <업체>` |
| scm 업체 이전 | `PM_USERS=<PM> ./migrate-vendor.sh <업체> <개발자들>` |

## 10. 문제 해결 (GitLab)

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| 로그인 "Email can't be blank" | Keycloak 사용자 Email 없음 | Email 입력, Email verified 켬 |
| 파이프라인 `pending` | Runner offline | Runners 화면, `./deploy-cicd-portal.sh runner` |
| `GitLab user ... not found` (onboard) | 아직 로그인 안 함 | 로그인 후 재실행 |
| GitLab 기동 실패 | 메모리·디스크 부족 | `kubectl -n cicd-gitlab logs deploy/gitlab --tail=100`, 노드 자원 |
