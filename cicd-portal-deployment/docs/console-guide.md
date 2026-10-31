# CI/CD 콘솔 가이드 (`https://cicd.<도메인>`)

CI/CD 포털(GitLab / K-PaaS SCM + Jenkins + Argo CD)을 웹 화면 하나에서 조회·운영하는 콘솔이다.
`ap-pipeline-ui`(어플리케이션 플랫폼 배포파이프라인 WEB UI, 기술지원 종료)의 화면 구성을 참고해 새로 만들었다.
Cloud Foundry UAA·4개 REST API에 의존하던 원본 대신, 이미 있는 CI/CD 포털 스크립트와 Keycloak·Jenkins·GitLab·Argo CD API를
그대로 사용하므로 별도 DB나 백엔드 서버가 없다.

> 사용 방법(초보자용): [운영 관리자 가이드 — 업체 등록·앱 추가](console-admin-guide.md) · [업체 가이드 — 개발·배포](console-vendor-guide.md)

## 1. ap-pipeline-ui 기능 대응

| ap-pipeline-ui | CI/CD 콘솔 | 구현 |
| --- | --- | --- |
| 파이프라인 목록 (대시보드) | 대시보드 · 업체 화면의 애플리케이션 카드 | Argo CD AppProject(업체), Application `<업체>-<앱>-dev/prod` |
| 파이프라인 상세 (Build → Test → Deploy Job) | 앱 화면의 5단계 흐름: 소스 → 빌드·이미지 → dev 배포 → 릴리스 → prod 배포 | Jenkins job `<앱>-dev`/`<앱>-release` 또는 GitLab 파이프라인 + Argo CD 상태 |
| Job 실행 / 중지 | 빌드 실행, 중지 | Jenkins `buildWithParameters`·`stop`, GitLab `pipeline`·`cancel` |
| Job 로그 · 이력 | 빌드 이력, 실시간 빌드 로그 | Jenkins `progressiveText`, GitLab job trace |
| 배포 Job · 롤백 | dev/prod Sync, prod 배포 이력에서 롤백 | Argo CD Application `.operation` (argocd app sync와 동일) |
| 저장소 브랜치/태그 조회 | 릴리스 태그 선택 | SCM-Manager 1.x `tags.json`, GitLab tags API |
| 참여자(Contributor) 관리 | 업체 구성원 추가·제외 | Keycloak 그룹 `cicd-<업체>` (+ GitLab 그룹 Developer) |
| 서비스 인스턴스 · 사용자 · 권한 | 업체 등록, 앱 추가, DB 연결 (운영 관리자) | `onboard-vendor.sh`, `add-app.sh`, `add-db.sh`를 백그라운드 실행 |
| 품질 이슈 · 코딩 규칙 · 품질 프로파일 · 품질 게이트 (SonarQube) | **품질 관리** 메뉴: 보안 이슈 · 검사 규칙 · 검사 프로파일 · 보안 게이트 · 예외 관리 | 파이프라인 보안 검사(Semgrep, Gitleaks, Trivy, 개인정보) 결과 — [보안 검사 · 품질 관리 가이드](security-guide.md) |
| CF 정보 · 바이너리 저장소 | 제외 | Kubernetes·Harbor로 대체 |

## 2. 설치

CI/CD 포털 설치(`./deploy-cicd-portal.sh`)가 끝난 뒤 관리 노드에서 실행한다. podman은 CP-Portal 설치 때 들어간다(`install_tools.sh`).

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script
SCM_ADMIN_PASSWORD='<scmadmin git 비밀번호>' ./deploy-cicd-portal.sh console-image console
```

| 단계 | 내용 |
| --- | --- |
| `console-image` | 콘솔 + 포털 스크립트·템플릿 + 관리 노드의 `kubectl`로 이미지를 만들어 Harbor `cicd-portal/cicd-console:<태그>`에 push (`sudo podman`) |
| `console` | Keycloak 클라이언트 `cicd-console`(groups 매퍼), namespace `cicd-console`, Secret·ConfigMap, Deployment·Service·Ingress, ServiceAccount 권한 |

- `SCM_ADMIN_PASSWORD`: `scm` 업체를 콘솔에서 등록·앱 추가하려면 필요하다(Secret `cicd-console-secrets`에 저장, 다음 실행부터 생략 가능).
- 폐쇄망: `cicd-vars.sh`의 `CONSOLE_BASE_IMAGE`(Harbor 미러), `CONSOLE_APT_MIRROR`, `CONSOLE_PIP_INDEX_URL`을 지정한다.
- 코드 변경 시 `CONSOLE_IMAGE_TAG`를 올리고 두 단계를 다시 실행한다. `cicd-vars.sh`만 바꾼 경우 `console` 단계만 실행하면 된다(ConfigMap).
- 점검: `./check-cicd-portal.sh`가 콘솔이 설치되어 있으면 Pod·`/healthz`·Keycloak 클라이언트도 확인한다.
- 삭제: `./uninstall-cicd-portal.sh console` (업체·앱·데이터는 유지). `all`에도 포함된다.

## 3. 권한

K-PaaS SSO(Keycloak `cp-realm`)로 로그인하며 권한은 Jenkins·Argo CD와 같은 Keycloak 그룹을 쓴다.

| 기능 | `cicd-admins` (운영 관리자) | `cicd-<업체>` (업체 구성원) |
| --- | --- | --- |
| 대시보드 · 앱 · 빌드 로그 조회 | 전체 업체 | 자기 업체 |
| develop 빌드 실행 · 중지, dev Sync | O | O |
| 릴리스 빌드 (scm: `RELEASE_TAG`) | O | O (Jenkins 폴더 권한과 동일) |
| 릴리스 태그 생성 (gitlab) | O | X — PM이 GitLab에서 태그 생성 (보호 태그 v*) |
| prod Sync · 롤백 | O | X |
| 업체 등록 · 앱 추가 · DB 연결 · 구성원 관리 · 시스템 점검 | O | X |

그룹을 바꾼 뒤에는 콘솔에서 로그아웃 후 다시 로그인한다. 콘솔은 Jenkins API 토큰(`jenkins-token` 단계)과 GitLab automation 토큰으로
API를 호출하므로 Jenkins·GitLab 기록상 실행자는 토큰 소유자로 남는다. 실제 실행자는 콘솔 로그에 남는다:
`kubectl -n cicd-console logs deploy/cicd-console | grep audit`.

## 4. 화면

- **대시보드**: 업체 수, 앱 수, dev 정상, prod 배포 대기(변경 있음), 오류 환경. 업체별 앱의 dev/prod 상태와 이미지 태그.
- **업체**: 애플리케이션 카드(최근 빌드, dev, prod) · 구성원 · 업체 정보(네임스페이스, Harbor, gitops 저장소, 리소스 쿼터 사용량).
- **앱**: 파이프라인 5단계, 빌드 이력(로그·중지), dev/prod 환경(이미지, 접속 주소, 리소스, 배포 이력, 롤백).
  빌드나 Sync가 진행 중이면 15초마다 새로 고친다.
- **업체 등록 / 앱 추가 / DB 연결**: 각 스크립트의 옵션을 폼으로 입력한다. 실행 로그는 **작업 이력**에서 실시간으로 본다.
  스크립트는 한 번에 하나씩 실행되고, 종료 코드 3(업체 등록의 SCM 할 일 남음)은 "수동 대기"로 표시된다.
  입력한 비밀번호(SCM CI, 외부 DB)는 로그에서 `****`로 가려지고 작업이 끝나면 메모리에서 지워진다.

### 롤백

prod 배포 이력의 **롤백**은 해당 gitops 리비전으로 Argo CD Sync한다. 이후 앱은 gitops `main`과 달라 "변경 있음"으로 표시되며,
다음 prod Sync 때 `main`으로 돌아간다. 롤백을 유지하려면 gitops 저장소의 `apps/<앱>/overlays/prod` 이미지 태그를 되돌린다.
dev는 자동 Sync라 롤백 버튼이 없다.

## 5. 구성

```text
브라우저 ─ Ingress cicd.<도메인> ─ cicd-console (gunicorn 1 프로세스, Flask)
                                    ├─ Keycloak (OIDC 로그인, 구성원 관리)
                                    ├─ Jenkins / GitLab / SCM-Manager API (외부 주소, K-PaaS CA)
                                    ├─ kubectl (ServiceAccount cicd-console): Argo CD Application/AppProject, Secret
                                    └─ /opt/cicd/script/*.sh (업체 등록·앱 추가·DB 연결)
```

- 설정은 스크립트와 같은 `lib.sh` `load_portal_vars`로 계산한다. `cp-portal-vars.sh` 값(도메인, Keycloak·Harbor 관리자,
  MariaDB)은 Secret `cicd-console-secrets`로, `cicd-vars.sh`는 ConfigMap `cicd-console-vars`로 넣는다.
- ServiceAccount 권한(ClusterRole `cicd-console`)은 관리 노드에서 스크립트가 쓰는 범위와 같다: namespace·Secret·ResourceQuota·
  LimitRange·PVC 생성/수정, Argo CD AppProject·Application, `mariadb` namespace의 `pods/exec`(공용 DB 모드).
  **Secret을 클러스터 전체에서 읽을 수 있으므로** 콘솔 이미지·namespace 접근은 운영 관리자로 제한한다.
- API 주소는 기본으로 `https://jenkins|gitlab|scm-manager.<도메인>`(Ingress 경유)이다. K-PaaS 기본 NetworkPolicy가 다른
  namespace에서 `cicd-jenkins`로의 직접 접근을 막기 때문이다. GitLab(`cp-role: shared`)과 SCM(정책 제외)은
  `CONSOLE_GITLAB_API_URL`, `CONSOLE_SCM_API_URL`로 내부 주소를 쓸 수 있다.
- 작업 이력은 메모리에 있어 Pod 재시작 시 지워진다(최근 50개). 스크립트는 재실행해도 안전하다.

## 6. 개발 · 테스트

```bash
cd cicd-portal-deployment/console
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python -m unittest discover -s tests -v      # 가짜 백엔드로 화면·권한·스크립트 실행 검증 (클러스터 불필요)
```

## 7. 문제 해결

| 증상 | 확인 |
| --- | --- |
| 로그인 후 "ID 토큰 검증 실패" | Pod 시간, `KEYCLOAK_URL`(`cp-portal-vars.sh`)이 브라우저 주소와 같은지 |
| "접근할 수 있는 업체가 없습니다" | Keycloak 그룹 `cicd-<업체>`/`cicd-admins` 소속, 로그아웃 후 재로그인 |
| 빌드 조회 실패 (Jenkins) | `./deploy-cicd-portal.sh jenkins-token` 토큰 등록, Pod에서 `jenkins.<도메인>` DNS/인증서 |
| 업체 등록이 SCM 단계에서 실패 | `SCM_ADMIN_PASSWORD` 재지정: `SCM_ADMIN_PASSWORD=... ./deploy-cicd-portal.sh console` |
| 이미지 pull 실패 | 노드의 Harbor CA 신뢰, `cicd-console-pull` Secret (`console` 단계 재실행 시 robot 재발급) |
