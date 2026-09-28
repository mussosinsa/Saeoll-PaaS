# 신규 서비스 배포 사전작업 및 파이프라인 사용 가이드

신규 PHP 서비스를 K-PaaS 컨테이너 플랫폼에 배포하기 전에 운영 관리자가 수행하는 사전작업과,
사전작업 완료 후 업체(개발자)가 파이프라인을 사용하는 방법을 정리한다.

## 0. 개요

### 0-1. 사전작업 정의

| No | 사전작업 | 대상 시스템 | 수행자 | 결과물 |
| --- | --- | --- | --- | --- |
| 1 | 포털 계정 생성 | CP-Portal (Keycloak) | 업체 담당자 가입 → 운영 관리자 확인 | 포털 로그인 계정 |
| 2 | 네임스페이스 생성 및 계정 권한 부여 | Kubernetes, CP-Portal | 운영 관리자 | `<업체>-dev`, `<업체>-prod` namespace, 사용자별 권한 |
| 3 | SCM 계정 생성 및 권한 부여 | 소스컨트롤(SCM) | 운영 관리자 | 개인 계정, Jenkins용 계정, 저장소 권한 |
| 4 | 베이스 이미지 Harbor 등록 | Harbor | 운영 관리자 | `base-images` 프로젝트의 승인된 베이스 이미지 |
| 5 | 파이프라인 등록 | Jenkins | 운영 관리자 | 업체 폴더, credential, dev/prod job |

### 0-2. 전체 흐름

```text
[업체] 서비스 등록 신청서 제출
   │
[운영] ① 포털 계정 확인 ─ ② namespace 생성·권한 ─ ③ SCM 계정·저장소 ─ ④ 베이스 이미지 등록 ─ ⑤ 파이프라인 등록
   │
[업체] 소스 등록(push) → develop 자동 배포(개발) → 릴리스 태그 → [운영] 승인 → 운영 배포
```

### 0-3. 접속 주소 (HOST_DOMAIN = `192.168.40.216.nip.io` 기준)

| 시스템 | 주소 | 비고 |
| --- | --- | --- |
| CP-Portal | `https://portal.192.168.40.216.nip.io` | 포털 계정 |
| Keycloak 관리 콘솔 | `https://keycloak.192.168.40.216.nip.io/admin` | 운영 관리자 전용 |
| Harbor | `https://harbor.192.168.40.216.nip.io` | 운영 관리자 전용 |
| 소스컨트롤(SCM) | `https://scm.192.168.40.216.nip.io` | 별도 설치 필요(본 저장소 미포함) |
| Pipeline | `https://pipeline.192.168.40.216.nip.io` | 포털 계정 |
| Jenkins | `kubectl -n cp-pipeline port-forward svc/cp-pipeline-jenkins-service 8080:8080` | 운영 관리자 전용 |

### 0-4. 명명 규칙

| 항목 | 규칙 | 예시 |
| --- | --- | --- |
| 업체 ID | 영문 소문자·숫자·`-`, 30자 이내 | `vendor-a` |
| 서비스(앱) 이름 | 영문 소문자·숫자·`-` | `homepage` |
| 포털/SCM 계정 | 개인별 발급, `<업체ID>-<이름>` 권장 | `vendor-a-hong` |
| namespace | `<업체ID>-dev`, `<업체ID>-prod` | `vendor-a-dev` |
| SCM 저장소 | `<업체ID>-<서비스>` | `vendor-a-homepage` |
| Harbor 프로젝트 | 업체 `<업체ID>`, 공통 `base-images` | `vendor-a` |
| 서비스 URL | 개발 `<서비스>-<업체ID>-dev.<도메인>`, 운영 `<서비스>-<업체ID>.<도메인>` | `homepage-vendor-a.192.168.40.216.nip.io` |

### 0-5. 서비스 등록 신청서 (업체 → 운영 관리자)

```text
[신규 서비스 등록 신청]
업체명 / 업체 ID       : ○○소프트 / vendor-a
서비스명 / 서비스 ID   : 기관 홈페이지 / homepage
담당자(PM)            : 성명, 이메일, 연락처
개발자 목록            : 성명, 이메일, 역할(개발/PM) - 인원별 1행
PHP 버전 / 웹서버      : PHP 8.3 / Apache
필요 확장·패키지       : pdo_mysql, gd, ...
외부 연동              : DB(호스트, 포트), 외부 API 등
필요 자원(예상)        : CPU 2, 메모리 4Gi, Pod 10
서비스 오픈 예정일     : 2026-11-01
```

---

## 1. 포털 계정 생성

포털 로그인은 Keycloak(`cp-realm`)을 사용하며, 로그인 화면에서 회원가입이 가능하도록 설정되어 있다.

### 1-1. 사용자 가입 (업체 담당자·개발자)

1. `https://portal.<도메인>` 접속 → 로그인 화면의 **Register(회원가입)** 클릭
2. Username(`vendor-a-hong`), 이름, 이메일, 비밀번호 입력 후 가입
3. 가입한 계정을 운영 관리자에게 알린다.

> 가입 직후에는 어떤 namespace에도 권한이 없으므로 서비스 자원이 보이지 않는다.

### 1-2. 운영 관리자가 직접 생성하는 경우

회원가입을 허용하지 않는 운영 정책이면 Keycloak 관리 콘솔에서 생성한다.

1. `https://keycloak.<도메인>/admin` → realm **cp-realm** 선택
2. **Users → Add user** → Username, Email, First/Last name 입력 → Create
3. **Credentials** 탭 → Set password (Temporary: On — 최초 로그인 시 변경)
4. 업체 계정은 **Groups**에 `cp-cluster-admin`을 절대 부여하지 않는다(클러스터 전체 관리자 그룹).

가입 자체를 막으려면 Keycloak `cp-realm` → Realm settings → Login → **User registration: Off**.

### 1-3. 확인

- 포털 **Managements → Users**에서 가입한 계정이 조회되는지 확인한다.
- 계정은 개인별로 발급하며 공용 계정을 사용하지 않는다.

---

## 2. 네임스페이스 생성 및 계정 권한 부여

### 2-1. namespace 생성 (운영 관리자) — 스크립트 사용 권장

포털 **Clusters → Namespaces**에서도 생성할 수 있지만, 업체 격리에 필요한 자원을 함께 만들기 위해
온보딩 스크립트를 사용한다.

```bash
cd ~/Saeoll-PaaS/cp-pipeline-deployment/script
./onboard-php-vendor.sh vendor-a
# 자원 한도 지정 예: QUOTA_CPU=2 QUOTA_MEMORY=4Gi QUOTA_PODS=10 ./onboard-php-vendor.sh vendor-a
```

| 생성 자원 | 내용 |
| --- | --- |
| namespace | `vendor-a-dev`, `vendor-a-prod` (라벨 `cp.k-paas.org/vendor=vendor-a`) |
| ResourceQuota / LimitRange | 기본 CPU 4, 메모리 8Gi, Pod 30 / 컨테이너 기본 요청·제한 |
| Secret | Harbor pull secret `harbor-regcred`, TLS secret(`*.<도메인>` 인증서) |
| ServiceAccount | `deployer` — 해당 namespace에서만 `edit` 권한 (Jenkins 배포용) |
| Harbor | private 프로젝트 `vendor-a`, robot 계정 `robot$vendor-a+ci` |
| 파일 | `cp-pipeline-deployment/vendors/vendor-a/` (kubeconfig, robot 계정, credential 목록 — 권한 600, Git 제외) |

확인:

```bash
kubectl get ns -l cp.k-paas.org/vendor=vendor-a
kubectl -n vendor-a-dev get resourcequota,secret,sa
```

### 2-2. 포털 사용자에게 namespace 권한 부여 (운영 관리자)

포털 **Managements → Users**에서 사용자를 선택하고 namespace와 역할(Role)을 지정한다.
역할의 세부 권한은 **Managements → Roles**에서 확인한다.
(화면 명칭은 포털 버전에 따라 다를 수 있다.)

| 사용자 | `vendor-a-dev` | `vendor-a-prod` |
| --- | --- | --- |
| 업체 PM | 조회·관리 | 조회 (필요 시) |
| 업체 개발자 | 조회·관리 | 권한 없음 |
| 운영 관리자 | 전체 | 전체 |

원칙:
- 업체 사용자에게 **Cluster Admin 권한을 부여하지 않는다.**
- 운영(`-prod`) namespace의 변경은 파이프라인(운영 관리자 승인)으로만 수행하고, 업체에는 조회 이상의 권한을 주지 않는다.
- 다른 업체 namespace 권한은 부여하지 않는다.

### 2-3. 확인

업체 계정으로 포털에 로그인하여 `vendor-a-dev` namespace만 선택·조회되는지 확인한다.

---

## 3. SCM 계정 생성 및 권한 부여

> 본 저장소에는 SCM 설치 스크립트가 없다. K-PaaS 소스컨트롤(`https://scm.<도메인>`) 또는
> 사내 Git 서버(GitLab 등)가 준비되어 있어야 한다. 아래 메뉴는 K-PaaS 소스컨트롤 기준이다.

### 3-1. 계정 생성

| 계정 | 생성 | 비고 |
| --- | --- | --- |
| 업체 개발자·PM 개인 계정 | 사용자 가입 또는 운영 관리자 생성 → 관리자 메뉴 **사용자 관리**에서 확인 | 개인별 발급 |
| Jenkins용 계정 `jenkins-vendor-a` | 운영 관리자 생성 | 업체 저장소 읽기 전용 |

### 3-2. 저장소 생성 및 권한 부여

1. **레파지토리** → 이름 `vendor-a-homepage`, 유형 **Git** → **생성**
2. 저장소 상세 → 기여자 관리

   | 계정 | 권한 |
   | --- | --- |
   | 업체 개발자, PM | **쓰기 권한** |
   | `jenkins-vendor-a` | **보기 권한** |
   | 운영 관리자 | 관리 |

3. **레파지토리 클론**에서 URL을 복사하여 업체에 전달한다.
4. 사내 Git을 사용하는 경우 `main` 브랜치를 보호(직접 push 금지, merge만 허용)한다.

### 3-3. 확인

```bash
# 업체 개발자 PC
git clone <클론 URL>          # 개인 계정으로 성공해야 함
# Jenkins 계정으로 clone은 되고 push는 거부되어야 함
```

---

## 4. 베이스 이미지 Harbor 등록

업체 서비스 이미지는 운영 관리자가 승인해 Harbor에 등록한 베이스 이미지로만 빌드한다.
Docker Hub 요청 제한, 폐쇄망, 검증되지 않은 이미지 사용을 막기 위함이다.

### 4-1. 등록 (운영 관리자)

```bash
cd ~/Saeoll-PaaS/cp-pipeline-deployment/script
./mirror-base-images.sh                                  # 기본: php:8.3-apache, composer:2
./mirror-base-images.sh php:8.2-apache php:8.3-fpm      # 추가 버전 등록
```

- Harbor에 **public** 프로젝트 `base-images`가 생성되고 이미지가 등록된다
  (모든 업체 빌드에서 인증 없이 pull 가능, push는 관리자만 가능).
- 출력되는 digest를 기록하여 이미지 변경 이력을 관리한다.

### 4-2. 등록 기준

| 항목 | 기준 |
| --- | --- |
| 출처 | Docker Hub 공식 이미지(`docker.io/library/*`) 또는 기관 승인 이미지 |
| 태그 | `latest` 금지, 버전 태그(`8.3-apache`) 사용 |
| 보안 | Harbor 취약점 스캔(Trivy)으로 Critical 취약점 확인 후 공지 |
| 갱신 | 월 1회 또는 보안 패치 시 재등록(동일 태그 재push) 후 업체 공지 |

Harbor 화면: `https://harbor.<도메인>` → Projects → `base-images` → Repositories에서
이미지와 스캔 결과(Vulnerabilities)를 확인한다.

### 4-3. 서비스에서 사용

파이프라인은 `BASE_REGISTRY=harbor.<도메인>/base-images`를 build-arg로 전달한다.
서비스 저장소의 Dockerfile은 다음 형식을 유지한다.

```dockerfile
ARG BASE_REGISTRY=docker.io/library
FROM ${BASE_REGISTRY}/composer:2 AS vendor
...
FROM ${BASE_REGISTRY}/php:8.3-apache
```

PHP 버전을 바꾸려면 먼저 운영 관리자에게 해당 베이스 이미지 등록을 요청한다.
등록되지 않은 이미지를 사용하면 빌드가 `manifest unknown`으로 실패한다.

---

## 5. 파이프라인 등록 (운영 관리자)

사전 조건: PHP 지원 Jenkins 이미지 적용(`script/build-jenkins-php-image.sh`, README 참고).

### 5-1. Jenkins 폴더와 credential

Jenkins → New Item → **Folder** `vendor-a` → 폴더의 Credentials에 등록한다
(값은 `vendors/vendor-a/jenkins-credentials.txt` 참고, 반드시 **폴더 범위**).

| ID | 종류 | 값 |
| --- | --- | --- |
| `vendor-a-harbor-robot` | Username with password | Harbor robot 계정 |
| `vendor-a-kubeconfig-dev` | Secret file | `kubeconfig-dev` |
| `vendor-a-kubeconfig-prod` | Secret file | `kubeconfig-prod` |
| `vendor-a-scm` | Username with password | `jenkins-vendor-a` SCM 계정 |

등록 후 `vendors/vendor-a/` 파일은 안전한 곳에 보관하거나 삭제한다.

### 5-2. job 생성

| 항목 | 개발 job `homepage-dev` | 운영 job `homepage-prod` |
| --- | --- | --- |
| 종류 | Pipeline | Pipeline |
| 빌드 유발 | Poll SCM `H/5 * * * *` | 없음(수동) |
| SCM | Git, 클론 URL, `vendor-a-scm` | 동일 |
| Branch Specifier | `*/develop` | `refs/tags/${RELEASE_TAG}` (Lightweight checkout 해제) |
| Script Path | `Jenkinsfile` | `Jenkinsfile` |
| 주요 파라미터 | `DEPLOY_ENV=dev`, `VENDOR=vendor-a`, `APP_NAME=homepage` | `DEPLOY_ENV=prod`, `RELEASE_TAG`, `APPROVERS` |
| 실행 권한 | 운영 관리자(자동 실행) | 운영 관리자만 |

### 5-3. 사전작업 완료 통보 (운영 관리자 → 업체)

```text
[신규 서비스 사전작업 완료]
포털 계정 / 권한     : vendor-a-hong - vendor-a-dev 권한 부여
SCM 저장소          : <클론 URL> (쓰기 권한)
개발 URL            : https://homepage-vendor-a-dev.192.168.40.216.nip.io
운영 URL            : https://homepage-vendor-a.192.168.40.216.nip.io
사용 가능 베이스 이미지 : base-images/php:8.3-apache, base-images/composer:2
자원 한도(namespace) : CPU 4, 메모리 8Gi, Pod 30
```

---

## 6. 파이프라인 사용 가이드 (업체)

### 6-1. 최초 소스 등록

저장소 루트 구조(`cp-pipeline-deployment/php-sample/` 복사):

```text
Jenkinsfile   Dockerfile   .dockerignore   composer.json   k8s/app.yaml
public/ (index.php, healthz.php 필수)   src/   tests/
```

```bash
git clone <클론 URL> vendor-a-homepage && cd vendor-a-homepage
cp -r <php-sample 경로>/. .
# Jenkinsfile 파라미터 기본값 VENDOR=vendor-a, APP_NAME=homepage 로 수정
git add -A && git commit -m "Initial import"
git push origin HEAD:main && git push origin HEAD:develop
```

- DB 비밀번호, API 키 등은 저장소에 커밋하지 않고 운영 관리자에게 Secret 등록을 요청한다.
- `public/healthz.php`는 헬스체크에 사용하므로 삭제하지 않는다.

### 6-2. 소스 수정 및 테스트 (개발 환경)

```bash
git checkout develop && git pull
git checkout -b feature/<작업명>
# 소스 수정 후 로컬 테스트
docker run --rm -v "$PWD":/app -w /app docker.io/library/composer:2 \
  sh -c 'composer install && find . -path ./vendor -prune -o -name "*.php" -print0 | xargs -0 -n1 php -l'
docker build -t app:local . && docker run --rm -p 8080:8080 app:local   # http://localhost:8080
# 반영
git checkout develop && git merge --no-ff feature/<작업명> && git push origin develop
```

`develop` push 후 5분 이내에 파이프라인이 자동 실행된다.

| 단계 | 내용 |
| --- | --- |
| Prepare | 이미지 태그 `dev-<커밋>-<빌드번호>` 결정 |
| Composer install | `composer validate`, `composer install` |
| Lint & Test | 전체 `php -l`, PHPUnit(있으면) |
| Build image | Harbor `base-images` 베이스로 빌드 |
| Push to Harbor | `harbor.<도메인>/vendor-a/homepage:<태그>` |
| Deploy | `vendor-a-dev`에 배포, 실패 시 자동 롤백 |
| Smoke test | `https://homepage-vendor-a-dev.<도메인>/healthz.php` 확인 |

확인: 개발 URL 접속, 포털에서 `vendor-a-dev` namespace의 Pod·로그 조회.

### 6-3. 운영 배포

1. 업체 PM: 릴리스 태그 생성
   ```bash
   git checkout main && git pull && git merge --no-ff develop
   git tag -a v1.0.0 -m "v1.0.0 최초 오픈"
   git push origin main --follow-tags
   ```
2. 업체 PM → 운영 관리자: 운영 배포 요청(태그, 변경 내용, 개발 검증 결과, 롤백 버전)
3. 운영 관리자: `homepage-prod` → Build with Parameters(`RELEASE_TAG=v1.0.0`) → **Approval** 승인
4. 운영 URL 확인: `https://homepage-vendor-a.<도메인>`
5. 롤백: 이전 태그로 `homepage-prod` 재실행, 긴급 시
   `kubectl -n vendor-a-prod rollout undo deployment/homepage`

상세 절차와 문제 해결은 [PHP 유지보수 업체별 소스 관리·배포 가이드](php-vendor-deploy-guide.md)를 참고한다.

---

## 7. 사전작업 점검표

| No | 점검 항목 | 확인 방법 | 확인 |
| --- | --- | --- | --- |
| 1 | 업체 인원별 포털 계정 가입·확인 | Managements → Users | ☐ |
| 2 | 업체 계정에 Cluster Admin 미부여 | Keycloak Groups, 포털 Users | ☐ |
| 3 | `<업체>-dev`, `<업체>-prod` namespace 생성 | `kubectl get ns -l cp.k-paas.org/vendor=<업체>` | ☐ |
| 4 | ResourceQuota, pull secret, TLS secret, deployer SA | `kubectl -n <ns> get resourcequota,secret,sa` | ☐ |
| 5 | 포털 사용자 namespace 권한(dev 관리, prod 조회/없음) | 업체 계정 로그인 확인 | ☐ |
| 6 | SCM 개인 계정 및 저장소 쓰기 권한 | clone/push 테스트 | ☐ |
| 7 | Jenkins용 SCM 계정 보기 권한 | clone 성공, push 거부 | ☐ |
| 8 | Harbor 업체 프로젝트, robot 계정 | Harbor Projects → `<업체>` → Robot Accounts | ☐ |
| 9 | 베이스 이미지 등록 및 취약점 확인 | Harbor `base-images` | ☐ |
| 10 | Jenkins 폴더 credential 4종(폴더 범위) | Jenkins 폴더 Credentials | ☐ |
| 11 | dev/prod job 생성, prod 실행 권한 제한 | 개발 job 1회 성공 | ☐ |
| 12 | `vendors/<업체>/` 민감 파일 정리 | 파일 삭제 또는 보안 보관 | ☐ |
| 13 | 사전작업 완료 통보 | 5-3 양식 발송 | ☐ |
