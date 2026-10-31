# CI/CD 콘솔 운영 관리자 가이드 (업체 등록 · 앱 추가)

CI/CD 콘솔(`https://cicd.<도메인>`)에서 **업체를 등록하고 앱을 추가하는 방법**을 처음 하는 사람 기준으로 순서대로 설명한다.
이 환경의 주소는 `https://cicd.192.168.20.151.nip.io`이다. 이하 `<도메인>` = `192.168.20.151.nip.io`.

업체 개발자에게는 [CI/CD 콘솔 업체 가이드](console-vendor-guide.md)를 전달한다.
콘솔 설치·구성은 [CI/CD 콘솔 가이드](console-guide.md)를 본다.

---

## 0. 먼저 알아 둘 용어

| 용어 | 뜻 | 예 |
| --- | --- | --- |
| 업체 | 서비스를 개발·운영하는 팀 또는 회사. 콘솔·Harbor·Kubernetes에서 이 ID로 구분된다 | `saeoll` |
| 앱 | 업체가 배포하는 서비스 하나. 소스 저장소 1개 = 앱 1개 | `homepage`, `php-service` |
| dev / prod | 개발(테스트) 환경 / 운영 환경 | `saeoll-dev`, `saeoll-prod` 네임스페이스 |
| 소스 | 소스 저장소와 빌드 도구의 조합. **scm** = K-PaaS SCM + Jenkins(내부 팀), **gitlab** = GitLab(외부 업체) | 이 환경은 `scm` |
| CI 계정 | Jenkins·Argo CD가 SCM 저장소를 읽고 쓰는 계정 | `jenkins-saeoll` 또는 `saeoll` |
| Sync | Argo CD가 gitops 저장소의 설정대로 Kubernetes에 배포하는 것. dev는 자동, prod는 운영 관리자가 버튼으로 | |
| 작업 | 콘솔이 대신 실행하는 스크립트(업체 등록, 앱 추가, DB 연결, 시스템 점검) | 작업 이력 메뉴 |

전체 흐름은 다음과 같다.

```text
[운영 관리자]                                   [업체 개발자]
 1. Keycloak 사용자 만들기
 2. 콘솔 업체 등록 (1차) ─ 수동 대기
 3. CI 계정 git 비밀번호 설정
 4. 콘솔 업체 등록 (2차) ─ 성공
 5. SCM 저장소 만들기 + 참여자 지정
 6. 콘솔 앱 추가 ───────────────────────────▶  7. git clone, develop에 push → dev 자동 배포
                                               8. 태그 v1.0.0 → 콘솔 [릴리스]
 9. 콘솔 prod Sync (운영 배포 승인) ◀──────────  배포 요청
```

---

## 1. 준비 확인 (최초 1회)

| 항목 | 확인 방법 |
| --- | --- |
| 내 계정이 운영 관리자인가 | 콘솔 오른쪽 위 이름 옆에 **운영 관리자** 표시가 있다 (Keycloak 그룹 `cicd-admins`) |
| 콘솔이 SCM 관리자 비밀번호를 알고 있는가 | 설치 때 `SCM_ADMIN_PASSWORD=... ./deploy-cicd-portal.sh console`로 실행했다. 모르면 다시 실행한다 |
| 시스템이 정상인가 | 대시보드 → **시스템 점검** → 마지막 줄이 `[RESULT] OK` |

> 운영 관리자 표시가 없으면: Keycloak 관리 화면 → `cp-realm` → Groups → `cicd-admins` → Members에 내 계정을 추가하고,
> 콘솔에서 **로그아웃 후 다시 로그인**한다.
>
> GitLab을 쓰지 않는데 시스템 점검에서 GitLab 항목이 FAIL이면 `cicd-vars.sh`의 `CICD_SOURCES`를 `"scm"`으로 바꾸고
> `./deploy-cicd-portal.sh console`을 다시 실행한다.

---

## 2. 콘솔 로그인과 화면

1. 브라우저에서 `https://cicd.<도메인>` 접속 → Keycloak 로그인 화면 → K-PaaS 계정으로 로그인
   (사설 인증서 경고가 나오면 `ca.crt`를 PC에 설치하거나 "고급 → 계속"을 누른다).
2. 위쪽 메뉴

| 메뉴 | 하는 일 |
| --- | --- |
| **대시보드** | 전체 업체·앱의 dev/prod 상태. 숫자 카드: 업체 수, 앱 수, dev 정상, **prod 배포 대기**, **오류 환경** |
| **업체 등록** | 새 업체 등록, 기존 업체 설정 다시 실행 |
| **작업 이력** | 콘솔이 실행한 스크립트 목록과 실시간 로그 |

3. 업체 이름을 누르면 업체 화면, 앱 이름을 누르면 앱 화면(파이프라인·빌드 이력·배포 환경)으로 간다.

---

## 3. 업체 등록 전 준비 — 사용자 계정 만들기

업체 사람(PM·개발자)마다 Keycloak 계정이 있어야 한다.

1. `https://keycloak.<도메인>` → 관리 콘솔 로그인 → 왼쪽 위 realm을 **cp-realm**으로 선택
2. **Users** → **Add user**

| 항목 | 입력 |
| --- | --- |
| Username | `<업체>-<이름>` 권장 (예: `saeoll-hong`). 영문 소문자·숫자·`-` |
| Email | 반드시 입력 (GitLab 로그인에 필요) |
| Email verified | 켬 |
| First name / Last name | 실명 |

3. 저장 → **Credentials** 탭 → **Set password** → 임시 비밀번호 입력, **Temporary 켬**(첫 로그인 때 바꾸게 함)
4. 업체 ID를 정한다: 영문 소문자·숫자·`-`, 2~30자 (예: `saeoll`). **나중에 바꿀 수 없다.**
   `cicd`, `default`는 쓸 수 없고, 같은 이름의 Kubernetes 네임스페이스가 이미 있으면 등록이 거부된다.

---

## 4. 업체 등록 (K-PaaS SCM 업체)

SCM 업체는 **두 번 실행**한다. 1차 실행에서 CI 계정이 만들어지고, 그 계정의 git 비밀번호를 설정한 뒤 2차 실행에서 마무리된다.

### 4-1. 1차 실행

메뉴 **업체 등록**에서 입력한다.

| 칸 | 입력 | 설명 |
| --- | --- | --- |
| 업체 ID | `saeoll` | 3장에서 정한 ID |
| 소스 저장소 · CI | **K-PaaS SCM + Jenkins** | GitLab을 설치했으면 GitLab도 보인다(외부 업체용, 4-5) |
| 네임스페이스 구성 | **분리** (권장) | 분리: `saeoll-dev`, `saeoll-prod` 두 개 / 단일: `saeoll` 하나에 dev·prod. **나중에 바꿀 수 없다** |
| 개발자 | `saeoll-hong,saeoll-kim` | 쉼표로 구분, 띄어쓰기 없이. 비워 두고 나중에 구성원 탭에서 추가해도 된다 |
| PM (GitLab Maintainer) | 비움 | GitLab 업체에서만 사용 |
| CI 계정 | 비움 | 비우면 `jenkins-saeoll` 계정을 새로 만든다. 이미 git 비밀번호를 설정한 기존 계정(예: `saeoll`)을 쓰려면 그 ID 입력 |
| CI 계정 git 비밀번호 | **비움** (새 CI 계정일 때) | 기존 계정을 CI 계정으로 쓰고 git 비밀번호를 알면 여기에 넣는다 → 2차 실행 없이 바로 끝난다 |

**실행**을 누르면 작업 화면으로 이동해 로그가 실시간으로 나온다.
새 CI 계정이면 상태가 **수동 대기**(종료 코드 3)로 끝나고 마지막에 할 일 목록이 나온다. 정상이다.

```text
Vendor saeoll partially onboarded. Complete these in K-PaaS source control and re-run ...
  - Sign in to https://scm.<도메인> as jenkins-saeoll, set its git password in 내정보 관리 ...
      (Keycloak password of jenkins-saeoll: kubectl -n cicd-jenkins get secret cicd-portal-secrets ...)
```

이 시점에 Keycloak 그룹 `cicd-saeoll`, Harbor 프로젝트 `saeoll`, 네임스페이스, Argo CD 프로젝트는 이미 만들어져 있다.

### 4-2. CI 계정의 git 비밀번호 설정

1. 관리 노드에서 CI 계정의 Keycloak 비밀번호를 확인한다(로그에 나온 명령).

   ```bash
   kubectl -n cicd-jenkins get secret cicd-portal-secrets -o jsonpath='{.data.kc-jenkins-saeoll-password}' | base64 -d; echo
   ```

2. 브라우저 **시크릿 창**에서 `https://scm.<도메인>` → `jenkins-saeoll` / 위 비밀번호로 로그인(최초 로그인 시 SCM 계정이 생긴다)
3. 오른쪽 위 계정 → **내정보 관리** → **비밀번호 변경** → 새 비밀번호 입력. 이것이 **git 비밀번호**다(Keycloak 비밀번호와 별개). 메모해 둔다.
4. 로그아웃하고 시크릿 창을 닫는다.

### 4-3. 2차 실행

메뉴 **업체 등록**에서 **같은 업체 ID**로 다시 입력한다.

| 칸 | 입력 |
| --- | --- |
| 업체 ID | `saeoll` (같은 값) |
| 소스 · 네임스페이스 | 1차와 같은 값 |
| 개발자 | 비워도 된다 (1차에 넣은 사람은 이미 추가됨) |
| CI 계정 | 1차에 비웠으면 비움 (기록된 계정을 사용) |
| CI 계정 git 비밀번호 | **4-2에서 설정한 git 비밀번호** |

상태가 **성공**이면 끝이다. 로그 마지막에 다음과 같이 나온다.

```text
Vendor saeoll onboarded.
  SCM          : https://scm.<도메인>  (gitops repository saeoll-gitops, CI account jenkins-saeoll)
  Jenkins      : https://jenkins.<도메인>/job/saeoll/
  ...
Next: ./add-app.sh saeoll <app> <java-gradle|java-maven|php|node|vue>
```

> **중요 — 다시 실행할 때는 항상 CI 계정 git 비밀번호를 함께 넣는다.**
> 업체 등록은 실행할 때마다 Harbor 로봇 계정 비밀번호를 새로 발급한다. 비밀번호 칸을 비워 두고 다시 실행하면
> Jenkins에 저장된 Harbor 비밀번호가 갱신되지 않아 **빌드의 이미지 push가 실패**한다. 이때는 비밀번호를 넣고 한 번 더 실행하면 된다.
> 구성원만 추가하려면 업체 등록을 다시 실행하지 말고 **업체 화면 → 구성원 탭**(7장)을 쓴다.

### 4-4. 결과 확인

대시보드에 업체가 나타나고, 업체 이름을 누르면 **업체 정보** 탭에서 다음을 볼 수 있다.

| 항목 | 값 (예) |
| --- | --- |
| 소스 | SCM + Jenkins |
| 네임스페이스 | `saeoll-dev`, `saeoll-prod` (dev/prod 분리) |
| Harbor 프로젝트 | `saeoll` (robot `robot$saeoll+cicd`) |
| CI 계정 | `jenkins-saeoll` |
| gitops 저장소 | `http://cp-source-control-manager-service.../scm/git/saeoll-gitops` |
| 리소스 쿼터 | 네임스페이스마다 CPU 4 / 메모리 8Gi / Pod 30 |

### 4-5. GitLab 업체 (GitLab을 설치한 경우)

1. 업체 사람들이 `https://gitlab.<도메인>`에 **한 번 로그인**(K-PaaS SSO)해야 GitLab 계정이 생긴다. 로그인했는지 확인한다.
2. **업체 등록** → 소스 **GitLab**, 개발자·PM 입력 → 실행. 한 번에 끝난다.
3. 로그에 `GitLab user ... not found`가 있으면 그 사람이 아직 GitLab에 로그인하지 않은 것이다. 로그인 후 같은 값으로 다시 실행한다.

---

## 5. 앱 추가

### 5-1. SCM 저장소 만들기 (SCM 업체만)

앱 추가 전에 소스 저장소를 K-PaaS SCM 화면에서 만든다. **SCM-Manager 관리 화면이 아니라 `scm.` 화면**에서 만들어야 K-PaaS 목록에 나온다.

1. `https://scm.<도메인>`에 운영 관리자 계정으로 로그인
2. **레파지토리** → **신규생성** → 유형 **Git**, 이름 **`<업체>-<앱>`** (예: `saeoll-homepage`) → 저장
3. 만든 저장소 상세 → **참여자 추가**

| 참여자 | 권한 |
| --- | --- |
| CI 계정 (`jenkins-saeoll` 또는 업체 정보의 CI 계정) | **보기** |
| 업체 개발자 | **쓰기** |

> 참여자로 추가하려면 그 사람이 `scm.`에 **한 번 로그인**한 적이 있어야 한다.
> 이미 있는 저장소를 쓰려면 새로 만들지 않고 참여자만 확인한 뒤 5-2에서 **기존 SCM 저장소 이름**에 그 이름을 넣는다.

### 5-2. 콘솔에서 앱 추가

업체 화면 → 오른쪽 위 **+ 앱 추가**.

| 칸 | 입력 | 설명 |
| --- | --- | --- |
| 앱 ID | `homepage` | 영문 소문자·숫자·`-`. 접속 주소가 된다: dev `https://homepage-saeoll-dev.<도메인>`, prod `https://homepage-saeoll.<도메인>` |
| 언어 · 빌드 유형 | `php` / `java-gradle` / `java-maven` / `node` / `vue` | 시작 소스와 Jenkinsfile 종류 |
| 헬스 체크 경로 | 비움 | 기본 `/healthz` (php는 `/healthz.php`). 앱이 다른 경로로 응답하면 입력 (예: `/actuator/health`) |
| 시작 소스를 넣지 않음 | 새 앱이면 끔 | 켜면 샘플 소스를 넣지 않는다. 기존 소스를 쓸 때 (저장소에 Dockerfile·Jenkinsfile 필요) |
| 기존 CI 파일을 포털 버전으로 교체 | 보통 끔 | 예전 K-PaaS 파이프라인용 `Jenkinsfile`이 있는 저장소일 때 켠다 |
| 기존 SCM 저장소 이름 | 비움 | 저장소 이름이 `<업체>-<앱>`이 아닐 때만 입력 (예: `saeoll`) |
| dev DB | 연결 안 함 | DB가 필요하면 6장에서 따로 연결해도 된다 |

**실행** → 작업 로그에서 진행을 본다(1~3분). 성공하면 로그 마지막에 다음이 나온다.

```text
Application saeoll/homepage (php) ready.
  Dev URL  : https://homepage-saeoll-dev.<도메인>
  Prod URL : https://homepage-saeoll.<도메인>   (after Argo CD sync of saeoll-homepage-prod)
The dev application stays Degraded until the first develop build pushes an image.
```

앱 추가가 하는 일:

| 대상 | 내용 |
| --- | --- |
| SCM 저장소 `saeoll-homepage` | 시작 소스(샘플, Dockerfile, Jenkinsfile)를 `main`에 넣고 `develop` 브랜치 생성 (기존 파일은 덮어쓰지 않음) |
| gitops `saeoll-gitops` | `apps/homepage/` 아래 배포 설정 (dev, prod) |
| Jenkins | `saeoll/homepage-dev` (develop 자동 빌드), `saeoll/homepage-release` (릴리스 태그 빌드) |
| Argo CD | `saeoll-homepage-dev` (자동 배포), `saeoll-homepage-prod` (수동 배포) |

### 5-3. 첫 배포 확인

1. 앱 화면을 연다(대시보드 → 앱 이름). 첫 빌드가 자동으로 시작되어 **빌드 이력**에 `#1 실행 중`이 보인다. 화면은 15초마다 새로 고쳐진다.
2. 빌드가 **성공**하면 잠시 뒤 **3. dev 배포**가 `정상 · 동기화됨`이 된다(보통 3~10분).
3. dev 환경 패널의 **접속 주소**를 눌러 샘플 화면이 나오는지 본다.
4. 업체 개발자에게 다음을 전달한다.
   - 계정 ID·임시 비밀번호, `ca.crt` (`~/Saeoll-PaaS/cp-portal-deployment/certs/ca.crt`, `ca.key`는 절대 전달 금지)
   - 콘솔 주소 `https://cicd.<도메인>`, git 주소 `https://scm-manager.<도메인>/scm/git/saeoll-homepage`
   - [CI/CD 콘솔 업체 가이드](console-vendor-guide.md)

> 첫 빌드가 실패하면 빌드 이력의 **로그**를 누른다. 자주 나오는 원인은 10장을 본다.

---

## 6. DB 연결 (필요한 앱만)

앱 화면 → 오른쪽 위 **DB 연결**.

| 칸 | 선택 | 설명 |
| --- | --- | --- |
| 환경 | dev → 확인 후 prod | prod는 운영 관리자가 prod Sync할 때 반영된다 |
| 방식 | **전용** (권장) | 앱 네임스페이스에 MariaDB를 따로 만든다(2Gi) |
| | 공용 | K-PaaS MariaDB에 DB·사용자만 만든다. 빠른 테스트용 |
| | 외부 | 이미 있는 DB의 접속 정보를 등록 (DB_HOST 등 입력) |

실행하면 Secret `homepage-db`(DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD)가 만들어지고 앱이 이 값을 환경 변수로 받는다.
비밀번호는 화면·Git에 남지 않는다. 업체에는 "환경 변수 `DB_HOST` 등을 읽도록 개발"하라고 안내한다.

---

## 7. 구성원 관리

업체 화면 → **구성원** 탭.

- **추가**: 사용자 ID 입력 → **추가**. 그 사람은 다시 로그인하면 콘솔·Jenkins·Argo CD에서 이 업체를 볼 수 있다.
- **제외**: 목록의 **제외** 버튼.
- SCM 업체는 저장소 쓰기 권한이 따로다. `scm.` 화면에서 저장소 **참여자**에도 추가·삭제한다.

---

## 8. 운영(prod) 배포 승인과 롤백

### 8-1. prod Sync

1. 업체가 릴리스 빌드를 성공시키면 대시보드 **prod 배포 대기** 숫자가 올라가고, 앱의 prod가 **변경 있음**으로 표시된다.
2. 앱 화면 → **5. prod 배포**의 이미지 태그(예: `v1.0.0`)가 요청받은 버전인지 확인한다.
3. **prod Sync** → 확인. 몇 분 뒤 prod 환경이 `정상 · 동기화됨`이 되고 이미지 태그가 바뀐다.

### 8-2. 롤백

앱 화면 → prod 환경 → **배포 이력** → 되돌릴 행의 **롤백** → 확인.

- 롤백 후 prod는 **변경 있음**으로 보인다(gitops 최신 설정과 다르기 때문). 다음 prod Sync를 누르면 다시 최신으로 간다.
- 롤백을 계속 유지하려면 업체에게 이전 버전으로 새 릴리스(예: `v1.0.1`)를 만들게 하는 것이 가장 깔끔하다.
- dev는 자동 배포라 롤백 버튼이 없다. 업체가 develop에 수정본을 push하면 된다.

---

## 9. 작업 이력과 시스템 점검

- **작업 이력**: 콘솔에서 실행한 업체 등록·앱 추가·DB 연결·점검이 최근 50개까지 남는다. 콘솔 Pod가 재시작되면 지워진다.
  작업은 한 번에 하나씩 실행되고, 앞 작업이 끝날 때까지 **대기**로 보인다.

| 상태 | 뜻 |
| --- | --- |
| 성공 | 정상 완료 |
| 수동 대기 | 사람이 할 일이 남음(로그 마지막 목록). 처리 후 같은 값으로 다시 실행 |
| 실패 | 로그의 `[ERROR]` 줄을 보고 10장 참고 |

- **시스템 점검**: 대시보드 → **시스템 점검**. Pod, 접속 주소, Keycloak 클라이언트, SCM·Jenkins API, 업체·앱 상태를 검사한다.

---

## 10. 문제 해결

| 증상 (작업 로그) | 원인 | 조치 |
| --- | --- | --- |
| 업체 등록이 **수동 대기**로 끝남 | 새 CI 계정의 git 비밀번호가 아직 없음 | 4-2 → 4-3 |
| `Namespace saeoll-dev already exists and is not managed by the CI/CD portal` | 같은 이름의 네임스페이스가 이미 있음(CP-Portal 사용자 네임스페이스 등) | 다른 업체 ID 사용 |
| `Set SCM_ADMIN_PASSWORD` / SCM `HTTP 401` | 콘솔이 SCM 관리자 비밀번호를 모름 | 관리 노드: `SCM_ADMIN_PASSWORD='...' ./deploy-cicd-portal.sh console` (scmadmin의 **git 비밀번호**) |
| `Jenkins API token not found` | Jenkins API 토큰 미등록 | 관리 노드: `JENKINS_USER=admin JENKINS_API_TOKEN=... ./deploy-cicd-portal.sh jenkins-token` |
| `Prepare 'saeoll-homepage' in https://scm...` (앱 추가) | SCM 저장소가 없거나 CI 계정이 참여자가 아님 | 5-1 (CI 계정 **보기** 권한) |
| `Cannot clone ... as scmadmin` | scmadmin이 저장소를 읽지 못함 | `scm.`에서 저장소 이름 확인, SCM 관리자 비밀번호 재등록 |
| 빌드 로그 Image 단계에서 `UNAUTHORIZED` / push 실패 | 업체 등록을 비밀번호 없이 재실행해 Harbor 비밀번호 불일치 | 업체 등록을 CI 계정 git 비밀번호와 함께 다시 실행 (4-3) |
| dev가 계속 `오류`/`진행 중` | 첫 이미지가 아직 없거나 앱이 헬스 체크에 응답하지 않음 | 빌드 성공 여부 확인 → dev 환경 패널의 경고 문구 확인 → 헬스 체크 경로 확인 |
| 업체 화면에 "소스가 기록되어 있지 않아" | 예전 방식으로 만든 Argo CD 프로젝트 | 같은 업체 ID로 업체 등록을 다시 실행 |
| 로그인 후 "접근할 수 있는 업체가 없습니다" | 그룹 미소속 | `cicd-admins` 또는 `cicd-<업체>` 그룹 추가 후 재로그인 |

---

## 11. 신규 업체 체크리스트

- [ ] Keycloak 사용자 생성 (Email 포함, 임시 비밀번호)
- [ ] 콘솔 업체 등록 1차 → 수동 대기
- [ ] CI 계정으로 `scm.` 로그인 → 내정보 관리에서 git 비밀번호 설정
- [ ] 콘솔 업체 등록 2차 (git 비밀번호 입력) → 성공
- [ ] `scm.`에서 저장소 `<업체>-<앱>` 생성, 참여자: CI 계정 보기 / 개발자 쓰기 (개발자는 `scm.` 최초 로그인 필요)
- [ ] 콘솔 앱 추가 → 성공 → 첫 빌드 성공 → dev 접속 확인
- [ ] (필요 시) DB 연결
- [ ] 업체에 계정·`ca.crt`·주소·[업체 가이드](console-vendor-guide.md) 전달
