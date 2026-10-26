# 테스트 샘플과 배포 방법 (PHP · Java Spring · Node.js · Vue)

CI/CD 포털의 빌드·배포와 **MariaDB 연동**을 언어별로 확인하는 게시판 샘플이다. 네 샘플 모두 같은 기능
(목록·검색·페이지, 보기·조회수, 쓰기, 비밀번호로 수정·삭제)과 같은 DB 규칙(`DB_*` 환경변수, `posts` 테이블)을 쓴다.

| 샘플 | 유형 (`add-app.sh`) | 내용 | DB | 확인 주소 (dev) |
| --- | --- | --- | --- | --- |
| [php-board](php-board/README.md) | `php` | PHP 8.3 + Apache, 화면 포함 | O | `/`, `/dbcheck.php` |
| [spring-board](spring-board/README.md) | `java-gradle` | Spring Boot 3.3 (JDK 17) REST API | O | `/api/posts`, `/api/dbcheck` |
| [node-board](node-board/README.md) | `node` | Node.js 20 REST API (`mariadb` 드라이버) | O | `/api/posts`, `/api/dbcheck` |
| [vue-board](vue-board/README.md) | `vue` | Vue 3 화면 + nginx (`/api` → node-board 또는 spring-board) | - | `/` |

```text
                         ┌─ node-board  (Node.js API) ── node-board-mariadb
브라우저 ── vue-board ──/api──┤
     (Vue + nginx)       └─ spring-board (Spring API) ── spring-board-mariadb    ← API_SERVICE 로 선택
브라우저 ── php-board (PHP 화면 + API) ── php-service-mariadb
```

- 모든 앱: **8080 포트**, `/healthz` 200(DB 사용 안 함 → DB 장애가 Pod 재시작으로 번지지 않음).
- DB 접속 정보는 Secret `<앱>-db`의 `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` (`add-db.sh`가 생성). 소스·Git에 비밀번호 없음.
- 테이블은 첫 접속 때 자동 생성 → 빈 DB에서 바로 동작.
- API 응답 규칙(Node·Spring 공통): 아래 [부록](#부록-rest-api-규칙).

## 1. 검증 결과 (작성 시 로컬 확인)

| 샘플 | 확인 내용 |
| --- | --- |
| node-board | `npm test` 4/4 통과(메모리 저장소), 실제 MariaDB로 생성·조회·수정(틀린 비밀번호 403)·검색·삭제, DB 중단 시 `/healthz` 200·API 503 |
| spring-board | `gradle check` 2/2 통과(H2), `bootJar` 실행 후 MariaDB로 같은 시나리오, DB 중단 상태에서도 기동·`/healthz` 200 |
| vue-board | `npm run build` 성공, nginx 설정 검사, 브라우저 자동 테스트(nginx → node-board → MariaDB): 글쓰기·보기·수정(틀린 비밀번호)·목록·삭제 |
| php-board | [php-board README](php-board/README.md) 참고 (클러스터 배포까지 확인) |

## 2. 배포 순서 (scm 업체 `saeoll` 예시)

관리자(서버)와 개발자(PC)가 나눠 진행한다. 앱 이름은 원하는 대로 바꿔도 된다(아래 명령의 이름만 맞춘다).

| 단계 | 누가 | 작업 |
| --- | --- | --- |
| 1 | 관리자 | SCM 저장소 생성·참여자 |
| 2 | 관리자 | `add-app.sh` (시작 소스, Jenkins 잡, Argo CD 앱) |
| 3 | 관리자 | `add-db.sh` (DB가 필요한 앱만) |
| 4 | 개발자 | 시작 소스를 샘플로 교체 → develop push |
| 5 | 모두 | Jenkins 빌드 → Argo CD dev 반영 → 화면·API 확인 |
| 6 | PM·관리자 | 태그 → release 빌드 → `add-db.sh ... prod` → 관리자 prod SYNC |

### 2-1. (관리자) SCM 저장소

`https://scm.<도메인>` → 레파지토리 신규생성(Git) 3개: `saeoll-spring-board`, `saeoll-node-board`, `saeoll-vue-board`
→ 각 저장소 참여자: CI 계정(예: `saeoll`) **보기**, 개발자 **쓰기**.

### 2-2. (관리자) 앱 추가

```bash
cd ~/Saeoll-PaaS && git pull && cd cicd-portal-deployment/script
read -rsp 'scmadmin 비밀번호: ' SCM_ADMIN_PASSWORD; echo; export SCM_ADMIN_PASSWORD
./add-app.sh saeoll spring-board java-gradle
./add-app.sh saeoll node-board node
./add-app.sh saeoll vue-board vue
```
시작 소스로 첫 dev 빌드가 돌고, Argo CD 앱 `saeoll-<앱>-dev/prod`가 생긴다.

### 2-3. (관리자) DB 연결

```bash
./add-db.sh saeoll spring-board dev
./add-db.sh saeoll node-board dev
```
각 앱 전용 MariaDB(`<앱>-mariadb`), Secret `<앱>-db`, gitops 연결이 만들어진다(vue-board는 DB 없음).

### 2-4. (개발자) 샘플 적용 — 공통 준비

```bash
# 샘플 받기 (서버에서 복사하거나 GitHub에서)
git clone --depth 1 -b claude/stoic-edison-jc393z https://github.com/mussosinsa/Saeoll-PaaS.git ~/Saeoll-PaaS
SAMPLES=~/Saeoll-PaaS/cicd-portal-deployment/samples
```
**Jenkinsfile은 저장소의 것(포털이 넣은 것)을 그대로 쓴다.** 샘플에는 Jenkinsfile이 없다.

#### spring-board

```bash
git clone -b develop https://scm-manager.<도메인>/scm/git/saeoll-spring-board && cd saeoll-spring-board
git rm -rq src/main/java/kr/saeoll/app src/test/java/kr/saeoll/app   # 시작 소스의 main 클래스 (두 개면 bootJar 실패)
cp -r $SAMPLES/spring-board/{build.gradle,settings.gradle,Dockerfile,src} .
git add -A && git commit -m "Spring 게시판 샘플" && git push origin develop
```

#### node-board

```bash
git clone -b develop https://scm-manager.<도메인>/scm/git/saeoll-node-board && cd saeoll-node-board
git rm -q server.test.js                                              # 시작 소스 테스트 (새 server.js와 맞지 않음)
cp -r $SAMPLES/node-board/{package.json,package-lock.json,server.js,Dockerfile,src,test} .
git add -A && git commit -m "Node.js 게시판 샘플" && git push origin develop
```

#### vue-board

```bash
git clone -b develop https://scm-manager.<도메인>/scm/git/saeoll-vue-board && cd saeoll-vue-board
git rm -q nginx.conf                                                  # 샘플은 nginx/ 폴더의 템플릿 사용
cp -r $SAMPLES/vue-board/{package.json,package-lock.json,index.html,vite.config.js,Dockerfile,src,nginx} .
git add -A && git commit -m "Vue 게시판 샘플" && git push origin develop
```

push 후 5분 안에 Jenkins `saeoll/<앱>-dev`가 빌드한다(급하면 **Build Now**).

### 2-5. 확인

| 앱 | 확인 | 기대 결과 |
| --- | --- | --- |
| 공통 | Jenkins `<앱>-dev` | Checkout → Build → Test → Image → Deploy 모두 초록 |
| 공통 | Argo CD `saeoll-<앱>-dev` | Healthy / Synced (DB 앱은 트리에 `sts <앱>-mariadb`) |
| spring-board | `https://spring-board-saeoll-dev.<도메인>/api/dbcheck` | `"status":"ok"`, `server_version` 11.4.x |
| node-board | `https://node-board-saeoll-dev.<도메인>/api/dbcheck` | 위와 같음 |
| vue-board | `https://vue-board-saeoll-dev.<도메인>/` | 게시판 화면, 하단 "API 정상 (DB node-board-mariadb …)" → 글쓰기·수정·삭제 |

API를 명령으로 시험:
```bash
U=https://node-board-saeoll-dev.<도메인>     # 또는 spring-board-...
curl -k -X POST -H 'Content-Type: application/json' -d '{"title":"첫 글","author":"홍길동","content":"내용","password":"1234"}' $U/api/posts
curl -k $U/api/posts
curl -k $U/api/posts/1
curl -k -X PUT -H 'Content-Type: application/json' -d '{"title":"수정","author":"홍길동","content":"내용","password":"1234"}' $U/api/posts/1
curl -k -X DELETE -H 'Content-Type: application/json' -d '{"password":"1234"}' $U/api/posts/1
```

### 2-6. vue-board가 spring-board를 쓰게 하기 (선택)

기본은 같은 네임스페이스의 `node-board`. 바꾸려면 gitops `apps/vue-board/overlays/<환경>/kustomization.yaml`의 `patches:`에 추가 후 push:
```yaml
  - target:
      kind: Deployment
      name: vue-board
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/env
        value:
          - name: API_SERVICE
            value: spring-board
```
(`git clone -b main https://scm-manager.<도메인>/scm/git/saeoll-gitops`) — Argo CD가 vue-board Pod를 다시 띄우면 적용된다.

### 2-7. 운영(prod) 배포

```bash
# 개발자/PM: 각 저장소에서
git checkout main && git pull && git merge --no-ff develop
git tag -a v1.0.0 -m "v1.0.0" && git push origin main --follow-tags
```
1. Jenkins `<앱>-release` → **Build with Parameters** → `RELEASE_TAG=v1.0.0`
2. (관리자) DB 앱: `./add-db.sh saeoll spring-board prod`, `./add-db.sh saeoll node-board prod`
3. (관리자) Argo CD `saeoll-<앱>-prod` → APP DIFF → **SYNC** (DB 앱을 먼저, vue-board는 마지막)
4. `https://<앱>-saeoll.<도메인>` 확인 (vue-board는 운영 네임스페이스의 node-board를 자동으로 사용)

## 3. 자원 (업체 기본 quota: CPU 요청 4, 메모리 8Gi)

| 구성 | 메모리 상한 |
| --- | --- |
| 앱 Pod (기본 LimitRange) | 512Mi씩 |
| 앱 전용 MariaDB | 1Gi씩 |

dev에 php·spring·node·vue + MariaDB 3개면 약 5Gi로 한도 안이다. 더 늘리면 `QUOTA_MEMORY=16Gi ./onboard-vendor.sh saeoll`.
Spring Boot가 느린 노드에서 기동 중 재시작되면(liveness 30초) gitops overlay에서 프로브 지연·메모리를 늘린다.

## 4. 문제 해결

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| spring Build `Unable to find a single main class` / 테스트에서 두 앱 충돌 | 시작 소스 `kr/saeoll/app` 남음 | 2-4의 `git rm` |
| node Test 단계 멈춤·실패 (`server.test.js`) | 시작 소스 테스트 남음 | `git rm server.test.js` |
| `/api/dbcheck` `db_host 127.0.0.1` | Secret 미연결 | `./add-db.sh saeoll <앱> dev` |
| `/api/dbcheck` 2002 | MariaDB 기동 중/없음 | `kubectl -n saeoll-dev get pod,pvc` |
| vue 화면 "API 서버에 연결할 수 없습니다" (502) | 같은 네임스페이스에 `node-board`(또는 `API_SERVICE`) 없음 | 백엔드 배포 확인, 2-6 |
| vue 화면 오류 "데이터베이스에 연결할 수 없습니다" | 백엔드는 있으나 DB 문제 | 백엔드의 `/api/dbcheck` |
| Image 단계 `manifest unknown` | 베이스 이미지 미러 없음(폐쇄망) | [Harbor 가이드](../docs/guide-harbor.md) 5장 |
| 빌드가 시작되지 않음 | master에 push, Poll SCM | [Jenkins 가이드](../docs/guide-jenkins.md) 5장 |

## 부록. REST API 규칙

node-board·spring-board 공통 (vue-board가 사용):

| 메서드 · 경로 | 요청 | 응답 |
| --- | --- | --- |
| `GET /api/posts?q=&page=` | - | `200 {total, page, pages, items:[{id,title,author,views,createdAt}]}` (10건씩) |
| `GET /api/posts/{id}` | - | `200 {id,title,content,author,views,createdAt,updatedAt}` (조회수 +1) / `404` |
| `POST /api/posts` | `{title, author, content, password}` | `201 {id}` / `400 {errors:[...]}` |
| `PUT /api/posts/{id}` | `{title, author, content, password}` | `200 글` / `403` 비밀번호 불일치 / `404` / `400` |
| `DELETE /api/posts/{id}` | `{password}` | `204` / `403` / `404` |
| `GET /api/dbcheck` | - | `200 {status:"ok", db_host, server_version, posts, ...}` / `503 {status:"error", error}` |
| `GET /healthz` | - | `200 ok` (DB 미사용) |
| DB 장애 시 API | - | `503 {errors:[...], cause:"2002 ..."}` |

비밀번호는 해시로만 저장한다(Node: scrypt, Spring: BCrypt, PHP: password_hash). 제목·작성자·내용 길이 1~200 / 1~50 / 1~10,000자, 비밀번호 4~64자.
