# CI/CD 포털 배포 (GitLab CE + GitLab Runner + Argo CD)

K-PaaS 파이프라인(`cp-pipeline`)과 소스 컨트롤(`cp-source-control`)은 **변경하지 않고**,
Java(Gradle/Maven)·PHP·Node.js·Vue 서비스를 위한 CI/CD 포털을 별도로 구축한다.

```text
[개발자] ── K-PaaS SSO (Keycloak cp-realm) ──┐
                                            ▼
 gitlab.<도메인>   GitLab CE  ── 그룹=업체, 프로젝트=서비스, MR·보호 태그
                     │ push / tag
                     ▼
 cicd-runner       GitLab Runner (Kubernetes executor)
                     │ build → test → kaniko 이미지 빌드
                     ▼
 harbor.<도메인>   Harbor (기존) ── 업체별 프로젝트, robot 계정
                     │ CI가 <업체>/gitops 의 이미지 태그 갱신
                     ▼
 argocd.<도메인>   Argo CD ── dev 자동 Sync / prod 수동 Sync(승인)
                     ▼
                  <업체>-dev, <업체>-prod namespace
```

| 구성요소 | namespace | 주소 | 비고 |
| --- | --- | --- | --- |
| GitLab CE (Omnibus, 단일 Pod) | `cicd-gitlab` | `https://gitlab.<도메인>` | PVC 3개(설정 1Gi, 로그 5Gi, 데이터 50Gi) |
| GitLab Runner | `cicd-runner` | - | 빌드 Pod도 이 namespace에서 실행, privileged 미사용 |
| Argo CD | `cicd-argocd` | `https://argocd.<도메인>` | Helm `argo/argo-cd` |
| Keycloak | (기존) `keycloak` | - | `cp-realm`에 클라이언트 `cicd-gitlab`, `cicd-argocd`, 그룹 `cicd-admins` **추가만** |
| Harbor | (기존) `harbor` | - | 업체별 프로젝트·robot 계정 추가 |

## 1. 사전 조건

- CP-Portal 배포 완료: Keycloak, Harbor, `cp-portal` namespace의 TLS secret, `cp-portal-deployment/certs/ca.crt`
- `kubectl`, `helm`, `curl`, `python3`(표준 라이브러리만 사용)
- 클러스터 여유 자원: GitLab 요청 CPU 2 / 메모리 4Gi(상한 8Gi) + Runner 빌드 Pod(빌드당 최대 4Gi) + Argo CD 약 1Gi
- StorageClass 여유 약 60Gi. GitLab 데이터는 NFS보다 블록 스토리지(Rook-Ceph RBD 등)를 권장
- Master Node와 Pod에서 인터넷 접근: Docker Hub(`gitlab/gitlab-ce`, 빌드 이미지), `registry.gitlab.com`(runner helper),
  `quay.io`·`ghcr.io`(Argo CD), `gcr.io`(kaniko), `charts.gitlab.io`, `argoproj.github.io`

```bash
kubectl top nodes
kubectl describe nodes | grep -A6 "Allocated resources"
kubectl get sc
```

## 2. 설정

`script/cicd-vars.sh`. 도메인·StorageClass·Keycloak 관리자·Harbor 계정은 `cp-portal-vars.sh`에서 읽으므로
보통은 수정하지 않는다.

| 변수 | 기본값 | 설명 |
| --- | --- | --- |
| `GITLAB_IMAGE` | `gitlab/gitlab-ce:17.11.1-ce.0` | 설치 전 [최신 패치 버전](https://hub.docker.com/r/gitlab/gitlab-ce/tags)으로 지정 권장 |
| `GITLAB_RUNNER_CHART_VERSION` | `0.76.0` | GitLab 버전과 같은 대(major.minor) 버전 권장 |
| `ARGOCD_CHART_VERSION` | `7.8.0` | Argo CD 2.14 |
| `GITLAB_DATA_SIZE` 등 | 50Gi / 1Gi / 5Gi | GitLab PVC 크기 |
| `CICD_DOCKERHUB` | `docker.io/library` | CI 도구 이미지 위치. 폐쇄망이면 Harbor 미러 경로 |
| `CICD_BASE_REGISTRY` | `docker.io/library` | Dockerfile `BASE_REGISTRY` (예: `harbor.<도메인>/base-images`) |
| `KEYCLOAK_ADMIN_GROUP` | `cicd-admins` | Argo CD 관리자 그룹(운영 배포 Sync 권한) |

## 3. 설치

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script
./deploy-cicd-portal.sh 2>&1 | tee cicd-portal-deploy.log
./check-cicd-portal.sh
```

단계별 실행도 가능하다(재실행 안전): `./deploy-cicd-portal.sh <단계> ...`

| 단계 | 내용 |
| --- | --- |
| `preflight` | 도구, StorageClass, TLS secret, CA, Keycloak, IngressClass, 이미지 태그, 노드 자원 확인 |
| `keycloak` | `cp-realm`에 클라이언트 `cicd-gitlab`·`cicd-argocd`(groups 매퍼) 생성, 그룹 `cicd-admins`에 포털 관리자 추가 |
| `gitlab` | GitLab CE 배포(TLS secret·CA 복사, Omnibus 설정, Ingress). 최초 기동 5~15분 |
| `bootstrap` | root 자동화 토큰 생성(`gitlab-rails runner`), 회원가입 차단, 인스턴스 CI 변수 등록 |
| `templates` | `cicd/ci-templates` 프로젝트에 언어별 CI 템플릿 업로드 |
| `runner` | Runner 등록(인스턴스 runner `cicd-k8s`), Helm 설치, online 확인 |
| `argocd` | Argo CD Helm 설치(Keycloak OIDC, `cicd-admins` → admin) |

생성된 비밀값은 `cicd-gitlab/cicd-portal-secrets`에 저장된다(root 비밀번호, 자동화 토큰, OIDC 클라이언트 secret).

## 4. 로그인

| 시스템 | 일반 로그인 | 비상(break-glass) 계정 |
| --- | --- | --- |
| GitLab | **K-PaaS SSO** 버튼 (Keycloak `cp-realm` 계정) | `root` / `kubectl -n cicd-gitlab get secret cicd-portal-secrets -o jsonpath='{.data.root-password}' \| base64 -d` |
| Argo CD | **LOG IN VIA K-PAAS SSO** | `admin` / `kubectl -n cicd-argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |

- **Keycloak 사용자에 이메일이 있어야 GitLab에 로그인된다.** Keycloak 관리 콘솔 → `cp-realm` → Users에서 Email 입력
  (Email verified 켬). 이메일이 없으면 "Email can't be blank"로 실패한다.
- GitLab 계정은 SSO 최초 로그인 시 자동 생성된다(사용자명 = Keycloak `preferred_username`). 회원가입은 막혀 있다.
- Argo CD 권한은 Keycloak 그룹으로 부여된다: `cicd-admins` = 전체 관리자, `cicd-<업체>` = 해당 업체 프로젝트
  조회 + dev Sync. 그룹 변경 후에는 Argo CD에서 로그아웃/로그인한다.

## 5. 업체 등록과 서비스 추가

```bash
# 업체 등록: GitLab 그룹·gitops 저장소, Harbor 프로젝트·robot, namespace, Argo CD 프로젝트
./onboard-vendor.sh saeoll saeoll,vendor-dev1

# 서비스 추가: 소스 프로젝트(starter), gitops 매니페스트, Argo CD 애플리케이션(dev/prod)
./add-app.sh saeoll homepage php            # java-gradle | java-maven | php | node | vue
./add-app.sh saeoll front vue
./add-app.sh saeoll api java-gradle
```

- `onboard-vendor.sh`의 사용자는 GitLab에 **한 번 로그인한 뒤** 그룹 멤버(Developer)로 추가된다.
  로그인 전이면 경고만 나오므로 로그인 후 같은 명령을 다시 실행한다. Keycloak 그룹(`cicd-<업체>`)은 바로 추가된다.
- `add-app.sh`는 기존 파일을 덮어쓰지 않는다. 기존 소스 저장소를 쓰려면 `SKIP_STARTER=1 ./add-app.sh ...` 후
  `starters/<유형>/.gitlab-ci.yml`의 `include`, 8080 포트로 동작하는 Dockerfile, 헬스 체크 경로(기본 `/healthz`,
  PHP `/healthz.php`)를 저장소에 추가한다.

| 생성물 | 위치 |
| --- | --- |
| 소스 | `https://gitlab.<도메인>/<업체>/<앱>` (main, develop, 보호 태그 `v*`) |
| GitOps | `<업체>/gitops` → `apps/<앱>/base`, `apps/<앱>/overlays/{dev,prod}` (kustomize) |
| 이미지 | `harbor.<도메인>/<업체>/<앱>:dev-<sha>-<번호>` / `:vX.Y.Z` |
| Argo CD | `<업체>-<앱>-dev`(자동 Sync), `<업체>-<앱>-prod`(수동 Sync) |
| URL | dev `https://<앱>-<업체>-dev.<도메인>`, prod `https://<앱>-<업체>.<도메인>` |

## 6. 개발·배포 흐름

| 동작 | 파이프라인 | 배포 |
| --- | --- | --- |
| feature 브랜치 push, MR | build, test | - |
| `develop` push/merge | build, test, image, deploy | gitops dev 태그 갱신 → Argo CD 자동 Sync → `<업체>-dev` |
| 태그 `vX.Y.Z` 생성(Maintainer만) | build, test, image, deploy | gitops prod 태그 갱신 → **`cicd-admins`가 Argo CD에서 Sync** → `<업체>-prod` |

롤백: Argo CD 애플리케이션 → History and Rollback, 또는 gitops 저장소에서 overlay의 `newTag`를 이전 값으로 되돌린다.

언어별 템플릿은 [ci-templates/README.md](ci-templates/README.md)를 참고한다. 템플릿을 고친 뒤에는
`./deploy-cicd-portal.sh templates`로 다시 올린다(모든 서비스에 즉시 적용되므로, 안정판은 태그 `v1.0.0` 등을 만들어
서비스에서 `ref: v1.0.0`으로 고정해도 된다).

## 7. 점검과 삭제

```bash
./check-cicd-portal.sh          # Pod, 엔드포인트, Keycloak 클라이언트, GitLab API·runner·템플릿, Argo CD 앱 상태
./uninstall-cicd-portal.sh      # GitLab(데이터 포함)·Runner·Argo CD·Keycloak 클라이언트 삭제, 업체 namespace·Harbor는 유지
```

## 8. 운영 참고

- **네트워크 정책**: K-PaaS Kyverno 정책이 새 namespace에 기본 NetworkPolicy를 만든다. GitLab Pod에는 기존 관례인
  `cp-role: shared` 라벨을 붙여 Runner·Argo CD가 클러스터 내부 주소(`http://gitlab.cicd-gitlab.svc.cluster.local`)로
  접근하게 했다.
- **사설 인증서**: K-PaaS CA를 GitLab(`/etc/gitlab/trusted-certs`), Argo CD(OIDC `rootCA`), 빌드 Pod(`/etc/cicd-ca/ca.crt`,
  kaniko `--registry-certificate`)에 넣는다. Runner·Argo CD는 GitLab에 내부 http로 접근하므로 인증서가 필요 없다.
- **백업**: `kubectl -n cicd-gitlab exec deploy/gitlab -- gitlab-backup create` (결과: `/var/opt/gitlab/backups`) +
  `gitlab-secrets.json`·`gitlab.rb`(`/etc/gitlab`). Argo CD 설정은 이 저장소와 gitops 저장소로 재현된다.
- **업그레이드**: `GITLAB_IMAGE`를 [지원 업그레이드 경로](https://docs.gitlab.com/update/upgrade_paths/)대로 한 단계씩 올리고
  `./deploy-cicd-portal.sh gitlab`. Runner 차트도 같은 버전대로 맞춘다.
- **한계**: GitLab은 Omnibus 단일 Pod(HA 아님, 재시작 시 수 분 중단)이다. 사용자·저장소가 늘면 GitLab 공식 Helm 차트
  (외부 PostgreSQL/Redis)로 이전을 검토한다. GitLab CE에서는 OIDC 그룹이 GitLab 그룹으로 자동 동기화되지 않으므로
  GitLab 멤버십은 `onboard-vendor.sh`로 관리한다.
- **토큰 만료**: 자동화 토큰과 gitops 프로젝트 토큰은 364일 후 만료된다. 만료 전 `./deploy-cicd-portal.sh bootstrap`
  (자동화 토큰: secret에서 `automation-token`을 지운 뒤 실행)과 `./onboard-vendor.sh <업체>`를 다시 실행한다.
