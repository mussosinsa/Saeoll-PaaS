# CI/CD 포털 처음 설치하기 — 기존 K-PaaS 환경 (초보자용)

**대상 환경**: `cp-portal-deployment`, `cp-source-control-deployment`, `cp-pipeline-deployment`가 이미 설치된 K-PaaS 클러스터.
여기에 `cicd-portal-deployment`(Jenkins + Argo CD + CI/CD 콘솔 + 보안 검사)를 **처음 설치하고 첫 서비스를 배포**하기까지를
순서대로 설명한다.

| 읽는 사람 | 볼 부분 |
| --- | --- |
| 운영 관리자 (설치·업체 등록·운영 배포 승인) | [1부 관리자](#1부-관리자) |
| 업체 개발자 (소스 개발·dev 배포·운영 배포 요청) | [2부 사용자](#2부-사용자-업체-개발자) |

예시 값: 도메인 `192.168.20.151.nip.io`, 업체 `saeoll`, 앱 `homepage`(PHP). 명령의 `<도메인>`은 자기 환경 값으로 바꾼다.
더 자세한 설명은 문서 끝 [참고 문서](#참고-문서)에 있다.

---

# 1부. 관리자

## 1. 무엇이 설치되나

**기존 K-PaaS 구성은 바꾸지 않는다.** 새 네임스페이스에 아래만 추가하고, Keycloak·Harbor·SCM은 기존 것을 함께 쓴다.

| 구분 | 이름 · 주소 | 비고 |
| --- | --- | --- |
| 기존 CP-Portal | `portal.<도메인>`, Keycloak `keycloak.<도메인>`, Harbor `harbor.<도메인>` | 로그인(SSO)·이미지 저장소를 같이 씀 |
| 기존 소스 컨트롤 | `scm.<도메인>` (SCM-Manager `scm-manager.<도메인>`) | 업체 소스 저장소로 그대로 씀 |
| 기존 파이프라인 | `pipeline.<도메인>` (namespace `cp-pipeline`) | **영향 없음**, 그대로 사용 가능 |
| **신규** Jenkins | `jenkins.<도메인>` (namespace `cicd-jenkins`) | 빌드 (Kubernetes Pod) |
| **신규** Argo CD | `argocd.<도메인>` (namespace `cicd-argocd`) | 배포 (GitOps) |
| **신규** CI/CD 콘솔 | `cicd.<도메인>` (namespace `cicd-console`) | 업체·앱·빌드·배포·품질 관리 웹 화면 |
| **신규** 보안 검사 | ConfigMap·이미지 (namespace `cicd-jenkins`) | Semgrep, Gitleaks, Trivy, 개인정보 |
| **신규** 업체 공간 | `<업체>-dev`, `<업체>-prod` | 업체를 등록할 때마다 생김 |

```text
개발자 ─push─▶ SCM(scm.)  ─5분 내─▶ Jenkins(jenkins.): 빌드·테스트·보안 검사·이미지 ─▶ Harbor
                                                 └─ gitops 저장소의 이미지 태그 변경 ─▶ Argo CD(argocd.)
                                                                     dev: 자동 배포 / prod: 관리자 승인 후 배포
운영 관리자·업체 ─▶ CI/CD 콘솔(cicd.): 업체 등록, 앱 추가, 빌드·배포 상태, 품질 관리
```

> 기존 파이프라인(`pipeline.`)과 새 포털은 따로 동작한다. 같은 SCM 저장소를 두 곳에서 동시에 빌드하지 않도록,
> 앱을 새 포털로 옮길 때는 기존 파이프라인의 해당 Job을 멈춘다.

**걸리는 시간**: 설치 1~2시간(Jenkins 플러그인·이미지 다운로드 포함), 업체 1개·앱 1개 등록과 첫 배포 30분.

## 2. 설치 전 확인 (10분)

모든 명령은 **관리 노드(Master Node, 예: k8s-cp01)** 에서 실행한다.

### 2-1. 기존 K-PaaS가 정상인지

```bash
kubectl get nodes                            # 모두 Ready
kubectl -n cp-portal get pod                 # CP-Portal: Running
kubectl -n keycloak get pod                  # Keycloak: Running
kubectl -n harbor get pod                    # Harbor: Running
kubectl -n cp-source-control get pod         # 소스 컨트롤: Running
kubectl get ingressclass                     # nginx
kubectl get storageclass                     # 이름과 (default) 확인
ls ~/Saeoll-PaaS/cp-portal-deployment/certs/ca.crt
ls ~/Saeoll-PaaS/cp-portal-deployment/script/cp-portal-vars.sh
```

| 확인 | 방법 |
| --- | --- |
| Harbor 로그인 | 브라우저 `https://harbor.<도메인>` → admin 로그인 |
| SCM 관리자 비밀번호 | `https://scm.<도메인>`에 `scmadmin`으로 로그인 → 오른쪽 위 → **내정보 관리**에서 설정한 **git 비밀번호**를 알고 있어야 한다 |
| StorageClass 이름 | `grep K8S_STORAGECLASS ~/Saeoll-PaaS/cp-portal-deployment/script/cp-portal-vars.sh` 값이 `kubectl get storageclass` 목록에 있어야 한다 |
| 도구 | `kubectl`, `helm`, `git`, `curl`, `python3`, `podman` (`podman version`). 없으면 `sudo dnf install -y git curl python3 podman` |
| 노드 여유 | `kubectl top nodes` — 메모리 여유 최소 6Gi (Jenkins 1~3Gi, Argo CD 1Gi, 콘솔 0.3Gi, 빌드 중 Pod 최대 6Gi) |
| 인터넷 | `charts.jenkins.io`, `updates.jenkins.io`, `argoproj.github.io`, `quay.io`, `ghcr.io`, `docker.io`, `gcr.io`, PyPI. 폐쇄망이면 [설치 가이드 3-4](install-guide.md#3-4-인터넷-접근) |

### 2-2. 비밀번호 입력 요령

명령줄에 비밀번호를 그대로 쓰면 셸 기록에 남는다. 아래처럼 입력받아 쓴다. **새 터미널을 열 때마다 다시 입력**한다.

```bash
read -rsp 'scmadmin git 비밀번호: ' SCM_ADMIN_PASSWORD; echo; export SCM_ADMIN_PASSWORD
```

## 3. 소스 받기와 설정 (10분)

```bash
cd ~/Saeoll-PaaS && git pull              # 저장소가 없으면: cd ~ && git clone -b claude/stoic-edison-jc393z https://github.com/mussosinsa/Saeoll-PaaS.git
cd ~/Saeoll-PaaS/cicd-portal-deployment/script
vi cicd-vars.sh
```

처음에는 아래 두 가지만 확인한다. 나머지는 기본값을 그대로 둔다.

| 변수 | 값 | 이유 |
| --- | --- | --- |
| `CICD_SOURCES` | `"scm"` | 이 환경은 K-PaaS SCM + Jenkins를 쓴다. GitLab은 필요할 때 나중에 추가 |
| `K8S_STORAGECLASS` | 비움 또는 실제 이름(예: `"nfs-client"`) | CP-Portal 값이 실제 StorageClass 목록에 없을 때만 입력 |

```bash
# CICD_SOURCES 줄을 이렇게 바꾼다
CICD_SOURCES=${CICD_SOURCES:-${CICD_SOURCE:-"scm"}}
```

## 4. 설치 (40~90분)

### STEP 1. 사전 점검

```bash
read -rsp 'scmadmin git 비밀번호: ' SCM_ADMIN_PASSWORD; echo; export SCM_ADMIN_PASSWORD
./deploy-cicd-portal.sh preflight
```

`[OK] Preflight passed`가 나와야 한다. `[WARN]`이 있으면 메시지대로 고치고 다시 실행한다.
`SCM-Manager REST API login failed ... 401`이면 Keycloak 비밀번호가 아니라 SCM의 **git 비밀번호**를 넣었는지 확인한다.

### STEP 2. Jenkins · Argo CD 설치

```bash
./deploy-cicd-portal.sh 2>&1 | tee cicd-portal-deploy.log
```

- 실행 순서: preflight → keycloak(SSO 클라이언트·`cicd-admins` 그룹) → jenkins → argocd.
- Jenkins 첫 기동은 플러그인 다운로드로 **5~15분** 걸린다. 멈춘 것처럼 보여도 기다린다.
- 실패하면 원인을 고치고 **같은 명령을 다시 실행**한다(이미 된 부분은 그대로 둔다).
- 마지막에 `Jenkins: https://jenkins.<도메인>`, `Argo CD: https://argocd.<도메인>`이 출력되면 성공이다.

### STEP 3. Jenkins API 토큰 등록 (필수, 1회)

업체 등록·앱 추가가 Jenkins에 폴더와 Job을 만들 때 쓰는 토큰이다.

1. 브라우저 `https://jenkins.<도메인>` → K-PaaS SSO로 `admin` 로그인 (STEP 2가 CP-Portal 관리자 계정을 `cicd-admins` 그룹에 자동으로 넣는다)
2. 오른쪽 위 사용자 이름 → **Security** → API Token의 **Add new Token** → 이름 `cicd-portal` → **Generate** → 값 복사(다시 볼 수 없다)
3. 관리 노드에서 등록:

```bash
read -rsp 'Jenkins API 토큰: ' JENKINS_API_TOKEN; echo
JENKINS_USER=admin JENKINS_API_TOKEN="$JENKINS_API_TOKEN" ./deploy-cicd-portal.sh jenkins-token
```

`[OK] Jenkins API token stored for admin`이 나오면 된다.

### STEP 4. Jenkins 차트 버전 고정 (권장)

설치 로그의 `chart jenkins-x.y.z`를 확인해 고정한다. 고정하지 않으면 다시 설치할 때 최신 차트로 바뀔 수 있다.

```bash
grep -o 'chart jenkins-[0-9.]*' cicd-portal-deploy.log | tail -1      # 예: chart jenkins-5.9.73
sed -i 's/^JENKINS_CHART_VERSION=""/JENKINS_CHART_VERSION="5.9.73"/' cicd-vars.sh
```

### STEP 5. CI/CD 콘솔 · 보안 검사 설치

`cicd-vars.sh`의 `CONSOLE_IMAGE_TAG`, `SECURITY_IMAGE_TAG`는 처음에는 기본값(`1.0.0`)으로 둔다. 아래 한 줄이 순서대로 실행된다.

```bash
./deploy-cicd-portal.sh console-image security-image security console 2>&1 | tee cicd-console-deploy.log
```

| 단계 | 하는 일 | 시간 |
| --- | --- | --- |
| `console-image` | 콘솔 이미지를 만들어 Harbor `cicd-portal/cicd-console`에 올림 (`sudo podman`) | 3~5분 |
| `security-image` | 보안 검사 이미지(Semgrep·Gitleaks·Trivy + 취약점 DB)를 만들어 Harbor에 올림 | 5~10분 |
| `security` | 보안 정책·규칙 ConfigMap, 이미지 pull 권한, Harbor 자동 스캔 | 1분 |
| `console` | Keycloak 클라이언트 `cicd-console`, 콘솔 배포 `https://cicd.<도메인>` | 2분 |

- `sudo` 비밀번호를 물으면 입력한다(podman이 CP-Portal 이미지 빌드와 같은 저장소를 쓰기 위함).
- 보안 정책은 처음에 **경고 모드**다(문제를 알려 주기만 하고 배포는 막지 않는다).

### STEP 6. 점검과 로그인 확인

```bash
./check-cicd-portal.sh        # 마지막 줄 [RESULT] OK
```

| 주소 | 로그인 | 확인할 것 |
| --- | --- | --- |
| `https://cicd.<도메인>` | K-PaaS 계정 `admin` | 오른쪽 위에 **운영 관리자** 표시, 메뉴 **품질 관리** |
| `https://jenkins.<도메인>` | K-PaaS SSO | 관리 화면 접근 가능 |
| `https://argocd.<도메인>` | **LOG IN VIA K-PAAS SSO** | 로그인 후 빈 Applications 화면 |

- 브라우저의 "주의 요함"은 K-PaaS 사설 인증서 때문이다. PC에 `ca.crt`를 **신뢰할 수 있는 루트 인증 기관**으로 설치하면 사라진다.
- 로그아웃 후 Keycloak 화면에 `Invalid redirect uri`가 나오면 `./deploy-cicd-portal.sh console`을 한 번 더 실행한다.

### STEP 7. 다른 운영 관리자 지정 (필요 시)

Keycloak 관리 화면 `https://keycloak.<도메인>/admin` → realm **cp-realm** → **Groups** → `cicd-admins` → **Members** → **Add member**.
추가된 사람은 콘솔·Jenkins·Argo CD에서 **로그아웃 후 다시 로그인**한다.

설치 끝. 이제부터는 대부분 **콘솔(`https://cicd.<도메인>`) 화면**에서 한다.

## 5. 첫 업체 등록 (20분)

### STEP 1. 업체 사람 계정 만들기 (Keycloak)

`https://keycloak.<도메인>/admin` → **cp-realm** → **Users** → **Add user**

| 항목 | 입력 |
| --- | --- |
| Username | `saeoll-hong` (영문 소문자·숫자·`-`) |
| Email | 반드시 입력, **Email verified** 켬 |
| First / Last name | 실명 |

저장 → **Credentials** → **Set password** → 임시 비밀번호, **Temporary 켬**.
그 사람에게 `https://scm.<도메인>`에 **한 번 로그인**해 달라고 한다(SCM 계정이 생겨야 저장소 참여자로 지정할 수 있다).

### STEP 2. 콘솔에서 업체 등록 — 1차

콘솔 메뉴 **업체 등록**:

| 칸 | 입력 |
| --- | --- |
| 업체 ID | `saeoll` (나중에 바꿀 수 없음) |
| 소스 저장소 · CI | **K-PaaS SCM + Jenkins** |
| 네임스페이스 구성 | **분리** (`saeoll-dev`, `saeoll-prod`) |
| 개발자 | `saeoll-hong` (여러 명이면 쉼표로) |
| CI 계정 / git 비밀번호 | 둘 다 **비움** |

**실행** → 작업 로그가 나온다. 상태 **수동 대기**(종료 코드 3)로 끝나는 것이 정상이다. 새 CI 계정 `jenkins-saeoll`이 만들어졌고 git 비밀번호 설정이 남았다는 뜻이다.

### STEP 3. CI 계정의 git 비밀번호 설정

```bash
kubectl -n cicd-jenkins get secret cicd-portal-secrets -o jsonpath='{.data.kc-jenkins-saeoll-password}' | base64 -d; echo
```

1. 브라우저 **시크릿 창** → `https://scm.<도메인>` → `jenkins-saeoll` / 위 비밀번호로 로그인
2. 오른쪽 위 → **내정보 관리** → **비밀번호 변경** → 새 비밀번호 입력(= git 비밀번호, 메모) → 로그아웃, 창 닫기

### STEP 4. 콘솔에서 업체 등록 — 2차

다시 **업체 등록** → 업체 ID `saeoll`, 소스·네임스페이스는 1차와 같게, **CI 계정 git 비밀번호**에 STEP 3의 값 → **실행** → **성공**.

> 업체 등록을 나중에 다시 실행할 때는 **항상 git 비밀번호를 함께 넣는다**. 비우면 Jenkins의 Harbor 비밀번호가 맞지 않아 빌드의 이미지 단계가 실패한다.
> 구성원 추가만 하려면 업체 화면의 **구성원** 탭을 쓴다.

## 6. 첫 앱 추가와 배포 (20분)

### STEP 1. SCM 저장소 만들기

`https://scm.<도메인>`에 운영 관리자로 로그인 → **레파지토리** → **신규생성** → 유형 **Git**, 이름 **`saeoll-homepage`**.
저장소 상세 → **참여자 추가**: `jenkins-saeoll` **보기**, `saeoll-hong` **쓰기**.

> SCM-Manager 관리 화면(`scm-manager.`)이 아니라 **`scm.` 화면**에서 만들어야 K-PaaS 목록에 보인다.
> 이미 쓰던 저장소가 있으면 새로 만들지 않고 참여자만 확인한 뒤, 다음 단계에서 **기존 SCM 저장소 이름**에 입력한다.

### STEP 2. 콘솔에서 앱 추가

콘솔 → 업체 `saeoll` → **+ 앱 추가**:

| 칸 | 입력 |
| --- | --- |
| 앱 ID | `homepage` |
| 언어 · 빌드 유형 | `php` (그 외 `java-gradle`, `java-maven`, `node`, `vue`) |
| 헬스 체크 경로 | 비움 (php `/healthz.php`, 그 외 `/healthz`) |
| 선택 사항 | 새 앱이면 모두 그대로 |

**실행** → **성공**. 저장소에 샘플 소스와 `Jenkinsfile`(보안 단계 포함)이 들어가고 `develop` 브랜치가 생기며 첫 빌드가 자동으로 시작된다.

### STEP 3. 첫 배포 확인

1. 콘솔 → 앱 `homepage` 화면. **빌드 이력**에 `#1 실행 중` → 5~10분 뒤 **성공** 또는 **불안정**(보안 경고, 배포는 됨)
2. **보안 검사** 단계 → **보고서**로 검사 결과 확인
3. **3. dev 배포**가 `정상 · 동기화됨`이 되면 dev 환경의 **접속 주소** `https://homepage-saeoll-dev.<도메인>` 클릭 → 샘플 화면
4. 실패하면 빌드 이력의 **로그**를 보고 [9장](#9-자주-생기는-문제-관리자)을 참고한다.

### STEP 4. 업체에 전달할 것

- 계정 ID·임시 비밀번호
- `ca.crt` (`~/Saeoll-PaaS/cp-portal-deployment/certs/ca.crt`, **`ca.key`는 절대 주지 않는다**)
- 콘솔 `https://cicd.<도메인>`, git 주소 `https://scm-manager.<도메인>/scm/git/saeoll-homepage`
- 이 문서의 [2부](#2부-사용자-업체-개발자)와 [업체 가이드](console-vendor-guide.md)

## 7. 운영(prod) 배포 승인

업체가 릴리스(태그 `v1.0.0`)를 빌드하면 콘솔 대시보드의 **prod 배포 대기** 숫자가 올라간다.

1. 콘솔 → 앱 화면 → **5. prod 배포**의 태그가 요청받은 버전인지 확인
2. **prod Sync** → 확인 → 몇 분 뒤 `정상 · 동기화됨`
3. 버튼이 **prod Sync (보안 미통과)**이면 최근 릴리스가 보안 게이트를 통과하지 못한 것이다. 보고서를 확인하고, 그래도 배포해야 하면 **배포 사유**를 입력한다(기록됨).
4. 문제가 생기면 prod 환경 **배포 이력** → 이전 행의 **롤백**.

## 8. 일상 운영

| 언제 | 할 일 | 어디서 |
| --- | --- | --- |
| 새 업체 | 5장 | Keycloak, 콘솔 |
| 새 앱 | 6장 | SCM, 콘솔 |
| 업체 인원 추가·제외 | 업체 화면 **구성원** 탭 + SCM 저장소 **참여자** | 콘솔, SCM |
| DB가 필요한 앱 | 앱 화면 **DB 연결** (dev 먼저) | 콘솔 |
| 운영 배포 | 7장 | 콘솔 |
| 보안 예외 요청 처리 | **품질 관리 → 예외 관리**에서 승인·반려 | 콘솔 |
| 차단 모드 전환 (2~4주 운영 후) | **품질 관리 → 보안 게이트** → prod를 차단 모드로 | 콘솔 |
| 주 1회 | 대시보드 → **시스템 점검**, 보안 이슈 확인 | 콘솔 |
| 주 1회 (폐쇄망) | 취약점 DB 갱신: `./deploy-cicd-portal.sh security-image` | 관리 노드 |
| 포털 업데이트 | `git pull` 후 바뀐 부분 재실행 (콘솔: `CONSOLE_IMAGE_TAG` 올리고 `console-image console`) | 관리 노드 |
| 백업 | Jenkins PVC(`cicd-jenkins`), SCM 저장소, gitops 저장소 | - |

## 9. 자주 생기는 문제 (관리자)

| 증상 | 해결 |
| --- | --- |
| preflight `SCM ... HTTP 401` | `SCM_ADMIN_PASSWORD`에 scmadmin의 **git 비밀번호**를 넣는다 |
| preflight `StorageClass not found` | `cicd-vars.sh`의 `K8S_STORAGECLASS`를 실제 이름으로 |
| Jenkins 설치가 오래 멈춤 | 첫 기동 15분까지 정상. `kubectl -n cicd-jenkins logs statefulset/jenkins -c jenkins --tail=50` |
| `security` 단계 `GitLab automation token not found` | `CICD_SOURCES="scm"`으로 바꾸고 다시 실행 |
| 콘솔 로그인 후 "접근할 수 있는 업체가 없습니다" | Keycloak 그룹 `cicd-admins`(관리자) 또는 `cicd-<업체>`(업체)에 넣고 재로그인 |
| 업체 등록 **수동 대기** | 정상. 5장 STEP 3~4 |
| 앱 추가 `Prepare 'saeoll-homepage' in https://scm...` | SCM 저장소가 없거나 `jenkins-saeoll`이 참여자(보기)가 아님 |
| 빌드 Image 단계 `UNAUTHORIZED` | 업체 등록을 git 비밀번호와 함께 다시 실행 |
| 빌드 Pod `ImagePullBackOff` (security) | `./deploy-cicd-portal.sh security-image security` 재실행 |
| dev가 계속 `오류` | 첫 빌드 성공 여부, dev 환경 패널의 경고 문구, 헬스 체크 경로 확인 |
| 대시보드 보안 열이 '결과 없음' | 보안 설치 전에 만든 앱 → 앱 추가를 같은 ID로 **'기존 CI 파일 교체'** 켜고 재실행 |

더 많은 항목: [운영 관리자 가이드 10장](console-admin-guide.md#10-문제-해결), [설치 가이드 13장](install-guide.md#13-문제-해결),
[보안 가이드 8장](security-guide.md#8-문제-해결).

## 10. 설치 체크리스트

- [ ] 2장 기존 K-PaaS 상태·도구·StorageClass·scmadmin git 비밀번호 확인
- [ ] `cicd-vars.sh`: `CICD_SOURCES="scm"`, (필요 시) `K8S_STORAGECLASS`
- [ ] `./deploy-cicd-portal.sh preflight` → OK
- [ ] `./deploy-cicd-portal.sh` → Jenkins·Argo CD 주소 출력
- [ ] Jenkins API 토큰 등록, 차트 버전 고정
- [ ] `./deploy-cicd-portal.sh console-image security-image security console`
- [ ] `./check-cicd-portal.sh` → `[RESULT] OK`, 콘솔·Jenkins·Argo CD 로그인
- [ ] 첫 업체 등록(1차 → git 비밀번호 → 2차), 첫 앱 추가, dev 접속 확인
- [ ] 업체에 계정·`ca.crt`·주소·2부 전달

---

# 2부. 사용자 (업체 개발자)

## 1. 받는 것

운영 관리자에게서 다음을 받는다.

- 계정 ID와 임시 비밀번호 (예: `saeoll-hong`)
- 인증서 파일 `ca.crt`
- 앱 이름과 git 주소 (예: `https://scm-manager.<도메인>/scm/git/saeoll-homepage`)

| 이름 | 주소 |
| --- | --- |
| CI/CD 콘솔 (빌드·배포·보안 결과) | `https://cicd.<도메인>` |
| 소스 저장소 웹 화면 | `https://scm.<도메인>` |
| dev 서비스 | `https://homepage-saeoll-dev.<도메인>` |
| 운영 서비스 | `https://homepage-saeoll.<도메인>` |

## 2. 처음 한 번 할 일

### 2-1. 인증서 설치 (브라우저 경고 없애기)

Windows: `ca.crt` 더블 클릭 → **인증서 설치** → **로컬 컴퓨터** → **모든 인증서를 다음 저장소에 저장** →
**신뢰할 수 있는 루트 인증 기관** → 마침 → 브라우저 재시작.

### 2-2. 로그인과 비밀번호 변경

1. `https://cicd.<도메인>` → 계정 ID / 임시 비밀번호 → 새 비밀번호 설정 → 대시보드에 우리 업체(`saeoll`)가 보이면 성공
2. `https://scm.<도메인>` 로그인(같은 계정) → 오른쪽 위 → **내정보 관리** → **비밀번호 변경**.
   여기서 정한 값이 **git 비밀번호**다(로그인 비밀번호와 다름). 운영 관리자에게 "SCM 첫 로그인 완료"를 알린다.

### 2-3. PC에 Git 준비와 소스 받기

Git for Windows를 설치하고 **Git Bash**에서 실행한다. `ca.crt`를 홈 폴더에 `kpaas-ca.crt` 이름으로 저장했다고 가정한다.

```bash
git config --global http.https://scm-manager.<도메인>/.sslCAInfo ~/kpaas-ca.crt
git config --global user.name "홍길동"
git config --global user.email "hong@example.com"
git clone -b develop https://scm-manager.<도메인>/scm/git/saeoll-homepage
#   Username: saeoll-hong   Password: 2-2의 git 비밀번호
cd saeoll-homepage
```

## 3. 개발하고 dev에 배포하기

```bash
git checkout develop && git pull
git checkout -b feature/login                # 작업용 브랜치
# ... 개발 ...
git add . && git commit -m "로그인 화면 추가"
git checkout develop && git merge --no-ff feature/login
git push origin develop                      # 이 push가 dev 배포를 시작한다
```

1. push 후 **5분 안에** 빌드가 자동으로 시작된다. 바로 하려면 콘솔 앱 화면의 **빌드 실행**.
2. 콘솔 앱 화면 **빌드 이력**에서 진행을 본다. **로그**로 실시간 로그를 볼 수 있다.
3. 빌드가 끝나면 1~3분 안에 **3. dev 배포**가 `정상 · 동기화됨`이 된다 → dev 주소에서 확인.

지켜야 할 규칙: 앱은 **8080 포트**, 헬스 체크 `GET /healthz`(PHP `/healthz.php`)가 200, 비밀번호·키는 소스에 넣지 않는다.

## 4. 보안 검사 결과 보기

빌드마다 코드 취약점, 비밀정보, 라이브러리 취약점, 개인정보(주민번호·카드번호 등)를 검사한다.

| 표시 | 뜻 | 할 일 |
| --- | --- | --- |
| 통과 (초록) | 기준 이내 | 없음 |
| 경고 (노랑), 빌드 **불안정** | 기준 초과, 배포는 됨 | 보고서를 보고 High 이상부터 수정 |
| 차단 (빨강) | 기준 초과, **배포 안 됨** (차단 모드) | 수정 후 다시 push |

1. 앱 화면 **보안 검사 → 보고서**, 또는 메뉴 **품질 관리 → 보안 이슈**
2. '내용' 열에 고치는 방법이 있다. 라이브러리 취약점은 '수정 버전'으로 올린다.
3. 비밀정보가 나오면 **그 비밀번호·키를 바로 바꾼다**(커밋 이력에 남기 때문).
4. 오탐이면 그 줄의 **예외 요청** → 근거를 적어 요청 → 운영 관리자 승인 후 다음 빌드부터 빠진다.

## 5. 운영 배포 요청

```bash
git checkout main && git pull
git merge --no-ff develop
git tag -a v1.0.0 -m "v1.0.0 최초 오픈"
git push origin main --follow-tags
```

1. 콘솔 앱 화면 → **4. 릴리스 → 릴리스** → 태그 `v1.0.0` → **실행**
2. 릴리스 빌드가 끝나면 운영 관리자에게 요청한다:

```text
[운영 배포 요청] saeoll / homepage  v1.0.0 (콘솔 릴리스 빌드 #3 성공, 보안: 통과)
변경: 로그인 화면 추가 / dev 테스트 완료 / 희망 일시: 11-03 18:00 / 롤백 기준: v0.9.0
```

3. 배포가 끝나면 **5. prod 배포**가 `정상 · 동기화됨`, 운영 주소에 새 버전이 보인다.
   다음 수정본은 번호를 올린다(`v1.0.1`). 같은 태그 이름은 다시 쓰지 않는다.

## 6. 자주 묻는 문제 (사용자)

| 증상 | 해결 |
| --- | --- |
| 콘솔에 우리 업체가 안 보임 | 운영 관리자에게 구성원 추가 요청 → 로그아웃 후 다시 로그인 |
| `git clone` `Authentication failed` | 로그인 비밀번호가 아니라 **git 비밀번호**. Windows 자격 증명 관리자에서 `scm-manager` 항목 삭제 후 재시도 |
| `git clone` 403 / not found | 저장소 참여자(쓰기)가 아님 → SCM 첫 로그인 후 운영 관리자에게 요청 |
| `SSL certificate problem` | 2-3의 `sslCAInfo` 설정 확인 |
| push 했는데 빌드가 안 됨 | 5분 기다리거나 콘솔 **빌드 실행** |
| 빌드 **실패** | **로그** 마지막의 `ERROR`/`FAIL` 확인 → 수정 후 push. Image 단계 오류는 운영 관리자에게 로그와 함께 문의 |
| dev가 `오류` | 8080 포트, `/healthz` 응답(200) 확인 |
| 릴리스 실패 | 태그를 push했는지(`git push origin v1.0.0`), 이름이 `v1.0.0` 형식인지 |

---

## 참고 문서

| 문서 | 내용 |
| --- | --- |
| [CI/CD 콘솔 운영 관리자 가이드](console-admin-guide.md) | 업체 등록·앱 추가·DB·구성원·운영 배포 상세 |
| [CI/CD 콘솔 업체 가이드](console-vendor-guide.md) | 개발자용 상세 (GitLab 업체 포함) |
| [보안 검사 · 품질 관리 가이드](security-guide.md) | 보안 게이트·프로파일·예외, Presidio·DefectDojo |
| [CI/CD 콘솔 가이드](console-guide.md) | 콘솔 구성·권한·설치 옵션 |
| [설치·설정·운영 전체 가이드](install-guide.md) | 스크립트별 상세, 명령으로 하는 방법, 폐쇄망 |
| [README](../README.md) | 구성 요약, GitLab 구성 |
