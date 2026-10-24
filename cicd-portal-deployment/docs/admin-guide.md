# CI/CD 포털 운영 관리자 가이드 (GitLab 모드)

업체(유지보수사)별로 소스를 분리해 Java(Gradle/Maven)·PHP·Node.js·Vue 서비스를 빌드·배포하는 CI/CD 포털의
운영 절차다. 업체 개발자용 안내는 [업체 개발자 가이드](vendor-guide.md)를 배포한다.

> **GitLab 모드를 쓰는 이유**: K-PaaS 소스 컨트롤(`scm.<도메인>`) 웹 화면은 참여자가 아닌 사용자에게도 모든 저장소와
> 파일을 보여 준다(git 접근만 권한으로 막힘). 업체 간 소스 분리가 필요하므로 업체 소스는 GitLab 비공개 그룹에 둔다.
> K-PaaS 소스 컨트롤은 내부·기존 서비스용으로 유지한다.

## 1. 구성과 역할

```text
업체 개발자 ── K-PaaS SSO(Keycloak cp-realm) ──▶ GitLab (gitlab.<도메인>)  소스·MR·파이프라인
                                                   │ develop / 태그 vX.Y.Z
                                                   ▼
                                     GitLab Runner (cicd-runner) 빌드·테스트·이미지
                                                   │ Harbor push, gitops 태그 갱신
                                                   ▼
운영 관리자 ── K-PaaS SSO ──────────────────▶ Argo CD (argocd.<도메인>)  dev 자동 / prod 승인 Sync
                                                   ▼
                                     <업체>-dev, <업체>-prod namespace
```

| 시스템 | 주소 (예: `<도메인>` = `192.168.20.151.nip.io`) |
| --- | --- |
| GitLab | `https://gitlab.<도메인>` |
| Argo CD | `https://argocd.<도메인>` |
| Harbor | `https://harbor.<도메인>` |
| Keycloak 관리 콘솔 | `https://keycloak.<도메인>/admin` → realm `cp-realm` |
| 서비스 | dev `https://<앱>-<업체>-dev.<도메인>` / prod `https://<앱>-<업체>.<도메인>` |

| 역할 | 계정 | 권한 |
| --- | --- | --- |
| 운영 관리자 | Keycloak 그룹 `cicd-admins` | Argo CD 전체 관리(운영 배포 승인), 스크립트 실행, GitLab 관리자(root는 비상용) |
| 업체 PM | GitLab **Maintainer** (`PM_USERS`) | `main` 머지, 릴리스 태그 `vX.Y.Z` 생성, 업체 프로젝트 설정 |
| 업체 개발자 | GitLab **Developer** | feature·`develop` 브랜치 push, MR 생성, 파이프라인 확인 |
| 업체 공통 | Keycloak 그룹 `cicd-<업체>` | Argo CD 업체 앱 조회·로그, dev Sync |

## 2. 설치와 점검

설치는 [배포 가이드](../README.md) 11장. 요약:

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script
export CICD_SOURCE=gitlab                 # 이 가이드의 모든 명령에 필요 (~/.bashrc 에 추가 권장)
./deploy-cicd-portal.sh preflight
./deploy-cicd-portal.sh                   # keycloak gitlab bootstrap templates runner argocd
./check-cicd-portal.sh                    # [RESULT] OK 확인
```

비상(break-glass) 계정 — SSO 장애 시에만 사용:

```bash
kubectl -n cicd-gitlab get secret cicd-portal-secrets -o jsonpath='{.data.root-password}' | base64 -d; echo   # GitLab root
kubectl -n cicd-argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo # Argo CD admin
```

## 3. 공통 사전 준비

### 3-1. K-PaaS CA 인증서 배포

사설 인증서를 쓰므로 업체 PC에서 git·브라우저가 인증서를 신뢰해야 한다.
`~/Saeoll-PaaS/cp-portal-deployment/certs/ca.crt`(공개 인증서, 비밀 아님)를 업체에 전달한다.
**`ca.key`는 절대 전달하지 않는다.**

### 3-2. 업체 사용자 계정 (Keycloak)

Keycloak 관리 콘솔 → realm **cp-realm** → **Users** → **Add user**

| 항목 | 값 |
| --- | --- |
| Username | 개인별 발급, `<업체>-<이름>` 권장 (예: `saeoll-hong`). 영문 소문자·숫자·`-` |
| Email | **필수** (없으면 GitLab 로그인 실패: "Email can't be blank") |
| Email verified | 켬 |
| First/Last name | 실명 |

저장 후 **Credentials** → **Set password** → 임시 비밀번호, **Temporary 켬**(첫 로그인 시 변경).
기존 포털 사용자도 Email이 비어 있으면 채운다(`admin` 포함).

## 4. 업체 등록

### 4-1. 등록 절차

1. 3-2로 PM·개발자 계정 생성 → ID·임시 비밀번호·`ca.crt`·[업체 개발자 가이드](vendor-guide.md) 전달
2. 업체 인원이 **GitLab에 한 번 로그인**(K-PaaS SSO)해야 GitLab 계정이 생긴다 → 로그인 완료 회신 받기
3. 등록 실행 (재실행 안전):

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script
CICD_SOURCE=gitlab PM_USERS=saeoll-pm ./onboard-vendor.sh saeoll saeoll-hong,saeoll-kim
#                  └ Maintainer         └ 업체 ID └ Developer 목록
```

`GitLab user ... not found` 경고가 나온 사용자는 아직 GitLab에 로그인하지 않은 것이다. 로그인 후 같은 명령을 다시 실행한다.

### 4-2. 생성 결과

| 시스템 | 생성물 |
| --- | --- |
| Keycloak | 그룹 `cicd-saeoll` (+ 지정 사용자) |
| GitLab | 비공개 그룹 `saeoll` (Developer/Maintainer), 프로젝트 `saeoll/gitops`, 그룹 CI 변수 `HARBOR_USER`·`HARBOR_PASSWORD`·`GITOPS_TOKEN` |
| Harbor | 비공개 프로젝트 `saeoll`, robot `robot$saeoll+cicd` (push/pull) |
| Kubernetes | `saeoll-dev`, `saeoll-prod` (ResourceQuota CPU 4 / 메모리 8Gi / Pod 30, LimitRange, pull secret `harbor-cicd`, TLS secret) |
| Argo CD | 프로젝트 `saeoll` (배포 대상 namespace 2개로 제한, `cicd-saeoll`: 조회·dev Sync) |

자원 한도 변경: `QUOTA_CPU=8 QUOTA_MEMORY=16Gi QUOTA_PODS=50 CICD_SOURCE=gitlab ./onboard-vendor.sh saeoll ...`

## 5. 서비스(앱) 추가

```bash
CICD_SOURCE=gitlab ./add-app.sh saeoll homepage php        # java-gradle | java-maven | php | node | vue
CICD_SOURCE=gitlab ./add-app.sh saeoll front vue
CICD_SOURCE=gitlab ./add-app.sh saeoll api java-gradle /actuator/health   # 헬스 체크 경로 지정
```

| 생성물 | 내용 |
| --- | --- |
| GitLab `saeoll/homepage` | 시작 소스(`.gitlab-ci.yml`, Dockerfile, 샘플)를 `main`에 커밋, `develop` 생성, 태그 `v*` 보호(Maintainer) |
| gitops `saeoll/gitops` | `apps/homepage/base`, `overlays/dev`, `overlays/prod` |
| Argo CD | `saeoll-homepage-dev`(자동 Sync), `saeoll-homepage-prod`(수동 Sync) |

`develop` 생성 시 첫 파이프라인이 자동 실행되어 dev에 배포된다(약 3~10분). 그 전까지 dev 앱은 `Degraded`로 보인다.

**기존 소스 이관**: `SKIP_STARTER=1 CICD_SOURCE=gitlab ./add-app.sh saeoll homepage php`로 빈 프로젝트를 만든 뒤
업체가 기존 이력을 push한다(`git remote add gitlab https://gitlab.<도메인>/saeoll/homepage.git && git push gitlab --all && git push gitlab --tags`).
저장소에 [업체 개발자 가이드 3장](vendor-guide.md#3-저장소-규칙)의 필수 파일이 있어야 한다.

**환경 설정·비밀값**(DB 접속정보 등): 업체 요청을 받아 운영 관리자가 gitops `apps/<앱>/overlays/<환경>`에
ConfigMap을 추가하거나 `kubectl -n <업체>-<환경> create secret generic <앱>-env --from-literal=...`로 Secret을 만들고
Deployment에 `envFrom`을 추가한다. 비밀값은 Git에 넣지 않는다.

## 6. 운영 배포 승인

1. 업체 PM이 태그 `vX.Y.Z`를 만들면 파이프라인이 이미지를 빌드하고 gitops `overlays/prod`의 태그를 바꾼다.
2. 업체의 운영 배포 요청서(업체 가이드 7장 양식)를 받는다.
3. 확인:
   - GitLab `saeoll/homepage` → **Build › Pipelines**: 해당 태그 파이프라인 성공
   - dev(`https://homepage-saeoll-dev.<도메인>`)에서 같은 기능 검증 완료 여부
   - Argo CD `saeoll-homepage-prod` → **APP DIFF**: 이미지 태그 외 변경이 없는지
4. Argo CD `saeoll-homepage-prod` → **SYNC** → **SYNCHRONIZE**
5. 상태 `Synced` / `Healthy`, 운영 URL 응답 확인 → 업체에 완료 통보

## 7. 롤백

| 대상 | 방법 |
| --- | --- |
| prod | Argo CD `<업체>-<앱>-prod` → **HISTORY AND ROLLBACK** → 이전 리비전 → **Rollback**. 이후 gitops `overlays/prod/kustomization.yaml`의 `newTag`도 이전 태그로 되돌려 커밋(다음 Sync 때 재배포 방지) |
| dev | 업체가 GitLab에서 이전 파이프라인의 `deploy` 잡 **Retry** (이전 이미지 태그를 다시 기록) |
| 긴급 | `kubectl -n <업체>-prod rollout undo deployment/<앱>` 후 위 gitops 정리 (Argo CD 자동 Sync가 아니므로 유지됨) |

## 8. 인원·업체 변경

| 작업 | 방법 |
| --- | --- |
| 인원 추가 | 3-2 계정 생성 → GitLab 1회 로그인 → `onboard-vendor.sh <업체> <기존+신규 목록>` 재실행 |
| PM 지정·변경 | `PM_USERS=<아이디> ... onboard-vendor.sh` 재실행, 또는 GitLab 그룹 → **Manage › Members**에서 역할 변경 |
| 인원 제외 | GitLab 그룹 Members에서 제거 + Keycloak 그룹 `cicd-<업체>`에서 제거(퇴사·계약 종료 시 Keycloak 사용자 비활성화) |
| 업체 종료 | ① Argo CD 앱·프로젝트 삭제 ② `kubectl delete ns <업체>-dev <업체>-prod` ③ GitLab 그룹 보관(Archive) 또는 백업 후 삭제 ④ Harbor 프로젝트·robot 삭제 ⑤ Keycloak 그룹·사용자 정리 |

## 9. 정기 운영

| 주기 | 작업 |
| --- | --- |
| 매일 | `CICD_SOURCE=gitlab ./check-cicd-portal.sh` |
| 매주 | GitLab 백업: `kubectl -n cicd-gitlab exec deploy/gitlab -- gitlab-backup create` → `/var/opt/gitlab/backups`를 외부로 복사. `/etc/gitlab/gitlab-secrets.json`도 함께 보관 |
| 매월 | Harbor 취약점 스캔 확인, 베이스 이미지 갱신, GitLab 보안 패치 검토 |
| 연 1회 (364일) | 토큰 갱신: `onboard-vendor.sh <업체>` 재실행(gitops 토큰), 자동화 토큰은 만료 후 `./deploy-cicd-portal.sh bootstrap` |
| 수시 | CI 템플릿 수정 후 `./deploy-cicd-portal.sh templates` (모든 서비스에 즉시 적용되므로 dev에서 먼저 확인) |

GitLab 업그레이드: `cicd-vars.sh`의 `GITLAB_IMAGE`를 [업그레이드 경로](https://docs.gitlab.com/update/upgrade_paths/)에 따라
한 단계씩 올리고 `CICD_SOURCE=gitlab ./deploy-cicd-portal.sh gitlab` (백업 후, 수 분 중단).

## 10. 장애 대응

| 증상 | 확인 | 조치 |
| --- | --- | --- |
| GitLab SSO 로그인 실패 "Email can't be blank" | Keycloak 사용자 Email | Email 입력, Email verified 켬 |
| 파이프라인이 `pending`에서 멈춤 | GitLab **Admin › CI/CD › Runners**의 `cicd-k8s` 상태 | `kubectl -n cicd-runner logs deploy/gitlab-runner`, 필요 시 `./deploy-cicd-portal.sh runner` |
| `image` 잡: `UNAUTHORIZED` | 그룹 CI 변수 `HARBOR_USER`/`HARBOR_PASSWORD` | `onboard-vendor.sh <업체>` 재실행(robot 재발급) |
| `image` 잡: `manifest unknown` (베이스 이미지) | `CICD_BASE_REGISTRY` 경로에 이미지 존재 여부 | Harbor `base-images`에 등록(`cp-pipeline-deployment/script/mirror-base-images.sh <이미지>`) |
| `deploy` 잡: `overlays/... not found` | gitops 저장소 | `add-app.sh <업체> <앱> <유형>` 재실행 |
| Argo CD `ImagePullBackOff` | `kubectl -n <업체>-dev describe pod` | pull secret `harbor-cicd` 확인 → `onboard-vendor.sh` 재실행 |
| Argo CD `Degraded`, Pod 재시작 반복 | `kubectl -n <업체>-dev logs deploy/<앱>` | 헬스 체크 경로·8080 포트·메모리(기본 512Mi) 확인 |
| `exceeded quota` | `kubectl -n <업체>-dev describe resourcequota` | quota 상향(4-2) 또는 업체에 자원 조정 요청 |

## 11. 권한 요약

| 작업 | 업체 개발자 | 업체 PM | 운영 관리자 |
| --- | --- | --- | --- |
| feature·`develop` push, MR 생성 | O | O | O |
| `main` 머지, 태그 `vX.Y.Z` 생성 | X | O | O |
| 파이프라인 조회·재실행 | O | O | O |
| gitops 저장소 직접 수정 (`main`) | X | O | O |
| Argo CD 조회·로그 | O | O | O |
| Argo CD dev Sync | O | O | O |
| **Argo CD prod Sync (운영 배포)** | X | X | **O** |
| 업체 등록·앱 추가·quota 변경 | X | X | O |
