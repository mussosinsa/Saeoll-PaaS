# Argo CD 적용 가이드 (배포)

CI/CD 포털에서 Argo CD는 **gitops 저장소에 적힌 설정(이미지 태그, DB 등)을 쿠버네티스에 그대로 적용**하는 역할이다.
scm·gitlab 업체가 공통으로 쓴다. dev는 자동 배포, **운영(prod)은 관리자가 SYNC 버튼으로 승인**한다.
화면 사용법은 [웹 화면 가이드](web-ui-guide.md) 2부를 본다.

| 솔루션 가이드 | |
| --- | --- |
| [소스 저장소 (SCM / GitLab)](guide-scm-gitlab.md) / [Harbor](guide-harbor.md) / [Jenkins](guide-jenkins.md) | |
| **Argo CD (이 문서)** | |
| [설치·관리 전체 가이드](install-guide.md) | |

---

## 1. 구성

| 항목 | 내용 |
| --- | --- |
| 주소 | `https://argocd.<도메인>` |
| 네임스페이스 | `cicd-argocd` (server, repo-server, application-controller, redis, applicationset) |
| 설치 | Helm 차트 `argo/argo-cd` `ARGOCD_CHART_VERSION`(7.8.0 = Argo CD 2.14), 원본 `values_orig/argocd.yaml` |
| 로그인 | **LOG IN VIA K-PAAS SSO** (Keycloak `cp-realm` 클라이언트 `cicd-argocd`, groups 클레임) |
| 비상 계정 | `admin` / `kubectl -n cicd-argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| 권한 | 기본 권한 없음(`policy.default: ""`), `cicd-admins` → `role:admin`, 업체 그룹은 업체 프로젝트 역할로 |
| 감시 주기 | gitops 저장소를 약 3분마다 확인 (즉시 반영: ⟳ REFRESH) |

### 1-1. 설치 시 적용되는 설정 (deploy-cicd-portal.sh argocd)

| 설정 | 내용 | 이유 |
| --- | --- | --- |
| `server.insecure: true` | TLS는 ingress-nginx에서 처리 | 인증서 이중 처리 방지 |
| Dex·알림 비활성화 | Keycloak에 직접 OIDC 연결 | 구성 단순화 |
| `oidc.config` + `rootCA` | issuer `https://keycloak.<도메인>/realms/cp-realm`, K-PaaS CA 포함 | 사설 인증서 Keycloak 신뢰 |
| OIDC 비밀값 | Helm 값 임시 파일(권한 600)로만 전달, Secret `argocd-secret`에 저장 | 명령줄·Git에 비밀값 없음 |
| `admin.enabled: true` | 로컬 admin 유지 | SSO 장애 시 비상 접속 |
| Ingress | `argocd.<도메인>`, TLS `<도메인>-tls` | |
| 설치 확인 | 모든 Deployment·StatefulSet 준비까지 대기 | `repo-server not ready` 방지 |

설정만 다시 적용: `./deploy-cicd-portal.sh argocd`

## 2. 업체·앱 단위로 만들어지는 것

### 2-1. 프로젝트 (onboard-vendor.sh)

| 항목 | 값 |
| --- | --- |
| AppProject `<업체>` | 라벨 `cicd.k-paas.org/source=scm|gitlab`, (scm) 어노테이션 `cicd.k-paas.org/scm-ci-user` |
| 소스 저장소 | `<업체>-gitops` 하나만 허용 |
| 배포 대상 | `<업체>-dev`, `<업체>-prod` 네임스페이스만 |
| 클러스터 리소스 | 금지 (`clusterResourceWhitelist: []`) |
| 금지 리소스 | ResourceQuota, LimitRange (업체 한도 변경 방지) |
| 역할 `developer` (그룹 `cicd-<업체>`) | 업체 앱 조회, 로그 보기, **`*-dev` 앱만 SYNC** |
| 저장소 접속 정보 | Secret `cicd-argocd/repo-creds-<업체>-gitops` (scm: CI 계정·git 비밀번호 / gitlab: 읽기 전용 프로젝트 토큰) |

### 2-2. 애플리케이션 (add-app.sh)

| 앱 | 경로 | 대상 | 동기화 |
| --- | --- | --- | --- |
| `<업체>-<앱>-dev` | gitops `apps/<앱>/overlays/dev` (main) | `<업체>-dev` | **자동** (prune·selfHeal) |
| `<업체>-<앱>-prod` | gitops `apps/<앱>/overlays/prod` (main) | `<업체>-prod` | **수동** (관리자 SYNC = 운영 승인) |

라벨: `cicd.k-paas.org/vendor`, `/app`, `/env`, `/type` → 화면 필터·스크립트에서 사용.

### 2-3. gitops 저장소 구조

```text
<업체>-gitops (main)
└── apps/<앱>/
    ├── base/            deployment.yaml (8080, 헬스 체크, 메모리 512Mi), service.yaml, ingress.yaml
    └── overlays/
        ├── dev/         kustomization.yaml: namespace <업체>-dev, replicas 1, host <앱>-<업체>-dev.<도메인>, newTag ← Jenkins <앱>-dev
        │                (+ add-db.sh: mariadb.yaml, envFrom <앱>-db)
        └── prod/        kustomization.yaml: namespace <업체>-prod, replicas 2, host <앱>-<업체>.<도메인>, newTag ← Jenkins <앱>-release
```

- `newTag`는 CI(Jenkins/GitLab)가 바꾼다. **사람이 바꾸는 것은 롤백할 때뿐**이다.
- gitops에 push해도 Jenkins는 동작하지 않는다(정상). Argo CD만 반영한다.
- clone은 `git clone -b main ...` (SCM 기본 브랜치가 master라 그냥 clone하면 빈 폴더).

## 3. 관리자 작업

### 3-1. 운영 배포 승인

전제: Jenkins `<앱>-release`가 `RELEASE_TAG=vX.Y.Z`로 성공 (gitops `overlays/prod`의 `newTag` 변경됨).

1. `cicd-admins` 계정으로 로그인
2. `<업체>-<앱>-prod` → ⟳ **REFRESH** → 상태 OutOfSync 확인
3. 앱 → **APP DIFF**: 바뀌는 내용이 `image: ...:vX.Y.Z`(와 의도한 설정)뿐인지 확인
4. **SYNC** → 옵션 기본값(PRUNE·FORCE·REPLACE 해제, 리소스 전체 선택) → **SYNCHRONIZE**
5. Progressing → **Healthy / Synced**, 운영 주소 확인 → 업체에 통보

업체 계정의 prod SYNC는 `permission denied: applications, sync, <업체>/<업체>-<앱>-prod` (설계된 동작).

### 3-2. 상태 읽기

| 앱 상태 | 의미 |
| --- | --- |
| dev Healthy / Synced | 정상 |
| dev Degraded + `none-yet` | 첫 빌드 전 — 빌드 성공 시 자동 해결 |
| prod Missing / OutOfSync | 운영 배포 전 (정상) |
| prod Healthy / OutOfSync | 새 release 빌드 완료, **승인 대기** |
| Progressing (오래 지속) | Pod 기동 실패·볼륨 대기 — 앱 상세에서 Pod EVENTS 확인 |
| Unknown / ComparisonError | gitops 저장소 접근·YAML 오류 — APP CONDITIONS 확인 |

### 3-3. 롤백

| 경우 | 방법 |
| --- | --- |
| prod (수동 Sync) | 앱 → **HISTORY AND ROLLBACK** → 이전 리비전 ⋮ → **Rollback** → 이후 gitops `overlays/prod`의 `newTag`도 이전 값으로 커밋(다음 SYNC 재배포 방지) |
| 자동 Sync 앱 (dev, 자동으로 바꾼 prod) | Rollback 메뉴 사용 불가 → 이전 커밋/태그로 다시 빌드 |

### 3-4. 운영 자동 배포로 전환 (선택, 소스 수정 없이)

```bash
kubectl -n cicd-argocd patch applications.argoproj.io <업체>-<앱>-prod --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
# 되돌리기
kubectl -n cicd-argocd patch applications.argoproj.io <업체>-<앱>-prod --type json \
  -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
```
자동으로 바꾸면 승인 지점이 Jenkins release 잡이 되므로 release 잡을 관리자 전용으로 제한한다([Jenkins 가이드](guide-jenkins.md) 4장).
`add-app.sh`를 다시 실행하면 수동으로 돌아간다.

### 3-5. 권한 부여

| 대상 | 방법 |
| --- | --- |
| 운영 관리자 | Keycloak 그룹 `cicd-admins` 추가 → 로그아웃·재로그인 |
| 업체 개발자 | Keycloak 그룹 `cicd-<업체>` → 로그아웃·재로그인 |
| 확인 | Argo CD → **User Info**의 Groups |

### 3-6. 점검 명령

```bash
kubectl -n cicd-argocd get pod
kubectl -n cicd-argocd get applications.argoproj.io                      # 전체 앱 Sync/Health
kubectl -n cicd-argocd get app saeoll-php-service-dev -o jsonpath=\
'{.status.sync.revision}{"  "}{.status.sync.status}{"  "}{.status.health.status}{"\n"}{.status.operationState.message}{"\n"}'
kubectl -n cicd-argocd annotate app saeoll-php-service-dev argocd.argoproj.io/refresh=hard --overwrite   # 강제 새로 읽기
kubectl -n cicd-argocd get appproject saeoll -o yaml | head -40
```
`revision`이 gitops `git log --oneline -1`의 커밋과 같으면 최신을 읽은 것이다.

### 3-7. 백업·업그레이드

| 작업 | 방법 |
| --- | --- |
| 백업 | 별도 데이터 없음 — 프로젝트·앱은 스크립트, 배포 내용은 gitops 저장소로 재현. 필요 시 `kubectl -n cicd-argocd get appprojects,applications -o yaml > argocd-objects.yaml` |
| 업그레이드 | `ARGOCD_CHART_VERSION` 변경 → `./deploy-cicd-portal.sh argocd` |
| SSO 장애 | 비상 `admin`으로 로그인, Keycloak 클라이언트 `cicd-argocd` 확인 후 `./deploy-cicd-portal.sh keycloak argocd` |

## 4. 문제 해결

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| dev Degraded, Pod `ImagePullBackOff` (`none-yet`) | 이미지 없음 | Jenkins 빌드 성공시키기 ([Harbor](guide-harbor.md) 저장소 수 확인) |
| 빌드 성공했는데 반영 안 됨 | 3분 주기 | ⟳ REFRESH, 안 되면 hard refresh |
| Sync 오류 `StatefulSet ... spec: Forbidden: updates to statefulset spec for fields other than ...` | StatefulSet 볼륨 설정(StorageClass 등)은 변경 불가 | revision이 새 커밋인지 확인 → `kubectl -n <ns> delete sts <이름>` + 데이터 없는 PVC 삭제 → Argo CD가 재생성 |
| PVC Pending, `storageclass ... not found` | 없는 StorageClass | gitops `mariadb.yaml`의 `storageClassName` 수정/삭제 → 위 절차 |
| 앱 Pod `CreateContainerConfigError` | 참조 Secret(`<앱>-db` 등) 없음 | `./add-db.sh ...` 또는 Secret 생성 |
| prod SYNC `permission denied` | 업체 계정 | 관리자 계정 |
| `repository not accessible` / `authentication required` | `repo-creds` 비밀번호 불일치(CI 계정 비밀번호 변경 등) | `./onboard-vendor.sh <업체>` |
| `namespace ... is not permitted in project` | 프로젝트 대상 외 네임스페이스 | overlay의 `namespace` 확인 |
| `resource ... is not permitted in project` | 금지 리소스(클러스터 리소스, ResourceQuota 등) | 관리자가 직접 적용하거나 설계 검토 |
| 업체 계정에 앱이 안 보임 | 그룹 미반영 | 3-5 |
| `exceeded quota` | 업체 한도 초과 | `QUOTA_* ./onboard-vendor.sh <업체>` |
| Pod 재시작 반복 (Degraded) | 헬스 체크·포트·메모리 | Pod LOGS, 8080 포트, `/healthz`, 메모리(기본 512Mi) |
