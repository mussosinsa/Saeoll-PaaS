# PHP 유지보수 업체별 소스 관리·배포 가이드

K-PaaS 컨테이너 플랫폼(CP-Portal, CP-Pipeline)에서 PHP 프로젝트를 유지보수 업체별로
분리하여 관리하고, Jenkins 파이프라인으로 테스트·배포하는 절차를 정리한다.

| 단계 | 내용 | 주 수행자 |
| --- | --- | --- |
| 1 | 신규 PHP 소스코드 등록 (업체 온보딩, SCM 사용자 계정, 저장소) | 운영 관리자 → 업체 |
| 2 | 파이프라인을 통한 개발 배포 (소스 수정, 테스트) | 업체 개발자 |
| 3 | 파이프라인을 통한 서비스(운영) 배포 | 업체 요청 → 운영 관리자 승인 |

---

## 0. 기본 구조

### 0-1. 역할

| 역할 | 설명 |
| --- | --- |
| 운영 관리자 | 플랫폼 운영 기관 담당자. 업체 온보딩, Jenkins job 생성, 운영 배포 승인·실행 |
| 업체 PM | 업체 책임자. 개발자 계정 신청, 릴리스 태그 생성, 운영 배포 요청 |
| 업체 개발자 | 소스 수정, 로컬 테스트, `develop` 브랜치 push, 개발 환경 확인 |

### 0-2. 업체별 격리 단위와 명명 규칙

업체 ID는 영문 소문자·숫자·`-`로 정한다(예: `vendor-a`). 애플리케이션 이름은 `APP`로 표기한다.

| 자원 | 이름 | 격리 방식 |
| --- | --- | --- |
| SCM 저장소 | `<vendor>-<app>` (예: `vendor-a-homepage`) | 저장소별 기여자 권한(쓰기/보기) |
| SCM 계정 | 개인 계정, Jenkins용 `jenkins-<vendor>` | 업체 저장소에만 권한 부여 |
| Harbor 프로젝트 | `<vendor>` (private) | 업체 전용 robot 계정 `robot$<vendor>+ci` |
| Kubernetes namespace | `<vendor>-dev`, `<vendor>-prod` | 전용 ServiceAccount(`deployer`, namespace 한정 `edit`), ResourceQuota |
| Jenkins | 폴더 `<vendor>`, job `<app>-dev`, `<app>-prod` | 폴더 범위 credential |
| 서비스 URL | 개발 `https://<app>-<vendor>-dev.<HOST_DOMAIN>`<br>운영 `https://<app>-<vendor>.<HOST_DOMAIN>` | 포털 와일드카드 인증서(`*.<HOST_DOMAIN>`) 사용 |

### 0-3. 브랜치 전략

```text
feature/<작업명> ──merge──▶ develop ──(자동)──▶ Jenkins <app>-dev ──▶ <vendor>-dev
                               │
                               └─merge─▶ main ──tag vX.Y.Z──▶ Jenkins <app>-prod(승인) ──▶ <vendor>-prod
```

- `develop`: 개발 환경 자동 배포 대상
- `main`: 운영 반영 대상 소스. 태그(`vMAJOR.MINOR.PATCH`)가 붙은 커밋만 운영 배포
- 운영 이미지 태그는 릴리스 태그와 같다(`harbor.<HOST_DOMAIN>/<vendor>/<app>:v1.2.0`)

### 0-4. 사전 조건 (운영 관리자, 1회)

1. CP-Portal, CP-Pipeline 배포 완료
2. PHP 지원 Jenkins 이미지 적용: `cp-pipeline-deployment/script/build-jenkins-php-image.sh`
   (README "PHP 지원 Jenkins 이미지 빌드" 참고)
3. SCM 준비: K-PaaS 소스컨트롤(`https://scm.<HOST_DOMAIN>`) 또는 사내 Git 서버.
   **본 저장소에는 SCM 배포 스크립트가 포함되어 있지 않으므로** 별도로 설치되어 있어야 한다.
4. Jenkins 접속: Ingress가 없으므로 운영 관리자 PC에서 port-forward로 접속한다.
   ```bash
   kubectl -n cp-pipeline port-forward svc/cp-pipeline-jenkins-service 8080:8080
   # http://127.0.0.1:8080
   ```

---

## 1. 신규 PHP 소스코드 등록 — SCM 사용자 계정

### 1-1. 업체 온보딩 (운영 관리자)

업체 등록 신청을 받으면 다음 스크립트로 업체 전용 자원을 만든다.

```bash
cd ~/Saeoll-PaaS/cp-pipeline-deployment/script
./onboard-php-vendor.sh vendor-a
```

생성 결과:

| 자원 | 내용 |
| --- | --- |
| Harbor | private 프로젝트 `vendor-a`, push/pull 전용 robot 계정 |
| namespace | `vendor-a-dev`, `vendor-a-prod` (ResourceQuota: CPU 4, 메모리 8Gi, Pod 30 기본값) |
| namespace 내부 | Harbor pull secret `harbor-regcred`, TLS secret, ServiceAccount `deployer`(해당 namespace `edit`만) |
| 파일 | `cp-pipeline-deployment/vendors/vendor-a/` 아래 robot 계정, kubeconfig(dev/prod), credential 목록 (권한 600) |

쿼터를 바꾸려면 `QUOTA_CPU=8 QUOTA_MEMORY=16Gi QUOTA_PODS=50 ./onboard-php-vendor.sh vendor-a`로 실행한다.
`vendors/` 디렉터리는 Git에 올리지 않으며, Jenkins 등록 후 안전한 곳에 보관하거나 삭제한다.

### 1-2. SCM 사용자 계정

| 계정 | 생성·관리 | 권한 |
| --- | --- | --- |
| 업체 개발자 개인 계정 | 개발자가 SCM에 가입(또는 운영 관리자가 생성) → 운영 관리자가 "사용자 관리"에서 확인 | 업체 저장소 **쓰기 권한** |
| 업체 PM 계정 | 동일 | 업체 저장소 **쓰기 권한** (릴리스 태그 생성) |
| Jenkins용 계정 `jenkins-<vendor>` | 운영 관리자 생성 | 업체 저장소 **보기 권한** (읽기 전용) |
| 운영 관리자 | 기존 관리자 계정 | 전체 |

운영 원칙:
- 계정은 개인별로 발급하고 공용 계정은 사용하지 않는다(Jenkins 계정 제외).
- 계정 신청은 업체 PM이 성명, 소속, 이메일, 대상 저장소를 기재하여 요청한다.
- 업체 계약 종료·인원 교체 시 "사용자 관리"에서 즉시 삭제한다(6장 참고).

### 1-3. 저장소 생성과 권한 부여 (운영 관리자)

K-PaaS 소스컨트롤 기준:

1. "레파지토리" → 저장소 이름 `vendor-a-homepage`, 유형 **Git** → "생성"
2. 저장소 상세 → 기여자 관리
   - 업체 개발자·PM 계정: **쓰기 권한**
   - `jenkins-vendor-a`: **보기 권한**
3. "레파지토리 클론"에서 클론 URL을 복사해 업체에 전달한다.

사내 Git(GitLab 등)을 쓰는 경우 업체별 그룹을 만들고 동일한 권한 구조를 적용한다.
가능하면 `main` 브랜치는 보호(직접 push 금지, merge만 허용)한다.

### 1-4. 최초 소스 등록 (업체 개발자)

저장소 루트는 다음 구조를 따른다. `cp-pipeline-deployment/php-sample/`을 복사해 시작한다.

```text
<repo>/
├── Jenkinsfile        # 파이프라인 정의 (수정 시 운영 관리자 협의)
├── Dockerfile         # PHP 8.3 + Apache, 8080 포트, DocumentRoot=public/
├── .dockerignore
├── composer.json      # (composer.lock 커밋 권장)
├── k8s/app.yaml       # Deployment / Service / Ingress 템플릿
├── public/            # 웹 루트 (index.php, healthz.php 필수)
├── src/               # 애플리케이션 코드
└── tests/             # PHPUnit 테스트 (권장)
```

```bash
git clone <클론 URL> vendor-a-homepage
cd vendor-a-homepage
cp -r ~/Saeoll-PaaS/cp-pipeline-deployment/php-sample/. .
# 기존 PHP 소스를 public/, src/ 등에 배치
git add -A
git commit -m "Initial import"
git push origin HEAD:main
git push origin HEAD:develop
```

- `public/healthz.php`는 파이프라인 헬스체크(readiness/liveness, 배포 후 smoke test)에 사용하므로 삭제하지 않는다.
- DB 접속 정보, API 키 등 비밀 값은 저장소에 커밋하지 않는다. Kubernetes Secret으로 등록하도록 운영 관리자에게 요청한다.
- 기존 소스의 DocumentRoot가 `public/`이 아니면 Dockerfile의 경로를 조정한다.

### 1-5. Jenkins 폴더·credential 등록 (운영 관리자)

1. Jenkins → New Item → **Folder** `vendor-a`
2. `vendor-a` 폴더 → Credentials → (폴더 범위) Add Credentials

| ID | 종류 | 값 |
| --- | --- | --- |
| `vendor-a-harbor-robot` | Username with password | `harbor-robot.env`의 `HARBOR_ROBOT_USER` / `HARBOR_ROBOT_SECRET` |
| `vendor-a-kubeconfig-dev` | Secret file | `kubeconfig-dev` |
| `vendor-a-kubeconfig-prod` | Secret file | `kubeconfig-prod` |
| `vendor-a-scm` | Username with password | `jenkins-vendor-a` 계정 |

credential은 반드시 **업체 폴더 범위**로 등록한다. 전역(Global)에 등록하면 다른 업체 job에서도 사용할 수 있게 된다.

> Folder 기능은 Jenkins "Folders" 플러그인이 필요하다. 설치되어 있지 않으면 job 이름을
> `vendor-a-homepage-dev`처럼 업체 접두어로 구분하고 credential ID로 격리한다.

---

## 2. 파이프라인을 통한 배포 — 소스코드 수정, 테스트 (개발 환경)

### 2-1. 개발 job 생성 (운영 관리자, 앱당 1회)

`vendor-a` 폴더 → New Item → **Pipeline** `homepage-dev`

| 항목 | 값 |
| --- | --- |
| This project is parameterized | 사용 (Jenkinsfile의 parameters가 첫 실행 후 자동 등록됨) |
| Build Triggers | Poll SCM `H/5 * * * *` (SCM webhook을 쓸 수 있으면 webhook) |
| Pipeline | Pipeline script from SCM → Git |
| Repository URL / Credentials | 클론 URL / `vendor-a-scm` |
| Branch Specifier | `*/develop` |
| Script Path | `Jenkinsfile` |

첫 실행은 "Build with Parameters"로 수행하며 다음 값을 기본값으로 저장한다.

| 파라미터 | 값 |
| --- | --- |
| `DEPLOY_ENV` | `dev` |
| `VENDOR` | `vendor-a` |
| `APP_NAME` | `homepage` |
| `BASE_DOMAIN` | `192.168.40.216.nip.io` |

> 저장소의 Jenkinsfile 기본값(`VENDOR`, `APP_NAME`)을 업체·앱에 맞게 수정해 두면 SCM 폴링으로
> 시작되는 자동 빌드에도 올바른 값이 적용된다.

### 2-2. 개발자 작업 흐름

```bash
git checkout develop && git pull
git checkout -b feature/login-fix
# 소스 수정
```

**로컬 테스트** (PHP/Composer 미설치 PC도 Docker 또는 Podman으로 실행 가능):

```bash
# 문법 검사
docker run --rm -v "$PWD":/app -w /app docker.io/library/composer:2 \
  sh -c 'composer install && find . -path ./vendor -prune -o -name "*.php" -print0 | xargs -0 -n1 php -l'

# 단위 테스트 (tests/ 와 phpunit이 있는 경우)
docker run --rm -v "$PWD":/app -w /app docker.io/library/composer:2 vendor/bin/phpunit

# 실행 확인 → http://localhost:8080
docker build -t homepage:local . && docker run --rm -p 8080:8080 homepage:local
```

**개발 환경 반영**:

```bash
git add -A && git commit -m "로그인 오류 수정"
git checkout develop && git merge --no-ff feature/login-fix
git push origin develop
```

`develop`에 push하면 5분 이내에 `vendor-a/homepage-dev` job이 자동 실행된다.

### 2-3. 파이프라인 단계

| 단계 | 수행 내용 | 실패 시 확인 |
| --- | --- | --- |
| Prepare | 앱 이름 검증, 이미지 태그 결정(`dev-<커밋8자리>-<빌드번호>`) | 파라미터 값 |
| Composer install | `composer validate`, `composer install` | composer.json 문법, 패키지 저장소(packagist) 접근 |
| Lint & Test | 모든 `.php` 파일 `php -l`, PHPUnit(있으면) 실행 및 결과 리포트 | 콘솔 로그의 오류 파일·행 번호, Test Result |
| Build image | `buildah bud`로 Dockerfile 빌드 | Dockerfile, 베이스 이미지 pull |
| Push to Harbor | `harbor.<도메인>/vendor-a/homepage:<태그>` push | robot credential |
| Deploy | `k8s/app.yaml` 적용, rollout 대기. 실패 시 이전 버전 자동 rollback | `kubectl -n vendor-a-dev describe pod`, 이벤트 |
| Smoke test | `https://<app>-<vendor>-dev.<도메인>/healthz.php` 200 확인 | healthz.php, Ingress |

### 2-4. 개발 환경 확인

- URL: `https://homepage-vendor-a-dev.192.168.40.216.nip.io`
- 빌드 결과 전달: 업체가 Jenkins에 직접 접속하지 않는 경우 운영 관리자가 콘솔 로그를 전달하거나,
  Jenkins에 알림(메일 등)을 설정한다.
- 업체가 포털 계정으로 `vendor-a-dev` namespace의 Pod·로그를 조회해야 하면 운영 관리자가
  CP-Portal에서 해당 사용자에게 `vendor-a-dev` namespace 권한을 부여한다(운영 namespace는 부여하지 않는다).

---

## 3. 파이프라인을 통한 서비스 배포 (운영 환경)

### 3-1. 릴리스 준비 (업체 PM)

1. 개발 환경 검증 완료 확인
2. `develop` → `main` merge, 릴리스 태그 생성

   ```bash
   git checkout main && git pull
   git merge --no-ff develop
   git tag -a v1.2.0 -m "v1.2.0: 로그인 오류 수정"
   git push origin main --follow-tags
   ```

3. 운영 배포 요청서를 운영 관리자에게 제출

   ```text
   [운영 배포 요청]
   업체 / 애플리케이션 : vendor-a / homepage
   릴리스 태그          : v1.2.0
   변경 내용            : 로그인 오류 수정 (이슈 #123)
   개발 환경 검증       : 완료 (검증자, 일시)
   DB/설정 변경         : 없음
   희망 배포 일시       : 2026-10-01 18:00
   롤백 기준 버전       : v1.1.3
   ```

### 3-2. 운영 job 생성 (운영 관리자, 앱당 1회)

`vendor-a` 폴더 → New Item → **Pipeline** `homepage-prod`

| 항목 | 값 |
| --- | --- |
| This project is parameterized | String Parameter `RELEASE_TAG` (기본값 없음) |
| Build Triggers | 없음 (수동 실행만) |
| Pipeline | Pipeline script from SCM → Git, Credentials `vendor-a-scm` |
| Branch Specifier | `refs/tags/${RELEASE_TAG}` |
| Lightweight checkout | **해제** (파라미터가 있는 브랜치 지정에 필요) |
| Script Path | `Jenkinsfile` |

첫 실행 시 `DEPLOY_ENV=prod`, `VENDOR`, `APP_NAME`, `BASE_DOMAIN`, `APPROVERS`(승인자 Jenkins 계정/그룹)를
설정한다. 운영 job의 실행(Build) 권한은 운영 관리자에게만 부여한다.

### 3-3. 운영 배포 실행 (운영 관리자)

1. `vendor-a/homepage-prod` → Build with Parameters → `RELEASE_TAG=v1.2.0`, `DEPLOY_ENV=prod`
2. 파이프라인 검증 사항
   - 체크아웃한 커밋이 해당 태그인지 확인(태그가 아니면 중단)
   - 테스트를 다시 수행하고 이미지 `harbor.<도메인>/vendor-a/homepage:v1.2.0` 생성
3. **Approval** 단계에서 변경 내용·이미지 확인 후 "Deploy" 클릭(1시간 내 미승인 시 자동 중단)
4. 운영 namespace `vendor-a-prod`에 Pod 2개로 배포, rollout 실패 시 자동 rollback
5. smoke test 통과 후 완료

### 3-4. 배포 확인

```bash
kubectl -n vendor-a-prod get deploy,pods,ingress
kubectl -n vendor-a-prod rollout history deployment/homepage
curl -sk https://homepage-vendor-a.192.168.40.216.nip.io/healthz.php
```

`rollout history`의 CHANGE-CAUSE에 `jenkins #<빌드번호> <태그>`가 기록된다.

### 3-5. 롤백

| 방법 | 명령 | 용도 |
| --- | --- | --- |
| 이전 릴리스 재배포 (권장) | `homepage-prod` job을 `RELEASE_TAG=v1.1.3`으로 실행 | 기록이 남는 정식 롤백 |
| 즉시 롤백 | `kubectl -n vendor-a-prod rollout undo deployment/homepage` | 장애 긴급 대응 |
| 특정 이력으로 롤백 | `kubectl -n vendor-a-prod rollout undo deployment/homepage --to-revision=<번호>` | 여러 버전 이전으로 복구 |

---

## 4. 권한 매트릭스

| 자원 | 운영 관리자 | 업체 PM | 업체 개발자 | Jenkins 계정 |
| --- | --- | --- | --- | --- |
| SCM 업체 저장소 | 관리 | 쓰기(태그) | 쓰기 | 보기 |
| 다른 업체 저장소 | 관리 | - | - | - |
| Jenkins `<app>-dev` | 관리 | 조회(선택) | 조회(선택) | - |
| Jenkins `<app>-prod` | 실행·승인 | - | - | - |
| Harbor `<vendor>` | 관리 | 조회(선택) | - | robot push/pull |
| namespace `<vendor>-dev` | 관리 | 조회(선택) | 조회(선택) | deployer(edit) |
| namespace `<vendor>-prod` | 관리 | - | - | deployer(edit) |

---

## 5. 점검·문제 해결

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| `php: not found`, `buildah: not found` | 기본 Jenkins 이미지 사용 중 | `build-jenkins-php-image.sh` 후 Jenkins 이미지 교체 |
| Credentials `vendor-a-...` not found | credential ID 오타 또는 다른 폴더에 등록 | 업체 폴더 범위에 1-5 표의 ID로 등록 |
| Composer install 실패 | packagist 접근 불가 | Jenkins Pod의 외부 HTTPS 접근, 프록시 설정 확인 |
| Push 401/403 | robot 계정 만료·삭제 | Harbor에서 robot 확인, `vendors/<vendor>/harbor-robot.env` 삭제 후 온보딩 재실행 |
| Pod `ImagePullBackOff` | pull secret 또는 노드의 Harbor CA 신뢰 문제 | `kubectl -n <ns> get secret harbor-regcred`, 노드 CA(cp-cert-setup) 확인 |
| Pod `Pending`, `exceeded quota` | ResourceQuota 초과 | 쿼터 상향 또는 replicas/resources 조정 |
| `Checked-out commit ... is not tag` | 운영 job 브랜치 설정 오류 | Branch Specifier `refs/tags/${RELEASE_TAG}`, Lightweight checkout 해제 |
| deployer token 만료(기본 1년) | ServiceAccount token 기간 종료 | `onboard-php-vendor.sh <vendor>` 재실행 후 kubeconfig credential 교체 |

---

## 6. 업체 계약 종료 (오프보딩)

1. SCM: 업체 계정 삭제, 저장소 권한 회수(저장소는 보존하거나 백업 후 보관)
2. Jenkins: 업체 폴더 job 비활성화, 폴더 credential 삭제
3. Harbor: 프로젝트 `vendor-a`의 robot 계정 삭제
4. Kubernetes: 서비스 이관 완료 후
   ```bash
   kubectl delete namespace vendor-a-dev
   # 운영 서비스를 다른 업체로 이관하는 경우 vendor-a-prod는 이관 후 삭제
   ```
5. `cp-pipeline-deployment/vendors/vendor-a/` 파일 삭제
