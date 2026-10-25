# Jenkins 적용 가이드 (빌드, scm 업체)

CI/CD 포털에서 Jenkins는 **K-PaaS SCM 저장소의 소스를 빌드·테스트하고 이미지를 만들어 Harbor에 올린 뒤,
gitops 저장소의 이미지 태그를 바꾸는** 역할이다. (gitlab 업체는 Jenkins 대신 GitLab Runner를 쓴다.)
화면 사용법은 [웹 화면 가이드](web-ui-guide.md) 1부를 본다.

| 솔루션 가이드 | |
| --- | --- |
| [소스 저장소 (SCM / GitLab)](guide-scm-gitlab.md) / [Harbor](guide-harbor.md) | |
| **Jenkins (이 문서)** | |
| [Argo CD](guide-argocd.md) / [설치·관리 전체 가이드](install-guide.md) | |

---

## 1. 구성

| 항목 | 내용 |
| --- | --- |
| 주소 | `https://jenkins.<도메인>` |
| 네임스페이스 | `cicd-jenkins` (컨트롤러 `jenkins-0` + 빌드할 때만 생기는 빌드 Pod) |
| 설치 | 공식 Helm 차트 `jenkins/jenkins` (`JENKINS_CHART_VERSION`, 첫 설치 후 고정 권장) |
| 설정 원본 | `values_orig/jenkins.yaml`(공통), `values_orig/jenkins-sso.yaml`(SSO·권한) → `values/`에 실제 값으로 생성 |
| 자원 | 컨트롤러 요청 0.5 CPU / 1Gi, 상한 3Gi, 디스크 `JENKINS_DATA_SIZE`(20Gi) |
| 실행기 | 컨트롤러 실행기 0개(`numExecutors: 0`) — **모든 빌드는 쿠버네티스 Pod에서** |
| 로그인 | Keycloak `cp-realm` 클라이언트 `cicd-jenkins` (oic-auth) |
| 권한 | **Project-based Matrix**: `cicd-admins` → 전체 관리, 로그인 사용자 → Overall/Read, 업체 폴더 → `cicd-<업체>` |

### 1-1. 설치 시 적용되는 설정 (deploy-cicd-portal.sh jenkins)

| 설정 | 내용 | 이유 |
| --- | --- | --- |
| 플러그인 | oic-auth, matrix-auth, credentials-binding, pipeline-stage-view, timestamper, junit (+차트 기본: kubernetes, workflow, git, configuration-as-code) | SSO, 폴더 권한, 비밀값 바인딩, 단계 화면, 테스트 리포트 |
| JVM truststore | 초기화 컨테이너 `cicd-truststore`가 기본 CA + **K-PaaS CA**를 `/var/jenkins_home/cicd-cacerts`로 생성 | Keycloak·Harbor·SCM 사설 인증서 신뢰 |
| OIDC 비밀값 | 환경변수 `CICD_OIDC_CLIENT_SECRET` ← Secret `cicd-portal-secrets`의 `jenkins-oidc-secret` | Git·values 파일에 비밀값 없음 |
| SSO (JCasC) | `preferred_username`=사용자, `groups` 클레임=그룹, 로그아웃 시 Keycloak도 로그아웃 | |
| `allowTokenAccessWithoutOicSession: true` | API 토큰으로 스크립트 접근 허용 | 없으면 스크립트 API 호출이 로그인 페이지로 302 |
| Ingress | `jenkins.<도메인>`, TLS `<도메인>-tls` | |
| 설정 관리 | JCasC(Configuration as Code) | **화면에서 바꾼 전역 설정은 재배포 시 원래대로** — 영구 변경은 values 파일 수정 후 재배포 |

설정만 다시 적용: `./deploy-cicd-portal.sh jenkins` (재시작 반복 중인 Pod는 자동으로 다시 만들고 준비될 때까지 대기)

### 1-2. API 토큰 (설치 후 1회)

스크립트(`onboard-vendor.sh`, `add-app.sh`, `migrate-vendor.sh`)가 폴더·잡·credential을 만들 때 쓴다.

1. `cicd-admins` 계정으로 로그인 → 사용자 메뉴 → **Security** → API Token **Add new Token** → 복사
2. `JENKINS_USER=admin JENKINS_API_TOKEN='<토큰>' ./deploy-cicd-portal.sh jenkins-token`
   → Secret `cicd-jenkins/cicd-portal-secrets`의 `jenkins-user`, `jenkins-api-token`

토큰을 폐기하거나 사용자를 바꾸면 다시 등록한다.

## 2. 업체·앱 단위로 만들어지는 것

| 스크립트 | Jenkins 생성물 |
| --- | --- |
| `onboard-vendor.sh --source scm <업체>` | 폴더 `<업체>` + 폴더 권한(그룹 `cicd-<업체>`: Read, Discover, Build, Cancel, Workspace, Replay) / 폴더 credential `<업체>-harbor`(Harbor robot), `<업체>-scm`(CI 계정 git 비밀번호) |
| `add-app.sh <업체> <앱> <유형>` | 잡 `<앱>-dev`: 저장소 `develop`, Poll SCM `H/5 * * * *`, 경량 체크아웃 / 잡 `<앱>-release`: 파라미터 `RELEASE_TAG`, 브랜치 `refs/tags/${RELEASE_TAG}` / 첫 dev 빌드 실행 |
| `migrate-vendor.sh` | 해당 업체 잡 비활성화(이력 보존) |

- 잡은 **파이프라인 정의를 저장소의 `Jenkinsfile`에서** 읽는다(Pipeline script from SCM). 저장소 주소는 클러스터 내부 주소
  `http://cp-source-control-manager-service.cp-source-control.svc.cluster.local:8080/scm/git/<저장소>`.
- credential이 폴더 범위라 다른 업체 잡에서 쓸 수 없다.

## 3. Jenkinsfile (starters/<유형>/Jenkinsfile)

```text
properties: 동시 빌드 금지, 30개 보관, RELEASE_TAG 파라미터, (dev 잡만) Poll SCM 5분
podTemplate: build 컨테이너(유형별 이미지) + kaniko 컨테이너(K-PaaS CA 마운트) + jnlp
  Checkout : 소스 받기, 이미지 태그 결정 (dev-<커밋>-<번호> 또는 RELEASE_TAG 검증)
  Build    : buildScript  (예: composer install, php -l / gradle build / npm ci ...)
  Test     : testScript   (+ junitReports 가 있으면 JUnit 리포트, 플러그인 없으면 건너뜀)
  Image    : kaniko → harbor.<도메인>/<업체>/<앱>:<태그> push (robot credential)
  Deploy   : gitops 저장소 clone → overlays/<dev|prod>/kustomization.yaml 의 newTag 변경 → push (충돌 시 3회 재시도)
```

| 유형 | build 이미지 | 기본 테스트 리포트 |
| --- | --- | --- |
| `java-gradle` | gradle:8.10-jdk17 | `build/test-results/test/**/TEST-*.xml` |
| `java-maven` | maven:3.9-eclipse-temurin-17 | `target/surefire-reports/TEST-*.xml` |
| `php` | composer:2 | `phpunit-report.xml` |
| `node` / `vue` | node:20-alpine | (없음) |

업체는 상단의 `buildScript`, `testScript`, `buildImage`, `junitReports`만 수정한다.

> **Poll SCM 주의**: Jenkinsfile의 `properties([...])`는 잡 설정 전체를 덮어쓴다. 예전 Jenkinsfile은 Poll SCM을 넣지 않아
> 첫 빌드 후 자동 빌드가 사라졌다. 현재 Jenkinsfile은 dev 잡에 Poll SCM을 다시 넣는다. 예전 저장소는
> `SCM_REPO=<저장소> REPLACE_CI=1 ./add-app.sh <업체> <앱> <유형>`으로 main·develop의 Jenkinsfile을 교체한다.

## 4. 관리자 작업

| 작업 | 방법 |
| --- | --- |
| 업체 사용자에게 폴더 보이기 | Keycloak 그룹 `cicd-<업체>`에 추가 → 사용자 로그아웃·재로그인 → `https://jenkins.<도메인>/whoAmI/`의 Authorities에 `cicd-<업체>` |
| 권한 방식 확인 | 관리(⚙) → Security → Authorization = **Project-based Matrix Authorization Strategy** |
| release 잡을 관리자 전용으로 | 잡 → Configure → Enable project-based security → Inheritance **Do not inherit permission grants from other ACLs** → `cicd-admins`에 Job Read·Build·Cancel, Run Replay |
| 빌드 수동 실행 | 잡 → **Build Now** / release는 **Build with Parameters** |
| Poll 확인 | 잡 → **Polling Log** (`Changes found` / `No changes`), 잡 → Configure → Build Triggers |
| 빌드 Pod 보기 | `kubectl -n cicd-jenkins get pod` (빌드 중에만 `<잡>-xxxxx`), 노드 목록에는 Built-In Node만 보이는 것이 정상 |
| credential 갱신 | 직접 수정하지 말고 `./onboard-vendor.sh <업체>` (Harbor robot·CI 계정 비밀번호 동기화) |
| Jenkinsfile 갱신 | `SCM_REPO=<저장소> REPLACE_CI=1 ./add-app.sh <업체> <앱> <유형>` → 개발자는 `git pull` |

### 4-1. 점검·진단

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script
kubectl -n cicd-jenkins get pod,pvc
kubectl -n cicd-jenkins logs jenkins-0 -c jenkins --tail=100
kubectl -n cicd-jenkins get cm -o yaml | grep -n "globalMatrix\|projectMatrix"      # projectMatrix
# 빌드 목록·마지막 콘솔 (curl -g 필수: 주소의 [ ])
bash -c 'source ./lib.sh; load_portal_vars
U=$(get_secret jenkins-user); T=$(get_secret jenkins-api-token); J="$JENKINS_URL/job/saeoll/job/php-service-dev"
curl -gsk -u "$U:$T" "$J/api/json?tree=builds[number,result,building]"; echo
curl -gsk -u "$U:$T" "$J/lastBuild/consoleText" | tail -40'
# 폴더 권한
bash -c 'source ./lib.sh; load_portal_vars; U=$(get_secret jenkins-user); T=$(get_secret jenkins-api-token)
curl -gsk -u "$U:$T" "$JENKINS_URL/job/saeoll/config.xml" | grep -E "permission|inheritance"'
```

### 4-2. 백업·업그레이드

| 작업 | 방법 |
| --- | --- |
| 백업 | PVC 스냅샷, 또는 `kubectl -n cicd-jenkins exec jenkins-0 -c jenkins -- tar czf - --exclude=workspace -C /var/jenkins_home . > jenkins-home.tgz` |
| 플러그인·보안 업데이트 | `./deploy-cicd-portal.sh jenkins` (`installLatestPlugins: true`) |
| 차트 업그레이드 | `cicd-vars.sh`의 `JENKINS_CHART_VERSION` 변경 → `./deploy-cicd-portal.sh jenkins` (백업 후) |
| SSO 장애 시 | `JENKINS_SSO=false ./deploy-cicd-portal.sh jenkins` → 로컬 admin(`kubectl -n cicd-jenkins get secret jenkins -o jsonpath='{.data.jenkins-admin-password}' \| base64 -d`) → 원인 해결 후 `true`로 재배포 |

## 5. 문제 해결

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| `jenkins-0` CrashLoopBackOff, 로그 `YamlUtils.merge` / `numExecutors` | JCasC 설정 충돌 | `git pull` 후 `./deploy-cicd-portal.sh jenkins` |
| 로그 `UnknownAttributesException ... pkceEnabled` | oic-auth 버전과 설정 불일치 | `git pull` 후 재배포 |
| 스크립트 `Jenkins API ... HTTP 302` | 토큰 없음/만료, SSO 세션 설정 | API 토큰 재등록(1-2), 최신 values 재배포 |
| 업체 계정 대시보드가 비어 있음 | 그룹 미반영 또는 권한 방식 globalMatrix | 4장 첫 줄, Security의 Authorization 확인 |
| develop push 후 빌드 안 됨 | master에 push / Poll SCM 소실 | `git branch -vv` / 3장 주의 |
| `No such DSL method 'junit'` | JUnit 플러그인 없음 | `./deploy-cicd-portal.sh jenkins` + `REPLACE_CI=1` |
| `fatal: detected dubious ownership` | 예전 Jenkinsfile (경고) | `REPLACE_CI=1` |
| Image `xz: Failed to enable the sandbox` | trixie 기반 PHP 이미지 + kaniko | Dockerfile `php:8.3-apache-bookworm` |
| Image `UNAUTHORIZED` / `x509` | Harbor robot / CA | [Harbor 가이드](guide-harbor.md) 7장 |
| Deploy push 거부 | CI 계정 gitops 쓰기 권한 | `./onboard-vendor.sh <업체>` |
| 빌드가 `Waiting for next available executor`에서 오래 대기 | 빌드 Pod 생성 실패(이미지 pull, 자원) | `kubectl -n cicd-jenkins get pod`, `get events --sort-by=.lastTimestamp \| tail` |
| `RELEASE_TAG must look like v1.2.0` / `Couldn't find any revision` | 태그 형식 / 태그 미 push | `vX.Y.Z`, `git push origin vX.Y.Z` |
