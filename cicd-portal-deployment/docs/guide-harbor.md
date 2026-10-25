# Harbor 적용 가이드 (이미지 저장소)

CI/CD 포털에서 Harbor는 **빌드된 컨테이너 이미지를 보관하고 쿠버네티스에 내려 주는 곳**이다.
Harbor는 K-PaaS(CP-Portal) 설치 때 이미 있으며, 포털은 업체별 프로젝트와 robot 계정만 추가한다.

| 솔루션 가이드 | |
| --- | --- |
| [소스 저장소 (SCM / GitLab)](guide-scm-gitlab.md) | |
| **Harbor (이 문서)** | |
| [Jenkins](guide-jenkins.md) / [Argo CD](guide-argocd.md) | |
| [설치·관리 전체 가이드](install-guide.md) | |

---

## 1. 역할과 흐름

```text
Jenkins 빌드 Pod (kaniko)  ──push (robot$<업체>+cicd)──▶  Harbor  harbor.<도메인>/<업체>/<앱>:<태그>
                                                              │
<업체>-dev / <업체>-prod 의 Pod  ◀──pull (Secret harbor-cicd)──┘
```

| 태그 | 만드는 잡 | 예 |
| --- | --- | --- |
| `dev-<커밋8자리>-<빌드번호>` | Jenkins `<앱>-dev` (develop) | `dev-e8ad2d85-4` |
| `vX.Y.Z` | Jenkins `<앱>-release` (`RELEASE_TAG`) | `v1.0.0` |

## 2. 접속과 계정

| 항목 | 값 |
| --- | --- |
| 주소 | `https://harbor.<도메인>` (`cp-portal-vars.sh`의 `REPOSITORY_URL`) |
| 관리자 | `cp-portal-vars.sh`의 `REPOSITORY_USERNAME` / `REPOSITORY_PASSWORD` (스크립트가 자동 사용) |
| API | `https://harbor.<도메인>/api/v2.0` |
| 인증서 | K-PaaS 사설 CA. 빌드 Pod는 `/etc/cicd-ca/ca.crt`로 신뢰(kaniko `--registry-certificate`) |

## 3. 포털이 만드는 것

`onboard-vendor.sh <업체>`가 Harbor API로 만든다.

| 대상 | 내용 |
| --- | --- |
| 프로젝트 `<업체>` | **비공개**. 저장소 `<업체>/<앱>`은 첫 push 때 자동 생성 |
| robot 계정 `robot$<업체>+cicd` | 그 프로젝트만 **push·pull**, 만료 없음. 비밀값은 다시 읽을 수 없어 **재실행 시 삭제 후 재발급** |
| Jenkins credential `<업체>-harbor` | robot 계정 (빌드 Pod가 push에 사용) |
| Secret `harbor-cicd` | `<업체>-dev`, `<업체>-prod`에 생성 (Pod가 pull에 사용, Deployment의 `imagePullSecrets`) |
| (gitlab 업체) 그룹 CI 변수 | `HARBOR_USER`, `HARBOR_PASSWORD` |

robot을 재발급하면 위 세 곳이 함께 갱신된다. 그래서 robot 문제는 대부분 `./onboard-vendor.sh <업체>` 재실행으로 해결된다.

## 4. 관리자 작업 (화면)

| 작업 | 위치 |
| --- | --- |
| 업체 이미지 확인 | 프로젝트 → `<업체>` → 저장소 → `<업체>/<앱>` → 태그 목록 (푸시 시간, 크기, 취약점) |
| 이미지가 올라왔는지 | 프로젝트 목록의 **저장소 수** (0이면 아직 빌드 성공 전) |
| 풀(Pull) 수 | 저장소 목록의 풀 수 (0이면 클러스터가 아직 받지 않음) |
| robot 계정 | 프로젝트 → **로봇 계정** (`<업체>+cicd`) |
| 취약점 스캔 | 태그 선택 → **스캔** (기본 스캐너 Trivy). 프로젝트 → 설정 → "푸시 시 자동 스캔" 권장 |
| 보관 정책 | 프로젝트 → **정책** → 태그 보존: 예) `dev-*` 최근 20개, `v*` 전체 유지 |
| 용량 | 프로젝트 → 요약 → **사용된 할당량**, 관리 → **정리(GC)** 주기 설정 |

## 5. 베이스 이미지 미러 (폐쇄망·Docker Hub 제한 대비)

빌드는 기본적으로 Docker Hub에서 베이스 이미지(php, composer, node, nginx, mariadb 등)를 받는다.
Harbor 공개 프로젝트 `base-images`에 복사해 두면 외부 의존이 없어진다.

```bash
cd ~/Saeoll-PaaS/cp-pipeline-deployment/script
./mirror-base-images.sh php:8.3-apache-bookworm composer:2 node:20-alpine nginx:1.27-alpine mariadb:11.4 alpine:3.20
```
그다음 `cicd-portal-deployment/script/cicd-vars.sh`:
```bash
CICD_DOCKERHUB="harbor.<도메인>/base-images"        # 빌드 도구 이미지
CICD_BASE_REGISTRY="harbor.<도메인>/base-images"    # Dockerfile 의 BASE_REGISTRY
MARIADB_IMAGE="harbor.<도메인>/base-images/mariadb:11.4"
```
→ `./deploy-cicd-portal.sh jenkins`(필요 시) 후 각 앱 `REPLACE_CI=1 ./add-app.sh ...`로 Jenkinsfile 갱신.

> PHP는 `php:8.3-apache-bookworm`을 미러한다. trixie 기반 `php:8.3-apache`는 kaniko 빌드에서
> `xz: Failed to enable the sandbox`로 실패한다.

## 6. 점검 명령

```bash
H=https://harbor.<도메인>
# 프로젝트·저장소
curl -sk -u admin "$H/api/v2.0/projects?name=saeoll" | python3 -m json.tool | head -20
curl -sk -u admin "$H/api/v2.0/projects/saeoll/repositories" | python3 -m json.tool | grep -E '"name"|artifact_count'
# 태그 목록
curl -sk -u admin "$H/api/v2.0/projects/saeoll/repositories/php-service/artifacts?with_tag=true" | grep -o '"name":"[^"]*"' | head
# 클러스터 pull secret
kubectl -n saeoll-dev get secret harbor-cicd -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | python3 -m json.tool | grep -E 'harbor|username'
```

## 7. 문제 해결

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| Pod `ImagePullBackOff`, `...:none-yet not found` | 아직 이미지가 없음 (첫 빌드 전·실패) | Jenkins 빌드 성공시키기. Harbor 저장소 수 0 확인 |
| Pod `ImagePullBackOff`, `401 Unauthorized` / `pull access denied` | pull secret 문제 | `./onboard-vendor.sh <업체>` |
| 빌드 Image 단계 `UNAUTHORIZED` | robot 비밀값 불일치 | `./onboard-vendor.sh <업체>` |
| 빌드 `x509: certificate signed by unknown authority` | CA 미적용 | `kubectl -n cicd-jenkins get secret cicd-ca`, `./deploy-cicd-portal.sh jenkins` |
| onboard 시 robot `409 Conflict` | 같은 이름 robot을 찾지 못함(예전 스크립트) | `git pull` 후 재실행, 그래도 안 되면 Harbor 화면에서 robot 삭제 후 재실행 |
| 빌드 `manifest unknown` (베이스 이미지) | `CICD_BASE_REGISTRY`에 이미지 없음 | 5장 미러 |
| 디스크 부족 | 오래된 `dev-*` 태그 누적 | 4장 태그 보존 정책 + GC |
