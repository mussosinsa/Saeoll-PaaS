# 보안 검사 · 품질 관리 가이드

CI/CD 포털 파이프라인에 **보안 검사 영역**을 추가하고, CI/CD 콘솔의 **품질 관리** 메뉴로 결과·규칙·정책·예외를 관리한다.
`ap-pipeline-ui`의 품질 메뉴(품질 이슈, 코딩 규칙, 품질 프로파일, 품질 게이트)를 보안 검사 기준으로 옮긴 것이다.

```text
Git push ─▶ Jenkins / GitLab CI
             Checkout → Build → Test → [Security: Semgrep · Gitleaks · Trivy(의존성) · 개인정보(+Presidio)]
                                     → Image → [Security Gate: Trivy(이미지) + 정책 판정] ─┬─ 통과/경고 → Deploy → Argo CD
                                                                                          └─ 차단 → 배포 중단 + 보고서
             보고서 security/summary.json (빌드 결과물) ─▶ 콘솔 품질 관리, (선택) DefectDojo
```

| ap-pipeline-ui | 콘솔 품질 관리 | 내용 |
| --- | --- | --- |
| 품질 이슈 | **보안 이슈** | 앱별 최근 develop·릴리스 빌드의 게이트 결과와 발견 사항, 필터, 예외 요청 |
| 코딩 규칙 | **검사 규칙** | Semgrep 규칙, Gitleaks 규칙, 개인정보 패턴, Trivy DB 설정 (조회) |
| 품질 프로파일 | **검사 프로파일** | 어떤 도구·규칙 묶음으로 검사할지, 앱별 지정 |
| 품질 게이트 | **보안 게이트** | 환경별 경고/차단 모드와 허용 건수 |
| — | **예외 관리** | 오탐·조치 예정 항목을 기간을 정해 게이트에서 제외 (요청 → 승인) |

## 1. 단계별 도입

| 단계 | 내용 | 하는 일 |
| --- | --- | --- |
| 1 | 파이프라인 보안 검사 (경고 모드) | 2장 설치, 기존 앱 Jenkinsfile 교체 |
| 2 | 콘솔 품질 관리 조회, prod Sync 확인 | `./deploy-cicd-portal.sh console` 재실행 |
| 3 | 차단 모드 전환, 게이트·프로파일 수정, 예외 승인 | 콘솔 품질 관리 (운영 관리자) |
| 4 | Presidio(개인정보 문맥 탐지), DefectDojo 연동 (선택) | 6장 |

처음 2~4주는 **경고 모드**로 운영하며 오탐을 예외로 정리하고, prod부터 **차단 모드**로 바꾸는 것을 권장한다.

## 2. 설치 (운영 관리자, 관리 노드)

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script
git pull
./deploy-cicd-portal.sh security-image      # 검사 이미지 빌드 → Harbor cicd-portal/security-scanner:<태그>
./deploy-cicd-portal.sh security            # 정책·규칙 ConfigMap, pull secret, Harbor 자동 스캔, GitLab 템플릿·Runner
./deploy-cicd-portal.sh console-image console   # 콘솔에 품질 관리 메뉴 반영 (콘솔 사용 시)
./check-cicd-portal.sh                      # 4c. Security scan 항목 확인
```

| 생성물 | 위치 |
| --- | --- |
| 검사 이미지 | Harbor `cicd-portal/security-scanner:<SECURITY_IMAGE_TAG>` (Semgrep, Gitleaks, Trivy + 취약점 DB, cicd-scan) |
| 정책 | ConfigMap `cicd-security-policy` (`cicd-jenkins`, `cicd-runner`) — 콘솔에서 수정, 재실행해도 유지 |
| 규칙 | ConfigMap `cicd-security-rules` — 저장소 `security/rules`에서 매번 갱신 |
| 이미지 pull | Secret `cicd-security-pull` (Harbor robot `cicd-portal+security`) |
| Harbor | 업체 프로젝트마다 "푸시 시 자동 스캔" 켬 (`SECURITY_HARBOR_PREVENT=critical`이면 취약 이미지 pull 차단) |
| GitLab | 인스턴스 변수 `CICD_SECURITY_IMAGE`, 템플릿 `security` 잡, Runner의 ConfigMap 마운트 |

설정 변수는 `script/cicd-vars.sh`의 `SECURITY_*`이다.

| 변수 | 설명 |
| --- | --- |
| `SECURITY_IMAGE_TAG` | 검사 이미지 태그. 규칙·도구를 바꾸면 올리고 `security-image security` 재실행 |
| `SECURITY_TRIVY_DB_REPOSITORY`, `SECURITY_TRIVY_JAVA_DB_REPOSITORY` | 폐쇄망: Trivy DB OCI 미러(Harbor). 비우면 ghcr.io |
| `SECURITY_GITLEAKS_IMAGE`, `SECURITY_TRIVY_IMAGE`, `SECURITY_BASE_IMAGE` | 폐쇄망: Harbor 미러 주소 |
| `SECURITY_HARBOR_PREVENT` | 비움(기본) / `critical` 등: Harbor가 해당 심각도 이상 이미지 pull 거부 (운영 Pod 재시작도 막힘 → 검토 후 사용) |
| `SECURITY_PRESIDIO` | `true`: Presidio 배포 (6장) |

**취약점 DB 갱신**: 파이프라인은 실행할 때 DB를 받고, 받지 못하면(폐쇄망) 이미지에 들어 있는 DB를 쓴다.
폐쇄망에서는 **주 1회 정도 `security-image`를 다시 실행**해 DB를 갱신한다.

### 2-1. 기존 앱에 적용

- **GitLab 업체**: 템플릿이 갱신되므로 다음 파이프라인부터 `security` 잡이 실행된다.
- **SCM(Jenkins) 업체**: Jenkinsfile이 앱 저장소에 있으므로 교체가 필요하다.
  콘솔 앱 추가 화면에서 같은 앱 ID로 **'기존 CI 파일(Jenkinsfile)을 포털 버전으로 교체'**를 켜고 실행한다
  (`REPLACE_CI=1 ./add-app.sh <업체> <앱> <유형>`). 업체가 Jenkinsfile을 고쳐 쓰고 있었다면 변경 내용을 다시 반영해야 하므로 미리 알린다.
- 새로 추가하는 앱은 보안 단계가 처음부터 들어간다.

## 3. 검사 내용

| 도구 | 대상 | 심각도 | 게이트 집계 |
| --- | --- | --- | --- |
| Semgrep | 소스 코드: SQL·명령 주입, eval, XSS, 역직렬화, 약한 해시, TLS 검증 해제, 하드코딩 비밀번호 | 규칙별 Critical~Low | Critical/High/Medium |
| Gitleaks | 소스 파일의 비밀정보: 클라우드 키, 토큰, 개인 키, DB 비밀번호, Harbor robot | Critical | 비밀정보 |
| Trivy 의존성 | lock 파일(composer.lock, package-lock.json, pom.xml, gradle 등)의 CVE | DB 값 | Critical/High/Medium |
| 개인정보 | 주민·외국인등록번호(검증번호), 카드번호(Luhn), 운전면허, 여권·계좌(문맥), 휴대전화 | High/Medium | 개인정보(High 이상) |
| Trivy 이미지 | Harbor에 올라간 이미지의 OS 패키지·라이브러리 CVE, 이미지 안의 비밀정보 | DB 값 | Critical/High/Medium, 비밀정보 |
| Presidio (선택) | 개인정보 + 문맥 점수, 이메일·카드·IP 등 | 패턴별 | 개인정보 |

- `vendor/`, `node_modules/`, `build/`, `target/`, `dist/` 등은 검사하지 않는다. Semgrep은 기본으로 `test/`·`tests/` 폴더도 제외한다.
- 보고서에는 비밀정보·개인정보가 **가려진 값**(`90**********67`)으로만 남는다.
- 결과: Jenkins 빌드 → **Build Artifacts → security/**, GitLab 파이프라인 → `security` 잡 → **Job artifacts**, 콘솔 → 빌드 이력의 **보안**.

### 게이트 판정

| 결과 | 조건 | 파이프라인 | 콘솔 |
| --- | --- | --- | --- |
| 통과 | 허용 건수 이내 | 배포 | 통과 |
| 경고 | 초과 + **경고 모드** | 배포, Jenkins 빌드 **불안정**(노란색) / GitLab **경고와 함께 통과** | 경고 |
| 차단 | 초과 + **차단 모드** | **Deploy 단계 생략** (이미지는 Harbor에 올라가지만 배포되지 않음) | 차단 |

prod는 추가로 **콘솔 prod Sync 확인**이 있다(보안 게이트의 "콘솔 prod Sync 차단"). 최근 릴리스 빌드가 통과하지 않았거나 결과가 없으면
운영 관리자가 **배포 사유**를 입력해야 Sync된다. 사유는 콘솔 로그(`audit ... security-override`)와 Argo CD 작업 정보에 남는다.
업체가 Jenkinsfile에서 보안 단계를 지워도 이 확인은 피할 수 없다.

## 4. 콘솔 품질 관리 사용법

메뉴 **품질 관리** (모든 사용자 조회, 수정은 운영 관리자).

### 4-1. 보안 이슈

1. **범위**를 '최근 develop 빌드' 또는 '최근 릴리스 빌드'로 고른다.
2. **애플리케이션별 결과**에서 게이트와 건수, 위반 내용(`high 4/0` = 4건, 허용 0건)을 본다. **보고서**는 빌드 하나의 상세다.
3. **발견 사항**을 심각도·분류로 거른다. 조치 방법은 '내용' 열에 나온다. CVE는 ↗ 링크로 상세를 본다.

### 4-2. 예외 관리

| 누가 | 방법 |
| --- | --- |
| 업체 구성원 | 발견 사항의 **예외 요청** → 사유(10자 이상)·만료일(최대 1년) → 요청 |
| 운영 관리자 | **예외 관리**에서 요청을 **승인/반려**(의견 입력 가능), 또는 직접 등록(바로 승인) |

- 승인된 예외는 **다음 빌드부터** 게이트에서 빠지고 보고서의 '예외 처리된 항목'에 표시된다.
- **지문(fingerprint)**을 켜 두면 그 항목 하나만, 끄면 규칙·경로 패턴(`src/test/*`)이 맞는 모든 항목이 제외된다.
- 만료일이 지나면 다시 집계된다. 오탐이면 사유에 근거를, 실제 취약점이면 조치 계획과 기한을 적는다.

### 4-3. 보안 게이트 (운영 관리자)

환경(dev·prod·기타 브랜치)마다 모드와 허용 건수(-1 = 제한 없음)를 정한다. 기본값:

| 환경 | 모드 | Critical | High | 비밀정보 | 개인정보 |
| --- | --- | --- | --- | --- | --- |
| dev | 경고 | 0 | 제한 없음 | 0 | 0 |
| prod | 경고 (+콘솔 prod Sync 확인) | 0 | 0 | 0 | 0 |

**차단 모드 전환 절차**: 보안 이슈에서 현재 위반을 확인 → 업체에 조치·예외 요청 안내 → 위반이 정리되면 prod를 '차단 모드'로 저장 →
업체에 공지. 저장은 다음 빌드부터 적용되며, 두 사람이 동시에 고치면 나중 저장이 거부된다(화면 새로 고침 후 다시 저장).

### 4-4. 검사 프로파일 (운영 관리자)

- 언어별 기본 프로파일(`php`, `java-gradle`, `java-maven`, `node`, `vue`)과 `default`가 있다.
- **프로파일 추가·수정**: 이름, 도구, Semgrep 규칙 묶음을 고르고 저장. 사용 중인 프로파일과 `default`는 지울 수 없다.
- **애플리케이션별 프로파일**: 특정 앱만 다른 프로파일(예: `php-strict`)을 쓰게 지정한다.

### 4-5. 검사 규칙

규칙은 저장소 `security/rules`에서 관리한다(콘솔은 조회만). 규칙을 바꾸면 커밋 후 `./deploy-cicd-portal.sh security`를 실행한다.
Semgrep 규칙을 추가할 때는 `metadata.cicd-severity`(critical|high|medium|low)와 한국어 `description`을 넣는다.

## 5. 업체 개발자 안내

- 빌드가 **불안정/경고**면 콘솔 앱 화면의 **보안 검사 → 보고서**를 열어 High 이상부터 고친다.
- 오탐이면 **예외 요청**을 하고 근거를 적는다. 승인 전까지는 계속 경고(차단 모드면 배포 중단)된다.
- 비밀정보가 발견되면 **값을 즉시 교체**(비밀번호·키 재발급)한다. 커밋에서 지워도 이력에는 남는다.
- 의존성 CVE는 '수정 버전'으로 올린다(`composer update <패키지>`, `npm update <패키지>`, Gradle/Maven 버전 변경).

## 6. Presidio · DefectDojo (4단계, 선택)

### 6-1. Presidio (개인정보 문맥 탐지)

```bash
SECURITY_PRESIDIO=true ./deploy-cicd-portal.sh security   # namespace cicd-security 에 presidio-analyzer 배포 (메모리 1~2Gi)
```

이후 콘솔 **검사 프로파일**에서 사용할 프로파일에 **Presidio**를 체크한다(같은 패턴을 두 번 세지 않도록 '개인정보'는 끈다).
cicd-scan은 한국 패턴을 Presidio의 ad-hoc 인식기로 보내 문맥 점수를 받고, 주민번호 검증번호·Luhn 검사를 다시 적용한다.
Presidio 기본 NLP 모델은 영어라 한국어 문맥 인식은 제한적이며, 이메일·카드·IP 등 기본 인식기가 추가되는 효과가 크다.
빌드 Pod가 접근할 수 있도록 Presidio Pod에는 `cp-role: shared` 라벨이 있다(K-PaaS 기본 NetworkPolicy).

### 6-2. DefectDojo (이력·지표 관리)

DefectDojo는 별도로 설치한다(공식 Helm chart). API v2 토큰을 만든 뒤:

```bash
DEFECTDOJO_URL=https://defectdojo.<도메인> DEFECTDOJO_TOKEN='<API 토큰>' ./deploy-cicd-portal.sh security
```

빌드마다 Semgrep·Gitleaks·Trivy 원본 보고서를 `reimport-scan`으로 보낸다(Product = 업체, Engagement = `<앱> <환경>`,
없으면 자동 생성). 전송 실패는 빌드를 실패시키지 않는다. DefectDojo가 K-PaaS CA 인증서를 쓰면 검사 이미지가 CA를 신뢰한다.

## 7. 삭제

```bash
./uninstall-cicd-portal.sh security
```

정책·규칙 ConfigMap, Presidio, DefectDojo 설정을 지운다. 이미 보안 단계가 들어간 Jenkinsfile은 검사 이미지에 들어 있는
기본 정책(경고 모드)으로 계속 검사한다. 단계를 없애려면 보안 설치 전 버전의 Jenkinsfile로 되돌린다.

## 8. 문제 해결

| 증상 | 원인 · 조치 |
| --- | --- |
| Jenkins 로그 `Security scan is not set up` | 보안 설치 전에 만든 Jenkinsfile → 2-1 Jenkinsfile 교체 |
| 빌드 Pod `ImagePullBackOff` (security 컨테이너) | 검사 이미지 미 push 또는 `cicd-security-pull` 없음 → `security-image security` 재실행 |
| 보고서 도구 상태 `실패` + `trivy ... download` | DB 다운로드 실패 → 이미지 DB 사용(메시지 'offline DB used'). 계속되면 `SECURITY_TRIVY_DB_REPOSITORY` 미러 지정 |
| Trivy 이미지 `UNAUTHORIZED` | 업체 Harbor robot 비밀번호 불일치 → 업체 등록을 CI 계정 git 비밀번호와 함께 재실행 |
| Semgrep `timed out` | 큰 저장소 → 빌드 Pod 메모리(security 컨테이너 2Gi) 확인, `CICD_SCAN_TIMEOUT` 증가 |
| 콘솔 보안 이슈가 '결과 없음' | 보안 단계 없는 Jenkinsfile, 빌드 실패로 검사 전 중단, GitLab 잡 결과물 만료(90일) |
| 콘솔 품질 관리 "설치되어 있지 않습니다" | `./deploy-cicd-portal.sh security` 후 `console` 재실행(ConfigMap 권한) |
| 오탐이 많음 | 해당 규칙을 예외(경로 패턴)로 정리하거나 프로파일에서 규칙 묶음을 조정, 규칙 수정은 저장소에서 |
