# CI/CD 콘솔 운영 관리자 가이드 (업체 등록 · 앱 추가)

CI/CD 콘솔(`https://cicd.<도메인>`)에서 **업체를 등록하고 앱을 추가하는 방법**을 처음 하는 사람 기준으로 순서대로 설명한다.
이하 `<도메인>`은 설치할 때 정한 도메인(`HOST_DOMAIN`, 예: `kpaas.example.co.kr`)이다.

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
| 개발자 (기존 계정) | `saeoll-hong,saeoll-kim` | Keycloak에 **이미 있는** ID. 쉼표로 구분, 띄어쓰기 없이 |
| 신규 개발자 계정 | `user11, 홍길동, hong@anbsoft.kr` (한 줄에 한 명) | Keycloak에 계정을 **새로 만든다**(3장 대신). 같은 ID·이메일이 있으면 오류. 임시 비밀번호는 실행 직후 작업 화면에 **한 번만** 표시 |
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

> **자동 생성 (권장)**: 앱 추가 화면의 **K-PaaS SCM 저장소 → 저장소 자동 생성**(기본 켜짐)을 쓰면 아래 수작업이 필요 없다.
> 저장소 `<업체>-<앱>`을 만들고 `scm.` 목록에 등록하며, CI 계정에 **보기**, 업체 구성원 전체(+ 추가 사용자)에 **쓰기** 권한을 준다.
> - `scm.`에 아직 한 번도 로그인하지 않은 사용자는 건너뛴다(작업 로그 마지막 `[TODO]`). 첫 로그인 후 앱 추가를 같은 값으로 다시 실행하면 추가된다.
> - `scm.` 목록 등록은 화면에서 만든 기존 저장소를 본떠서 한다. 기존 저장소가 하나도 없거나 형식을 알 수 없으면 등록을 건너뛰고 경고만 남긴다
>   (git·Jenkins는 정상 동작). 이때는 아래 수작업으로 화면에 등록한다.
>
> 자동 생성을 끈 경우의 수작업 절차:

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

> **임시 비밀번호**: 업체 등록의 '신규 개발자 계정'으로 만든 계정은 작업 화면 위쪽 **생성한 계정** 표에 임시 비밀번호가
> 한 번만 표시된다(복사 버튼). 놓쳤거나 분실했으면 구성원 탭의 **비밀번호 초기화**로 새 임시 비밀번호를 받는다.
> 사용자는 첫 로그인 때 새 비밀번호를 정한다. 이 업체 구성원만 초기화할 수 있다.

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

### 8-3. 보안 게이트와 prod 배포

보안 검사를 설치했다면(`./deploy-cicd-portal.sh security`) 앱 화면에 **보안 검사** 단계와 릴리스의 **보안** 결과가 보인다.
최근 릴리스 빌드가 보안 게이트를 통과하지 못했으면 버튼이 **prod Sync (보안 미통과)**로 바뀌고, 누르면 보안 보고서 링크와
**배포 사유** 입력 창이 나온다. 사유는 기록된다. 가능하면 업체가 조치하거나 예외 승인을 받은 뒤 새 릴리스로 배포한다.
게이트·프로파일·예외는 메뉴 **품질 관리**에서 관리한다 → [보안 검사 · 품질 관리 가이드](security-guide.md).

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
- [ ] (이미지 업체) 업체 화면 → 업체 정보 → **Harbor push 계정 발급** → 계정·비밀번호 전달, 앱 추가 시 유형 `image`

---

## 12. 이미지 배포 앱 (업체가 만든 컨테이너 이미지)

소스를 주지 않고 **완성된 컨테이너 이미지**만 납품하는 유지보수 업체용이다. 빌드는 업체가 하고, 포털은 이미지를 받아
보안 검사 → dev 배포 → (확인 후) prod 승격만 한다. 같은 업체(Harbor 프로젝트 `<업체>`) 안에서만 처리된다.

```text
업체 PC ──push──▶ Harbor <업체>/<앱>:v1.2.0 ──이미지 배포──▶ 보안 게이트 ──▶ gitops dev (자동 Sync)
                                              └──prod 승격(dev에 배포된 digest만)──▶ 보안 게이트 ──▶ gitops prod ──▶ 관리자 prod Sync
```

### 12-1. push 계정 발급 (업체당 1회)

1. 업체 화면 → **업체 정보** 탭 → **Harbor push 계정 발급**.
2. 화면에 계정(`robot$<업체>+push`)과 비밀번호가 **한 번만** 표시된다. 업체 담당자에게 안전하게 전달한다.
   - 다시 누르면 비밀번호가 새로 바뀌고 이전 비밀번호는 무효가 된다(분실 시 재발급).
   - 권한은 Harbor 프로젝트 `<업체>`의 push·pull 뿐이다. CI용 계정과는 별개다.
3. 발급 시 `v*` 태그는 **덮어쓰기 금지(immutable)**로 설정된다. 같은 `v1.2.0`을 다른 내용으로 다시 올릴 수 없다.

### 12-2. 앱 추가 (유형 image)

업체 화면 → **+ 앱 추가** → 언어 · 빌드 유형 **image**.

| 칸 | 입력 | 설명 |
| --- | --- | --- |
| 앱 ID | `erp` | Harbor 저장소 이름이 된다: `<업체>/erp` |
| 헬스 체크 | `/healthz` · `tcp` · `none` | 업체가 알려 준 확인 경로. 모르면 `tcp` |
| 컨테이너 포트 | `8080` | 이미지가 듣는 포트 (업체 확인) |
| 메모리 상한 | `512Mi` | 업체 권장값 |

SCM 저장소·Jenkinsfile·빌드 작업은 만들지 않는다. 대신 gitops 설정과 포털이 관리하는 Jenkins 작업 `<업체>/<앱>-deploy`,
Argo CD 앱(dev 자동 / prod 수동)을 만든다. 이미지가 아직 없으므로 dev는 첫 배포 전까지 `Degraded`가 정상이다.

### 12-3. 배포 흐름과 관리자 승인

| 단계 | 누가 | 화면 | 결과 |
| --- | --- | --- | --- |
| 1. 이미지 push | 업체 | (PC에서 podman/docker) | 앱 화면 **1. 이미지 (Harbor)**에 최근 이미지 표시 |
| 2. 이미지 배포 | 업체 또는 관리자 | 앱 화면 **이미지 배포** → 태그 선택 | 보안 검사(Trivy) 후 dev에 자동 배포 |
| 3. prod 승격 | 업체 또는 관리자 | **prod 승격** → `vX.Y.Z` 선택 | dev에 배포됐던 같은 digest만 통과 → gitops prod 갱신 → prod **변경 있음** |
| 4. prod Sync | **관리자** | 8-1과 동일 | 실제 운영 반영 (보안 미통과 시 사유 입력) |

- 이미지는 태그가 아니라 **digest(`sha256:…`)로 고정**된다. 승격 뒤 누군가 태그를 바꿔 올려도 prod에는 dev에서 확인한 이미지가 나간다.
- prod는 `vX.Y.Z` 태그만 승격할 수 있다. dev는 `latest`·`1.2.0-rc1` 같은 태그도 배포할 수 있다.
- 롤백은 8-2와 같다(배포 이력 → 롤백), 또는 이전 버전을 다시 **prod 승격**한다.

### 12-4. 콘솔에서 이미지 파일 올리기 (컨테이너 이미지 등록)

Harbor에 직접 push하기 어려운 업체(사내망 PC, podman 미설치 등)는 이미지 **파일**을 콘솔로 올린다.
업체 화면 오른쪽 위 **컨테이너 이미지 등록** (앱 화면의 **이미지 업로드**도 같음).

| 칸 | 입력 |
| --- | --- |
| 앱 | 기존 image 앱 선택. 관리자는 **+ 새 앱**으로 앱 추가(유형 image)까지 한 번에 할 수 있다 (포트를 비우면 이미지의 EXPOSE 포트) |
| 태그 | `v1.2.0` (운영 승격 가능) 또는 `dev-1` 같은 시험용 |
| 이미지 파일 | `podman save -o app.tar <이미지>` / `docker save` 결과, `.tar.gz`도 가능. 최대 2048MiB |
| 등록 후 dev에 배포 | 기본 켬 |

업로드가 끝나면 작업 화면으로 이동해 진행을 보여 준다(업로드한 사용자와 관리자만 볼 수 있음).

```text
[OK]   Image: docker-archive, linux/amd64, user '1000', ports 8080
[INFO] Pushing to harbor.<도메인>/<업체>/<앱>:v1.2.0 as robot$<업체>+upload
[OK]   Harbor ... (sha256:...)
[OK]   dev deployment started: security gate -> gitops dev -> Argo CD <업체>-<앱>-dev (auto sync)
```

- 파일은 풀지 않고 검사만 한다: `linux/amd64` 이미지 1개가 아니면 거절, root 실행·EXPOSE 없음은 경고.
- Harbor push는 그 업체 프로젝트 전용 계정(`robot$<업체>+upload`, 매번 새 비밀번호)으로 하므로 다른 업체 프로젝트에 올라갈 수 없다.
- 이미 있는 `v*` 태그는 거절된다. 업로드 파일은 push가 끝나거나 실패하면 바로 지워진다.
- 콘솔은 한 번에 **하나의 이미지만** 처리한다. 진행 중이면 "다른 이미지 등록이 진행 중" 메시지가 나온다.
- 한도 변경: `manifests/console.yaml`의 `CICD_UPLOAD_MAX_MB`(콘솔), Ingress `proxy-body-size`, `uploads` emptyDir `sizeLimit`(한도의 4배 이상)을 함께 바꾼다.
- 업로드가 413으로 바로 실패하면 Ingress 설정이 반영되지 않은 것이다 → `./deploy-cicd-portal.sh console` 다시 실행.

### 12-5. 반입 기준 (업체에 전달)

- `linux/amd64` 이미지, root가 아닌 사용자로 실행(`USER 1000` 등), 지정한 포트 하나로 서비스.
- 설정·접속 정보는 이미지에 넣지 않는다 → 환경변수/DB 연결 화면으로 주입. 비밀번호·키가 든 이미지는 보안 검사에서 막힌다.
- 버전 태그는 `v1.2.0` 형식, 한 번 쓴 태그는 다시 쓰지 않는다(`v*`는 덮어쓰기 금지).
- 보안 검사 기준(Critical 취약점 등)은 메뉴 **품질 관리**의 프로파일 `image`에서 관리한다.

---

## 13. 서비스 중지 · 앱 삭제 · 업체 중지 · 업체 삭제

모든 작업은 콘솔 **작업 로그**로 진행 상황이 보이며, 실행자와 사유가 기록된다.

| 작업 | 위치 | 권한 | 되돌리기 |
| --- | --- | --- | --- |
| 서비스 중지 / 재개 | 앱 화면 → dev·prod 환경 → **서비스 중지** | dev: 업체 구성원도 가능, prod: 관리자 | 서비스 재개 |
| 앱 삭제 | 앱 화면 → **앱 삭제…** | 관리자 | 불가 (보관 항목만 남음) |
| 업체 중지 / 재개 | 업체 화면 → 업체 정보 → **업체 중지** | 관리자 | 업체 재개 |
| 업체 삭제 | 업체 화면 → 업체 정보 → **업체 삭제…** | 관리자 | 불가 |

### 13-1. 서비스 중지 / 재개 (`app-state.sh`)

- gitops `apps/<앱>/overlays/<환경>/kustomization.yaml`의 `replicas` count를 0으로 바꾸고(이전 값은 주석 `was N`) Deployment를 바로 0으로 줄인다.
  Argo CD가 되돌리지 않으며, 이력이 git에 남는다.
- 중지 중에도 데이터·Secret·이미지·전용 MariaDB는 그대로다. 접속 주소는 503을 돌려준다.
- 대시보드·업체 화면에 `중지됨`으로 표시되고 **오류 환경** 숫자에서 빠진다.
- "Jenkins 빌드·배포 작업도 중지"를 켜면 `<앱>-dev/-release/-deploy`를 비활성화하고 재개할 때 다시 켠다.
- prod 재개는 **중지 전에 실행하던 버전**으로 돌아온다. 그동안 승격된 새 버전은 기존처럼 prod Sync로 배포한다.

### 13-2. 앱 삭제 (`remove-app.sh`)

1. prod가 실행 중이면 삭제할 수 없다 → prod **서비스 중지** 먼저.
2. **미리보기**: 실제로 찾은 대상(DB 종류, 볼륨, 저장소)을 작업 로그에 보여 주고 아무것도 바꾸지 않는다.
3. 사유와 앱 ID를 입력하고 **삭제**.

| 대상 | 기본 |
| --- | --- |
| Argo CD 앱(dev/prod)과 배포 리소스, gitops `apps/<앱>/`, Jenkins 작업, 품질 관리 프로파일·예외 | 삭제 |
| DB 데이터 (전용 MariaDB 볼륨, 공용 MariaDB DB·사용자, DB Secret) | **보관** (체크하면 삭제) |
| Harbor 이미지 `<업체>/<앱>` | **보관** |
| 소스 저장소 (SCM 저장소 + scm 목록 / GitLab 프로젝트) | **보관** |

DB를 보관하면 같은 앱 ID로 다시 **앱 추가 → DB 연결**할 때 기존 데이터와 비밀번호를 그대로 쓴다.
외부 DB는 Secret만 지우고 DB 자체는 건드리지 않는다.

### 13-3. 업체 중지 / 재개 (`vendor-state.sh`)

계약 종료나 일시 정지에 쓴다. 중지하면 다음이 적용된다.
- 모든 앱의 dev·prod를 13-1 방식으로 중지한다.
- Argo CD 프로젝트에 deny sync window를 걸어 수동 Sync도 막는다.
- Jenkins 폴더의 작업을 비활성화한다.
- Harbor robot 계정(cicd, push, upload)을 비활성화한다.
- 업체 구성원은 콘솔에서 **조회만** 할 수 있다(빌드·배포·이미지 등록 불가).

**업체 재개**는 위를 되돌리되, **업체 중지로 멈춘 앱만** 다시 시작한다(그 전에 따로 중지한 앱은 그대로 둔다).
GitLab 업체는 파이프라인 자체는 돌지만 배포(Sync)와 Harbor push가 막힌다.

### 13-4. 업체 삭제 (`remove-vendor.sh`)

1. prod가 실행 중인 앱이 있으면 삭제할 수 없다 → **업체 중지** 먼저.
2. 앱이 남아 있으면 앱 삭제를 먼저 하거나 **모든 앱 함께 삭제**를 체크한다(선택 항목이 앱마다 적용).
3. 네임스페이스에 볼륨(PVC)이 있으면 **DB 데이터** 체크 없이는 멈춘다. 필요한 데이터는 먼저 백업한다.
4. **미리보기**로 대상 확인 → 사유·업체 ID 입력 → **삭제**.

| 대상 | 기본 |
| --- | --- |
| Argo CD 프로젝트·저장소 인증 정보, 네임스페이스, Jenkins 폴더, Keycloak 그룹 `cicd-<업체>`, 품질 관리 항목 | 삭제 |
| 계정 (Keycloak·SCM-Manager·scm 목록): CI 계정 `jenkins-<업체>`, 업체 구성원, "추가로 삭제할 계정" | **보관** — **계정 삭제** 체크 시 삭제 |
| Harbor 프로젝트 | **보관** (robot만 비활성화) |
| 저장소: SCM `<업체>-*` 전체(gitops, 앱 소스, 전에 지운 앱의 남은 저장소) / GitLab 그룹 | **보관** |

**계정 삭제 규칙** — 다음 계정은 체크해도 지우지 않고 미리보기에 `keep`으로 표시한다.
- 운영 관리자(`cicd-admins`), `admin`, `scmadmin`
- 다른 그룹(다른 업체 `cicd-*`, K-PaaS 그룹)에도 속한 계정
- 기존 계정을 CI 계정으로 지정한 경우(예: `SCM_CI_USER=saeoll`)

K-PaaS 포털 등 다른 곳에서도 쓰는 계정인지 미리보기로 확인하고 실행한다.

**SCM 저장소가 지워지지 않을 때** — SCM-Manager는 열어 둔 git 파일이 NFS에 남아 있으면 저장소를 못 지운다
(`could not delete file .../objects/pack`). **SCM-Manager 재시작 허용**을 체크하면 한 번 재시작(약 1분간 모든 업체 git 접속 중단)하고 다시 지운다.
체크하지 않으면 작업이 **수동 대기**(종료 코드 3)로 끝나고 남은 저장소를 알려 준다.

**삭제가 중간에 멈췄다면** — 메뉴 **작업 이력 → 남은 업체 정리**에서 업체 ID로 남은 네임스페이스·Jenkins 폴더·그룹·저장소·계정을 정리한다
(Argo CD 프로젝트가 이미 지워져 업체 화면이 없을 때). 그룹이 이미 지워졌으면 구성원 계정은 **추가로 삭제할 계정**에 적는다.

NFS 등 `Retain` StorageClass를 쓰면 네임스페이스를 지워도 PV가 남는다 → `kubectl get pv`로 확인 후 정리.

명령으로 실행할 때(마스터 노드): 아래처럼 `--yes` 없이 실행하면 미리보기만 한다.

```bash
./remove-app.sh --delete-data saeoll homepage
```

---

## 14. 자동 확장 (HPA)

동시 접속자가 늘어 CPU 사용률이 오르면 Pod 수를 자동으로 늘리고, 줄면 다시 줄인다. 앱 화면 → 환경 패널 **자동 확장 → 설정** (관리자).

### 14-1. 먼저 확인

- **metrics-server:** `kubectl top pods -A`가 값을 보여야 한다. 안 되면 `cp-portal-deployment/script/install-metrics-server.sh`.
- **앱이 여러 Pod로 떠도 되는지:**
  - 로그인 세션을 Pod 메모리·로컬 파일에 두는 앱은 **세션 고정**을 켠다(근본 해결은 DB·Redis 세션).
  - 업로드 파일을 Pod 로컬 디스크에 저장하면 안 된다.
  - DB 커넥션 수(Pod 수 × 커넥션 풀)가 MariaDB `max_connections`(기본 151)를 넘지 않아야 한다.
  - 스케줄러처럼 한 곳에서만 돌아야 하는 작업이 중복 실행되지 않는지 확인한다.
- **업체 쿼터:** `최대 Pod × CPU 요청값`이 네임스페이스 쿼터(`requests.cpu`, 기본 4)를 넘으면 설정이 거절된다. 같은 업체의 다른 앱과 쿼터를 나눠 쓴다.

### 14-2. 설정 값 (기본)

| 항목 | 기본 | 설명 |
| --- | --- | --- |
| 최소 / 최대 Pod | 2 / 6 | 최소 2 이상이면 노드 점검 때도 1개는 남도록 PodDisruptionBudget을 같이 만든다 |
| CPU 목표 사용률 | 70% | Pod 평균 CPU가 **요청값의** 70%를 넘으면 늘린다 |
| 메모리 목표 | 0 (사용 안 함) | 메모리는 부하가 줄어도 잘 내려가지 않아 보통 쓰지 않는다 |
| Pod당 CPU 요청값 | 200m | 사용률의 기준. 기본 배포값 50m은 너무 작아 바로 최대치로 늘어나므로 부하 테스트로 정한다 |
| 세션 고정 | 끔 | Ingress sticky cookie (`cicd-route`) |

**확장 속도:** 늘릴 때는 1분에 최대 2개씩 바로 늘린다. 줄일 때는 5분 동안 지켜본 뒤 2분에 1개씩 줄인다.

### 14-3. 동작

- `scale-app.sh`가 gitops `apps/<앱>/overlays/<환경>/`에 기록한다.
  - `autoscale.yaml`: HPA와 PDB
  - `kustomization.yaml`: 고정 replicas 제거, CPU 요청값, 노드 분산, 세션 고정 patch
- **dev**는 Argo CD가 자동 반영하고, **prod**는 **prod Sync**로 반영한다(다른 prod 변경과 같음).
- 처음 반영할 때 Deployment가 잠깐 1개가 됐다가 HPA가 바로 최소값으로 올린다.
- 상태 표시:
  - 앱 화면: 현재 Pod 수, CPU 사용률, `최대 도달`
  - 대시보드·업체 화면: `×N` 배지, 대시보드에 "자동 확장 최대 도달" 숫자
- **최대 도달**이 자주 보이면 최대 Pod 수나 업체 쿼터를 늘리거나, 앱 성능을 점검한다.
- **서비스 중지**하면 HPA도 멈추고(Pod 0), **재개**하면 최소 Pod 수로 시작한다.
- **자동 확장 끄기**: 켜기 전의 고정 Pod 수로 돌아간다(prod는 prod Sync 후).

### 14-4. 부하 테스트 예

```bash
hey -z 3m -c 50 https://<앱>-<업체>-dev.<도메인>/
```

```bash
kubectl -n <네임스페이스> get hpa -w
```

1. dev에서 Pod 1개로 부하를 줘 평소 CPU를 보고 요청값을 정한다.
2. 자동 확장을 켜고 같은 부하로 Pod가 늘었다가, 부하를 멈추고 5분쯤 뒤 줄어드는지 확인한다.
3. 확장된 상태에서 로그인 유지와 업로드를 확인한다.
