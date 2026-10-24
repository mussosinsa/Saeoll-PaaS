# CI/CD 포털 업체 개발자 가이드

GitLab에 소스를 올리면 자동으로 빌드·테스트되고, 개발(dev) 환경에 배포된다. 운영(prod) 배포는 릴리스 태그를 만든 뒤
운영 관리자의 승인으로 반영된다.

```text
feature 브랜치 ─ MR ─▶ develop ──(자동)──▶ 빌드·테스트·이미지 ──▶ dev 자동 배포
                         │
                         └─ MR ─▶ main ─ 태그 vX.Y.Z (PM) ──▶ 빌드·이미지 ──▶ 운영 관리자 승인 ──▶ prod 배포
```

| 항목 | 주소 (`<도메인>`, `<업체>`, `<앱>`은 운영 관리자 안내값) |
| --- | --- |
| GitLab (소스·파이프라인) | `https://gitlab.<도메인>` |
| Argo CD (배포 상태·로그) | `https://argocd.<도메인>` |
| 개발 서비스 | `https://<앱>-<업체>-dev.<도메인>` |
| 운영 서비스 | `https://<앱>-<업체>.<도메인>` |

## 1. 시작하기

### 1-1. 받는 것

운영 관리자에게서 다음을 받는다.

- 계정 ID(예: `saeoll-hong`)와 임시 비밀번호
- K-PaaS 인증서 파일 `ca.crt`
- 담당 서비스 목록(`<업체>/<앱>`)

### 1-2. 첫 로그인

1. `https://gitlab.<도메인>` 접속 → **K-PaaS SSO** 클릭 → ID/임시 비밀번호 입력 → 새 비밀번호 설정
2. 로그인되면 운영 관리자에게 **"GitLab 첫 로그인 완료"**를 알린다(그 후 업체 그룹 권한이 부여됨).
3. 권한 부여 후 GitLab 첫 화면 또는 **Groups**에서 `<업체>` 그룹과 프로젝트가 보이는지 확인한다.
4. `https://argocd.<도메인>` → **LOG IN VIA K-PAAS SSO** → 같은 계정으로 로그인 → 업체 앱이 보이는지 확인한다.

이 한 계정(K-PaaS SSO)으로 GitLab·Argo CD를 모두 쓴다. 비밀번호 변경은 Keycloak 계정 화면
(`https://keycloak.<도메인>/realms/cp-realm/account`)에서 한다.

## 2. PC 준비

### 2-1. 인증서 신뢰 설정

사설 인증서라 설정하지 않으면 git이 `SSL certificate problem`으로 실패한다.

```bash
# 받은 ca.crt 를 홈 디렉터리에 두고 (Windows Git Bash: C:/Users/<사용자>/kpaas-ca.crt)
git config --global http.https://gitlab.<도메인>/.sslCAInfo ~/kpaas-ca.crt
```

브라우저 경고("주의 요함")를 없애려면 `ca.crt`를 운영체제의 **신뢰할 수 있는 루트 인증 기관**에 등록한다
(Windows: 파일 더블클릭 → 인증서 설치 → 로컬 컴퓨터 → 신뢰할 수 있는 루트 인증 기관).

### 2-2. git 접속용 토큰 발급

SSO 계정에는 git 비밀번호가 없으므로 **Personal Access Token**을 비밀번호로 쓴다.

1. GitLab 우측 상단 프로필 → **Edit profile** → **Access tokens** → **Add new token**
2. 이름 `git-pc`, 만료일(최대 1년), Scopes: **`read_repository`, `write_repository`** → **Create**
3. 표시된 토큰(`glpat-...`)을 복사해 안전하게 보관(다시 볼 수 없음)

```bash
git config --global user.name "홍길동"
git config --global user.email "hong@vendor.co.kr"
git config --global credential.helper store      # 처음 한 번 입력한 토큰을 저장 (공용 PC에서는 사용 금지)
git clone https://gitlab.<도메인>/<업체>/<앱>.git
# Username: 계정 ID   Password: glpat-... 토큰
cd <앱> && git checkout develop
```

SSH 접속은 제공하지 않는다(HTTPS만 사용).

## 3. 저장소 규칙

처음 생성된 저장소에는 시작용 파일이 들어 있다. 다음 파일·규칙은 **반드시 유지**한다.

| 파일·규칙 | 내용 |
| --- | --- |
| `.gitlab-ci.yml` | 파이프라인 정의(공통 템플릿 include). 삭제·변경 금지, 아래 3-2의 변수만 추가 가능 |
| `Dockerfile` | 컨테이너 이미지 정의. **8080 포트**로 서비스 |
| 헬스 체크 | `GET /healthz` 가 200 응답 (PHP는 `/healthz.php`). 실패하면 배포가 완료되지 않음 |
| 베이스 이미지 | `FROM ${BASE_REGISTRY}/<이미지>` 형식 유지. 운영 관리자가 등록한 이미지만 사용 |
| 비밀정보 | 비밀번호·키·토큰을 소스에 커밋하지 않음(필요한 값은 운영 관리자에게 요청) |
| 브랜치 | `main`(운영 기준, PM만 머지), `develop`(개발 통합, 자동 dev 배포), `feature/<작업명>`(개발) |

### 3-1. 언어별 기본 빌드

| 유형 | 빌드 | 테스트 | 실행 이미지 |
| --- | --- | --- | --- |
| Java / Gradle | `./gradlew assemble` (없으면 `gradle`) | `./gradlew check` | eclipse-temurin 17 JRE |
| Java / Maven | `./mvnw -DskipTests package` (없으면 `mvn`) | `./mvnw verify` | eclipse-temurin 17 JRE |
| PHP | `composer install`, 전체 `php -l` | `vendor/bin/phpunit`(설치 시) | php 8.3 + Apache |
| Node.js | `npm ci`, `npm run build`(있으면) | `npm run lint`, `npm test`(있으면) | node 20 |
| Vue | `npm ci`, `npm run build` | `npm run lint`, `npm run test:unit`(있으면) | nginx (dist 정적 파일) |

### 3-2. 조정 가능한 변수

`.gitlab-ci.yml`에 `variables:`를 추가해 조정한다.

```yaml
include:
  - project: cicd/ci-templates
    ref: main
    file: /templates/java-gradle.yml

variables:
  JAVA_BUILD_IMAGE: $CICD_DOCKERHUB/gradle:8.10-jdk21   # 빌드 이미지 (운영 관리자 등록 이미지)
  DOCKERFILE: docker/Dockerfile                          # Dockerfile 위치
  DOCKER_CONTEXT: .                                      # 빌드 컨텍스트
```

| 변수 | 유형 |
| --- | --- |
| `JAVA_BUILD_IMAGE` | java-gradle, java-maven |
| `PHP_BUILD_IMAGE` | php |
| `NODE_BUILD_IMAGE` | node, vue |
| `DOCKERFILE`, `DOCKER_CONTEXT` | 공통 |

JDK·PHP·Node 버전을 바꾸려면 Dockerfile의 실행 이미지도 함께 바꾸고, 새 이미지가 필요하면 운영 관리자에게 등록을 요청한다.

## 4. 개발 흐름

```bash
git checkout develop && git pull
git checkout -b feature/login-page
# ... 개발, 로컬 테스트 ...
git add . && git commit -m "로그인 화면 추가"
git push -u origin feature/login-page
```

1. GitLab에서 **Merge request** 생성: `feature/login-page` → `develop`
2. MR 화면에서 파이프라인(build, test) 성공 확인 → 리뷰 → **Merge**
3. `develop` 머지 즉시 파이프라인이 실행되어 dev에 자동 배포된다(약 3~10분).
4. `https://<앱>-<업체>-dev.<도메인>`에서 확인한다.

혼자 작업하는 경우 `develop`에 직접 push해도 된다(같은 배포가 실행됨).

## 5. 파이프라인 확인

GitLab 프로젝트 → **Build › Pipelines**

| 잡 | 실행 조건 | 내용 |
| --- | --- | --- |
| `build` | 모든 브랜치·MR | 컴파일·패키징 |
| `test` | 모든 브랜치·MR | 테스트(결과는 MR의 **Tests** 탭) |
| `image` | `develop`, 태그 `vX.Y.Z` | 이미지 빌드 → `harbor.<도메인>/<업체>/<앱>:<태그>` |
| `deploy` | `develop`, 태그 `vX.Y.Z` | 배포 정보(gitops) 갱신 → Argo CD가 반영 |

이미지 태그: develop은 `dev-<커밋8자리>-<번호>`, 릴리스는 `vX.Y.Z`. 배포 이력은 **Operate › Environments**(dev/prod)에서 볼 수 있다.

### 실패 시

| 실패 잡 | 흔한 원인 | 조치 |
| --- | --- | --- |
| `build` / `test` | 컴파일 오류, 테스트 실패, 의존성 다운로드 실패 | 잡 로그 확인 → 수정 후 다시 push. 네트워크 오류는 **Retry** |
| `image` | Dockerfile 오류, 등록되지 않은 베이스 이미지(`manifest unknown`) | Dockerfile 수정, 이미지 등록 요청 |
| `deploy` | 배포 정보 미생성(`overlays/... not found`) | 운영 관리자에게 문의 |
| 파이프라인이 `pending` | 빌드 서버 대기·장애 | 10분 이상 지속 시 운영 관리자에게 문의 |

## 6. 배포 상태·로그 확인 (Argo CD)

`https://argocd.<도메인>` → 앱 `<업체>-<앱>-dev`

| 상태 | 의미 |
| --- | --- |
| `Synced` / `Healthy` | 배포 완료, 정상 |
| `Progressing` | 배포 중(새 Pod 기동 대기) |
| `Degraded` | Pod가 정상 기동하지 못함 → Pod 로그 확인 |
| `OutOfSync` (prod) | 새 릴리스가 승인 대기 중 |

로그 보기: 앱 화면 → Deployment 아래 Pod 클릭 → **LOGS**. dev 앱은 **SYNC** 버튼으로 다시 반영할 수 있다(운영 앱은 불가).

`Degraded`의 흔한 원인: 8080 포트가 아님, 헬스 체크 경로 응답 없음, 메모리 부족(기본 상한 512Mi), 설정값 누락.

## 7. 운영 배포 (PM)

1. dev 검증 완료 후 GitLab에서 **Merge request** `develop` → `main` 생성·머지
2. 릴리스 태그 생성 (Maintainer만 가능)
   - GitLab 프로젝트 → **Code › Tags** → **New tag** → 이름 `v1.0.0`, Create from `main`, 메시지 입력
   - 또는 `git checkout main && git pull && git tag -a v1.0.0 -m "v1.0.0 최초 오픈" && git push origin v1.0.0`
3. 태그 파이프라인 성공 확인(**Build › Pipelines**)
4. 운영 관리자에게 운영 배포 요청:

```text
[운영 배포 요청]
업체/서비스   : saeoll / homepage
릴리스 태그   : v1.0.0  (파이프라인 #123 성공)
변경 내용     : 로그인 화면 추가, 공지사항 목록 페이징 수정
dev 검증 결과 : 2026-10-24 기능 테스트 완료 (담당: 홍길동)
배포 희망 일시 : 2026-10-25 10:00
롤백 버전     : v0.9.3
```

5. 승인·반영 후 `https://<앱>-<업체>.<도메인>`에서 확인한다.

태그 이름은 `v<주>.<부>.<수정>` 형식만 배포된다(예: `v1.2.0`, `v1.2.1`). 같은 태그를 다시 쓰지 않는다.

## 8. 롤백

| 환경 | 방법 |
| --- | --- |
| dev | GitLab **Build › Pipelines**에서 정상이던 이전 파이프라인의 `deploy` 잡 **Retry**(이전 이미지로 되돌림) |
| prod | 운영 관리자에게 롤백 요청(대상 태그 명시, 예: "v1.0.0 → v0.9.3"). 수정 배포는 새 태그(`v1.0.1`)로 진행 |

## 9. 문제 해결

| 증상 | 조치 |
| --- | --- |
| GitLab 로그인 "Email can't be blank" | 운영 관리자에게 계정 이메일 등록 요청 |
| GitLab에 프로젝트가 안 보임 | 첫 로그인 완료를 운영 관리자에게 알렸는지 확인(권한 부여 필요) |
| `git clone` 시 `SSL certificate problem` | 2-1 인증서 설정 |
| `git clone` 시 `HTTP Basic: Access denied` | 비밀번호 대신 Access Token(2-2) 사용, 토큰 만료 여부 확인 |
| `main`에 push 거부 | 정상. `main`은 MR로만 반영(PM 머지) |
| 태그 생성 거부 | Maintainer(PM)만 가능 |
| Argo CD에 앱이 안 보임 | 로그아웃 후 다시 로그인(권한 갱신), 그래도 없으면 운영 관리자 문의 |
| dev 주소 접속 시 404 / 503 | Argo CD 앱 상태 확인(6장). 첫 배포 직후라면 수 분 대기 |

## 10. 지켜야 할 사항

- 계정·토큰은 개인별로 사용하고 공유하지 않는다. 퇴사·투입 종료 시 즉시 운영 관리자에게 알린다.
- 비밀번호·인증키·개인정보를 소스나 이슈·MR 설명에 올리지 않는다.
- 운영 데이터베이스·서버에 직접 접속해 변경하지 않는다. 모든 반영은 파이프라인과 배포 승인으로 한다.
- 외부 라이브러리 추가 시 라이선스와 보안 취약점을 확인한다.
