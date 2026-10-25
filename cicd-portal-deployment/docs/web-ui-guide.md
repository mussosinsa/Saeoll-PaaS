# Jenkins · Argo CD 웹 화면 사용 가이드 (초보자용)

CI/CD 포털의 **Jenkins**(빌드)와 **Argo CD**(배포) 웹 화면을 처음 쓰는 사람을 위한 안내다.
예시는 업체 `saeoll`, 앱 `php-service`, 도메인 `192.168.20.151.nip.io` 기준이다.

```text
소스 push ──▶ Jenkins: 빌드·테스트·이미지 생성 ──▶ Harbor: 이미지 보관
                         │ gitops 저장소의 "배포할 버전" 변경
                         ▼
              Argo CD: 바뀐 버전을 쿠버네티스에 배포 ──▶ 서비스 화면
```

| 시스템 | 한 줄 설명 | 주소 |
| --- | --- | --- |
| Jenkins | 소스를 **빌드**해서 이미지를 만드는 곳 | `https://jenkins.<도메인>` |
| Argo CD | 만든 이미지를 **배포**하고 상태를 보여 주는 곳 | `https://argocd.<도메인>` |

두 화면 모두 **K-PaaS 계정(Keycloak)** 으로 로그인한다. 업체 계정은 자기 업체 것만 보인다.

> 브라우저 주소창의 "주의 요함"은 사내(사설) 인증서 때문이며 사용에는 문제없다.

---

# 1부. Jenkins

## 1. 로그인

1. `https://jenkins.<도메인>` 접속 → 자동으로 K-PaaS 로그인 화면(Keycloak)으로 이동
2. K-PaaS 아이디·비밀번호 입력 → Jenkins 첫 화면(대시보드)으로 돌아옴
3. 로그아웃: 오른쪽 위 사람 아이콘 → **로그아웃** (K-PaaS 로그인도 함께 종료)

| 계정 | 보이는 것 |
| --- | --- |
| 업체 (`cicd-saeoll` 그룹) | 대시보드에 **`saeoll` 폴더만**. 빌드 실행·로그 보기 가능, 설정 변경 불가 |
| 운영 관리자 (`cicd-admins`) | 모든 폴더 + 톱니바퀴(Jenkins 관리) 메뉴 |

**내 권한 확인**: 주소창에 `https://jenkins.<도메인>/whoAmI/` → **Authorities**에 `cicd-saeoll`(업체) 또는
`cicd-admins`(관리자)가 있어야 한다. 없으면 관리자에게 그룹 등록을 요청하고, 등록 후 **로그아웃 → 다시 로그인**한다.

## 2. 화면 구성

```text
┌ Jenkins / saeoll / php-service-dev ─────────────── 🔍  ⚙(관리자만)  👤 ┐
│ 왼쪽 메뉴              │ 가운데                                         │
│  Status               │  잡 이름, 설명                                  │
│  Changes              │  Stage View (단계별 결과 표)                     │
│  Build Now ▷          │  Permalinks (마지막 성공/실패 빌드 링크)          │
│  Polling Log          │                                                │
│ ─ Builds (빌드 이력) ─ │                                                │
│  #4 ✔  #3 ✘  ...      │                                                │
└────────────────────────────────────────────────────────────────────────┘
```

| 용어 | 뜻 |
| --- | --- |
| 폴더 | 업체 단위 묶음 (`saeoll`) |
| 잡(Job, 프로젝트) | 빌드 작업 하나. 앱마다 2개: `<앱>-dev`, `<앱>-release` |
| 빌드(#번호) | 잡을 한 번 실행한 기록. `#4 dev dev-e8ad2d85-4` = 4번째 빌드, dev용, 이미지 태그 |
| Stage | 빌드 안의 단계: Checkout → Build → Test → Image → Deploy |

### 상태 아이콘

| 아이콘 | 뜻 |
| --- | --- |
| ✔ 초록 체크 | 마지막 빌드 성공 |
| ✘ 빨강 | 마지막 빌드 실패 |
| ⋯ 회색 | 아직 한 번도 실행 안 함 (`release` 잡은 처음엔 이 상태) |
| 깜빡임 / 진행 막대 | 빌드 중 |
| ☀ / ☁ / ⛈ (날씨) | 최근 5번 빌드의 성공률 (맑을수록 좋음) |

## 3. 두 개의 잡

| 잡 | 언제 실행 | 무엇을 | 결과 |
| --- | --- | --- | --- |
| `php-service-dev` | `develop` 브랜치에 push하면 **5분 안에 자동** (또는 Build Now) | develop 소스 빌드 → 이미지 `dev-<커밋>-<번호>` | **dev 환경 자동 배포** |
| `php-service-release` | **사람이 직접** 태그를 입력해 실행 | 태그(`v1.0.0`) 소스 빌드 → 이미지 `v1.0.0` | 운영 배포 준비 (관리자가 Argo CD에서 승인) |

## 4. 자주 하는 작업

### 4-1. dev 빌드 바로 실행 (Build Now)

push 후 5분을 기다리기 싫거나 다시 빌드하고 싶을 때.

1. 대시보드 → `saeoll` 폴더 → `php-service-dev`
2. 왼쪽 **Build Now** 클릭 (또는 목록에서 줄 끝의 ▷ 버튼)
3. 왼쪽 아래 **Builds**에 새 번호가 생기고 진행 막대가 움직인다

> 빌드는 실행될 때마다 임시 빌드용 Pod를 만들기 때문에 시작까지 **30초~1분** 걸린다.
> 그동안 "빌드 대기 목록"에 `Waiting for next available executor`가 보이는 것은 정상이다.

### 4-2. 빌드 진행·결과 보기

**방법 1: Stage View (단계별 표)** — 잡 화면 가운데

| 칸 색 | 뜻 |
| --- | --- |
| 초록 | 그 단계 성공 |
| 빨강 | 그 단계에서 실패 → 그 칸에 마우스를 올리고 **Logs**로 해당 단계 로그만 보기 |
| 파랑 줄무늬 | 진행 중 |

**방법 2: Console Output (전체 로그)** — 가장 정확하다

1. 왼쪽 **Builds**에서 빌드 번호(예: `#4`) 클릭
2. 왼쪽 **Console Output**
3. 맨 아래로 내려 결과 확인

| 맨 아래 문구 | 뜻 |
| --- | --- |
| `Finished: SUCCESS` | 성공 |
| `Finished: FAILURE` | 실패 → 바로 위 `ERROR`·`error` 줄이 원인 |
| `Finished: ABORTED` | 누군가 중지함 |

성공 시 끝부분에서 꼭 확인할 두 줄:
```text
Pushed harbor.192.168.20.151.nip.io/saeoll/php-service:dev-e8ad2d85-4      ← 이미지가 Harbor에 올라감
gitops apps/php-service/overlays/dev/kustomization.yaml -> dev-e8ad2d85-4  ← 배포 버전이 바뀜(Argo CD가 반영)
```

빌드가 진행 중일 때 Console Output을 열면 로그가 실시간으로 늘어난다.

### 4-3. 운영용 빌드 (release, 태그 입력)

먼저 소스에 태그가 있어야 한다(개발자가 `git tag -a v1.0.0 ... && git push origin main --follow-tags`).

1. `saeoll` → `php-service-release`
2. 왼쪽 **Build with Parameters**
3. `RELEASE_TAG` 칸에 `v1.0.0` 입력 → **Build**
4. 성공하면 Harbor에 `v1.0.0` 이미지가 생기고, 운영 배포 버전이 `v1.0.0`으로 바뀐다
5. 운영 관리자에게 배포 요청 → 관리자가 Argo CD에서 SYNC ([2부 4-4](#4-4-운영-배포-승인-sync-관리자))

| 실패 메시지 | 원인 |
| --- | --- |
| `RELEASE_TAG must look like v1.2.0` | 형식 오류. `v숫자.숫자.숫자`로 입력 |
| `Couldn't find any revision to build` | 태그를 push하지 않음 (`git push origin v1.0.0`) |

### 4-4. 빌드 중지

진행 중인 빌드 화면 → 왼쪽 **Abort**, 또는 진행 막대 옆 ✖ 버튼.

### 4-5. 같은 소스로 다시 실행 / 조금 고쳐서 실행

| 메뉴 (빌드 번호 화면) | 용도 |
| --- | --- |
| 잡 화면 **Build Now** | 최신 소스로 다시 빌드 |
| **Replay** | 그 빌드의 Jenkinsfile을 화면에서 잠깐 고쳐 다시 실행(시험용, 저장소에는 반영 안 됨) |

### 4-6. 자동 빌드가 안 될 때 확인 (Polling Log)

`php-service-dev` → 왼쪽 **Polling Log**

| 내용 | 뜻 |
| --- | --- |
| `Changes found` | 변경을 찾아 빌드를 시작함 |
| `No changes` | develop 브랜치에 새 커밋이 없음 → **master/main에 push하지 않았는지** 확인 |
| 오류(401·403 등) | 저장소 접근 문제 → 관리자에게 문의 |

### 4-7. 이전 빌드에서 바뀐 소스 보기

빌드 번호 → **Changes**: 그 빌드에 포함된 커밋 메시지·작성자·파일 목록.

## 5. 실패했을 때 보는 순서

1. Stage View에서 **빨간 칸이 어느 단계**인지 본다
2. Console Output 맨 아래 → 위로 올라가며 첫 `ERROR`/`error`/`fatal` 줄을 찾는다
3. 아래 표에서 찾고, 없으면 **마지막 40줄을 복사**해 관리자에게 전달

| 단계 | 흔한 원인 |
| --- | --- |
| Checkout | 저장소 접근 권한, 태그 없음 |
| Build | 문법 오류, 의존성(composer/npm/gradle) 다운로드 실패 |
| Test | 테스트 실패 (로그의 실패한 테스트 이름 확인) |
| Image | Dockerfile 오류, 베이스 이미지 없음, Harbor 인증 (`UNAUTHORIZED`) |
| Deploy | gitops 저장소 쓰기 권한, 앱 매니페스트 없음 |

> `fatal: detected dubious ownership` 경고는 빌드 결과와 무관하다(새 Jenkinsfile에서는 나오지 않음).

## 6. (관리자) 알아 두면 좋은 메뉴

| 메뉴 | 위치 | 용도 |
| --- | --- | --- |
| Jenkins 관리 | 오른쪽 위 ⚙ | 플러그인, 보안, 노드, 시스템 로그 |
| Security | Jenkins 관리 → Security | Authorization이 **Project-based Matrix Authorization Strategy**인지 확인 |
| Credentials | 폴더 → 왼쪽 Credentials | `saeoll-harbor`, `saeoll-scm` (스크립트가 관리, 직접 수정하지 않음) |
| 잡 권한 | 잡 → Configure → Enable project-based security | release 잡을 관리자 전용으로 제한할 때 |
| Nodes | Jenkins 관리 → Nodes | `Built-In Node`만 보이는 것이 정상(빌드 Pod는 빌드할 때만 잠깐 나타남) |
| API 토큰 | 👤 → Security → API Token | 스크립트용 토큰 발급 |

> Jenkins 설정은 스크립트(JCasC)로 관리된다. 화면에서 Security 등 전역 설정을 바꿔도
> `./deploy-cicd-portal.sh jenkins` 실행 시 원래대로 돌아간다. 영구 변경은 관리자에게 요청한다.

---

# 2부. Argo CD

## 1. 로그인

1. `https://argocd.<도메인>` 접속
2. **LOG IN VIA K-PAAS SSO** 클릭 → K-PaaS 아이디·비밀번호
   (아래 Username/Password 칸은 관리자 비상 계정 `admin` 전용)
3. 로그아웃: 왼쪽 메뉴 **User Info** → **LOG OUT**, 또는 오른쪽 위 **Log out**

| 계정 | 할 수 있는 것 |
| --- | --- |
| 업체 (`cicd-saeoll`) | 자기 업체 앱 조회·로그 보기, **dev 앱 SYNC** |
| 운영 관리자 (`cicd-admins`) | 전체 + **prod 앱 SYNC(운영 배포 승인)**, 설정 변경 |

## 2. 앱 목록 화면 (Applications)

앱은 업체·서비스·환경마다 하나씩 있다: `saeoll-php-service-dev`, `saeoll-php-service-prod`.

```text
┌ saeoll-php-service-dev ──────────── ↗ ☆ ┐
│ Project:   saeoll                          │
│ Status:    ♥ Healthy   ✔ Synced           │ ← 가장 중요한 두 가지
│ Repository: ...scm/git/saeoll-gitops       │ ← 배포 설정 저장소
│ Path:      apps/php-service/overlays/dev   │
│ Namespace: saeoll-dev                      │ ← 배포되는 곳
│ Last Sync: 10/24/2026 23:55:02             │ ← 마지막 배포 시각
│ [SYNC] [⟳] [✖]                            │
└────────────────────────────────────────────┘
```

| 버튼 | 뜻 |
| --- | --- |
| ↗ | 서비스 주소 열기 (Ingress가 있을 때) |
| SYNC | 지금 배포 (gitops 내용을 클러스터에 적용) |
| ⟳ (REFRESH) | gitops 저장소를 지금 다시 읽기 (평소엔 3분마다 자동) |
| ✖ | **앱 삭제 — 누르지 않는다** (관리자만 가능, 서비스가 내려감) |

위쪽 **REFRESH APPS**는 모든 앱을 한꺼번에 새로 읽는다. 왼쪽 필터(SYNC STATUS, HEALTH STATUS, Labels)로 앱을 걸러 볼 수 있다.
오른쪽 위 아이콘으로 카드형/목록형/요약 보기를 바꿀 수 있다.

## 3. 상태 읽는 법

상태는 두 가지를 따로 본다.

**Sync 상태 — "gitops에 적힌 대로 배포되어 있나?"**

| 표시 | 뜻 |
| --- | --- |
| ✔ **Synced** | gitops와 클러스터가 같음 |
| ↑ **OutOfSync** (노랑) | gitops가 바뀌었는데 아직 배포 안 함. prod는 관리자가 SYNC해야 함 |
| Unknown | gitops 저장소를 읽지 못함 (저장소 접근 문제) |

**Health 상태 — "서비스가 정상 동작하나?"**

| 표시 | 뜻 | 할 일 |
| --- | --- | --- |
| ♥ **Healthy** (초록) | 정상 | - |
| ◔ **Progressing** (파랑) | 배포 중 (새 Pod 기동 중) | 1~2분 기다림 |
| 💔 **Degraded** (빨강) | 실패 (Pod가 안 뜸) | [5장](#5-문제가-있을-때) |
| **Missing** (노랑) | 아직 한 번도 배포 안 됨 | prod는 운영 배포 전이면 정상 |
| Suspended | 일시 중지 | 관리자 문의 |

| 앱 | 정상적인 모습 |
| --- | --- |
| dev | Healthy + Synced (빌드 후 자동으로 이렇게 됨) |
| prod (운영 배포 전) | Missing + OutOfSync |
| prod (운영 배포 후) | Healthy + Synced |
| prod (새 release 빌드 후, 승인 전) | Healthy + **OutOfSync** = 승인 대기 |

## 4. 자주 하는 작업

### 4-1. 앱 상세 화면 보기

카드의 앱 이름 클릭 → 리소스 지도(트리)가 나온다.

```text
saeoll-php-service-dev ─┬─ svc  php-service            (서비스 주소)
                        ├─ deploy php-service ── rs ── pod php-service-xxxx  (실제 실행 중인 컨테이너)
                        └─ ing  php-service            (외부 접속 주소)
```

- 각 상자의 하트/색이 그 리소스의 상태다. **pod** 상자가 가장 중요하다.
- 위쪽 버튼: **APP DETAILS**(설정), **APP DIFF**(무엇이 바뀌는지), **SYNC**, **SYNC STATUS**, **HISTORY AND ROLLBACK**, **REFRESH**
- 오른쪽 위 보기 전환: 트리 / Pod 중심 / 네트워크 / 목록

### 4-2. 지금 어떤 버전이 배포되어 있나

- 목록 화면에서 앱 카드 → 이름 클릭 → **pod** 상자 클릭 → **SUMMARY** 탭의 **IMAGES**
  예: `harbor.192.168.20.151.nip.io/saeoll/php-service:dev-e8ad2d85-4`
- 또는 **APP DETAILS** → **SUMMARY**의 Images 항목

Jenkins 빌드 이름(`#4 dev dev-e8ad2d85-4`)의 태그와 같으면 그 빌드가 배포된 것이다.

### 4-3. 로그·이벤트 보기 (문제 확인)

앱 상세 → **pod** 상자 클릭 → 위쪽 탭

| 탭 | 내용 |
| --- | --- |
| SUMMARY | 이미지, 상태, 재시작 횟수 |
| **EVENTS** | 쿠버네티스 이벤트 (이미지 받기 실패 등) — 배포 실패 원인은 대부분 여기 |
| **LOGS** | 앱 출력 로그 (PHP 오류, Apache 로그 등). **Follow**로 실시간 보기 |
| MANIFEST | 실제 적용된 YAML |

### 4-4. 운영 배포 승인 (SYNC, 관리자)

전제: Jenkins `php-service-release`가 `RELEASE_TAG=v1.0.0`으로 **성공**한 상태.

1. `cicd-admins` 계정으로 로그인
2. `saeoll-php-service-prod` 카드 → **⟳ REFRESH** (최신 gitops 읽기) → 상태가 **OutOfSync**인지 확인
3. 앱 이름 클릭 → **APP DIFF** → 바뀌는 내용이 `image: ...:v1.0.0` 한 줄인지 확인 (다른 변경이 있으면 업체에 확인)
4. **SYNC** → 오른쪽에 창이 열림
   - Revision: `main` 그대로
   - PRUNE, DRY RUN, FORCE 등 체크박스: **모두 해제(기본값)**
   - SYNCHRONIZE RESOURCES: 전부 체크된 그대로
5. 맨 위 **SYNCHRONIZE** 클릭
6. Progressing → **Healthy / Synced** 확인 → 서비스 주소 `https://php-service-saeoll.<도메인>` 확인

> 업체 계정으로 prod를 SYNC하면 `permission denied: applications, sync, saeoll/...-prod`가 나온다. 정상(관리자 전용)이다.

### 4-5. dev 수동 재배포 (업체도 가능)

평소엔 자동이다. Pod가 이상할 때 다시 맞추고 싶으면 `saeoll-php-service-dev` → **SYNC** → **SYNCHRONIZE**.
Pod만 다시 띄우려면 앱 상세 → **deploy** 상자의 ⋮ → **Restart**.

### 4-6. 롤백 (이전 버전으로 되돌리기, 관리자)

1. 앱 상세 → **HISTORY AND ROLLBACK**
2. 배포 이력(시각, 리비전)에서 되돌릴 항목의 ⋮ → **Rollback** → OK
3. 롤백 후 앱은 OutOfSync로 보인다(gitops에는 새 버전이 적혀 있으므로). 다음 SYNC 때 다시 새 버전이 배포되지 않도록
   gitops `overlays/prod/kustomization.yaml`의 `newTag`도 이전 값으로 되돌린다(또는 이전 태그로 release를 다시 빌드).

> 자동 Sync(dev, 또는 자동으로 바꾼 prod)에서는 Rollback 메뉴를 쓸 수 없다. 이전 커밋/태그로 다시 빌드한다.

### 4-7. 운영도 자동 배포로 바꾸기 / 되돌리기 (관리자)

앱 → **APP DETAILS** → **SYNC POLICY**

| 버튼 | 결과 |
| --- | --- |
| ENABLE AUTO-SYNC (+ PRUNE RESOURCES, SELF HEAL 켬) | release 빌드가 끝나면 3분 안에 운영 자동 배포 |
| DISABLE AUTO-SYNC | 다시 관리자 SYNC 승인 방식 |

자동으로 바꾸면 release 잡을 관리자만 실행하도록 Jenkins 잡 권한도 함께 제한한다([설치 가이드 10-3](install-guide.md#10-3-선택-운영도-자동-배포로--소스-수정-없이)).

## 5. 문제가 있을 때

| 화면 | 확인 | 원인 / 조치 |
| --- | --- | --- |
| dev **Degraded**, pod EVENTS에 `...:none-yet ... not found` | Jenkins `<앱>-dev`에 성공 빌드가 있나 | 아직 첫 빌드 전/실패 → Jenkins 빌드를 성공시키면 자동 해결 |
| Jenkins는 성공했는데 그대로 | Last Sync 시각 | ⟳ REFRESH, 안 되면 카드 ⋮(또는 REFRESH 옆 ▾) → **Hard Refresh** |
| EVENTS에 `401 Unauthorized` / `pull access denied` | - | 이미지 받기 인증 문제 → 관리자 (`onboard-vendor.sh` 재실행) |
| pod 재시작 반복 (`CrashLoopBackOff`) | pod **LOGS** | 앱 오류, 8080 포트, 헬스 체크(`/healthz.php`) 응답 확인 |
| `OOMKilled` | pod SUMMARY | 메모리 부족 (기본 512Mi) → 관리자에게 상향 요청 |
| Sync 실패 `exceeded quota` | - | 업체 자원 한도 초과 → 관리자 |
| Sync 상태 **Unknown**, 오류 `repository not accessible` | APP CONDITIONS | gitops 저장소 접근 문제 → 관리자 |
| prod SYNC `permission denied` | 로그인 계정 | 업체 계정은 prod 불가(정상). 관리자에게 요청 |

---

## 부록. 하루 작업 흐름 예시

| 순서 | 누가 | 어디서 | 무엇을 |
| --- | --- | --- | --- |
| 1 | 개발자 | PC | `develop`에 push |
| 2 | 개발자 | Jenkins `php-service-dev` | 5분 내 빌드 시작 확인 → Stage View 전부 초록 |
| 3 | 개발자 | Argo CD `...-dev` | Healthy / Synced, 이미지 태그가 방금 빌드와 같은지 |
| 4 | 개발자 | dev 주소 | 기능 확인 |
| 5 | 업체 PM | PC | `main` 머지 + 태그 `v1.0.1` push |
| 6 | 업체 PM | Jenkins `php-service-release` | Build with Parameters `v1.0.1` → 성공 |
| 7 | 업체 PM | (메일·메신저) | 운영 배포 요청: 앱, 태그, 빌드 번호, 변경 내용 |
| 8 | 운영 관리자 | Argo CD `...-prod` | REFRESH → APP DIFF 확인 → SYNC → Healthy |
| 9 | 운영 관리자 | 운영 주소 | 확인 후 완료 통보 |
