# PHP + MariaDB 게시판 샘플 (DB 연동 테스트)

CI/CD 포털로 배포한 PHP 앱(`saeoll/php-service`)에 **MariaDB를 연동하는 방법**을 확인하기 위한 게시판 샘플이다.
글 목록·검색·페이지, 보기(조회수), 쓰기, 수정·삭제(작성 시 비밀번호)와 DB 연결 점검 페이지를 제공한다.

```text
브라우저 ─▶ Ingress ─▶ php-service Pod (Apache + PHP, PDO pdo_mysql)
                          │ 환경변수 DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASSWORD  ◀─ Secret php-service-db
                          ▼
             방식 A: php-service-mariadb (같은 네임스페이스 saeoll-dev, gitops로 배포, PVC 2Gi)
             방식 B: K-PaaS 공용 MariaDB mariadb.mariadb.svc.cluster.local (전용 DB·계정 생성)
```

## 1. 구성

```text
samples/php-board/
├── app/                        ← 소스 저장소(saeoll)에 복사
│   ├── Dockerfile              포털 PHP 시작 소스와 동일 (php:8.3-apache-bookworm, pdo_mysql 설치)
│   ├── composer.json
│   ├── public/                 웹 루트(DocumentRoot)
│   │   ├── index.php           목록·검색·페이지
│   │   ├── view.php            보기(조회수 +1), 삭제 폼
│   │   ├── write.php           글쓰기
│   │   ├── edit.php            수정(비밀번호 확인)
│   │   ├── delete.php          삭제(비밀번호 확인)
│   │   ├── dbcheck.php         DB 연결 점검(JSON)
│   │   └── healthz.php         쿠버네티스 헬스 체크(DB와 무관하게 200)
│   ├── src/
│   │   ├── db.php              DB 접속(환경변수 → PDO), 테이블 자동 생성
│   │   └── layout.php          화면 공통, XSS 이스케이프, CSRF, DB 오류 화면
│   └── sql/schema.sql          테이블 정의(참고용, 앱이 첫 접속 때 자동 생성)
└── gitops/overlays/dev/        ← gitops 저장소(saeoll-gitops)에 반영
    ├── mariadb.yaml            방식 A: MariaDB Service + StatefulSet(PVC)
    └── kustomization.yaml      dev overlay 수정 예시 (envFrom Secret, mariadb.yaml 추가)
```

## 2. DB 연동 방식 (핵심)

| 원칙 | 구현 |
| --- | --- |
| 접속 정보는 **소스·Git에 넣지 않는다** | 운영 관리자가 `kubectl create secret`으로 Secret `php-service-db` 생성 |
| 앱은 **환경변수**로 받는다 | gitops overlay에서 Deployment에 `envFrom: secretRef: php-service-db` 추가 → `getenv('DB_HOST')` 등 |
| 환경(dev/prod)마다 다른 DB | `saeoll-dev`, `saeoll-prod` 네임스페이스에 각각 Secret, 각각 다른 DB |
| DB 장애가 웹 Pod 재시작으로 번지지 않게 | 헬스 체크는 `/healthz.php`(DB 미사용). DB 점검은 `/dbcheck.php` |
| 빈 DB에서 바로 동작 | 첫 접속 때 `CREATE TABLE IF NOT EXISTS posts` (`src/db.php`) |
| 한글 | `utf8mb4` (DSN `charset=utf8mb4`, 테이블 `utf8mb4_unicode_ci`) |
| 보안 | PDO prepared statement(SQL 인젝션 방지), `htmlspecialchars` 출력(XSS 방지), 쿠키 기반 CSRF 토큰(세션 불필요, Pod 여러 개 가능), 비밀번호 `password_hash` |

Secret `php-service-db`의 키:

| 키 | 예 (방식 A) | 예 (방식 B) |
| --- | --- | --- |
| `DB_HOST` | `php-service-mariadb` | `mariadb.mariadb.svc.cluster.local` |
| `DB_PORT` | `3306` | `3306` |
| `DB_NAME` | `board` | `saeoll_board` |
| `DB_USER` | `board` | `saeoll_board` |
| `DB_PASSWORD` | 임의 생성 | 임의 생성 |

| 방식 | 장점 | 단점 | 권장 |
| --- | --- | --- | --- |
| **A. 앱 전용 MariaDB** (업체 네임스페이스, gitops) | 업체·환경별 완전 분리, gitops로 재현 | PVC·백업을 직접 관리, 업체 quota 사용(메모리 1Gi) | **dev 테스트, 업체 전용 DB** |
| B. K-PaaS 공용 MariaDB | 설치 없이 빠름 | 플랫폼 DB(포털·Keycloak)와 같은 서버 → 장애·부하 공유 | 빠른 연결 확인용. 운영 데이터에는 비권장 |

> 네트워크: K-PaaS Kyverno 기본 NetworkPolicy는 **같은 네임스페이스 간 통신을 허용**하고, `mariadb` 네임스페이스는
> 정책 대상에서 제외되어 있어 두 방식 모두 추가 NetworkPolicy가 필요 없다.

## 3. 테스트 절차 (dev, 방식 A)

순서: **① Secret → ② gitops(MariaDB·환경변수) → ③ 소스 push**. 순서를 바꿔도 결국 동작하지만,
이 순서면 중간 오류 없이 한 번에 확인된다.

### ①② 자동 (권장): add-db.sh

서버(운영 관리자)에서 한 번 실행하면 ① Secret 생성과 ② gitops 수정(MariaDB 추가·envFrom 연결·push)을 모두 한다.
비밀번호는 자동 생성되어 Secret에만 저장된다(화면·Git에 남지 않음). 다시 실행해도 기존 Secret·파일은 유지된다.

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script
read -rsp 'scmadmin 비밀번호: ' SCM_ADMIN_PASSWORD; echo; export SCM_ADMIN_PASSWORD
./add-db.sh saeoll php-service dev            # 방식 A (dedicated). 방식 B: ... dev shared
```

이미 아래 ①②를 손으로 진행했다면 실행해도 기존 Secret·`mariadb.yaml`·envFrom을 그대로 두고 없는 것만 채운다.
아래 ①②는 스크립트가 하는 일을 손으로 하는 방법(참고용)이다.

### ① Secret 생성 (운영 관리자, 서버)

```bash
NS=saeoll-dev
DB_PW=$(openssl rand -hex 16); ROOT_PW=$(openssl rand -hex 16)
kubectl -n $NS create secret generic php-service-db \
  --from-literal=DB_HOST=php-service-mariadb --from-literal=DB_PORT=3306 \
  --from-literal=DB_NAME=board --from-literal=DB_USER=board --from-literal=DB_PASSWORD="$DB_PW"
kubectl -n $NS create secret generic php-service-mariadb-root --from-literal=password="$ROOT_PW"
unset DB_PW ROOT_PW
kubectl -n $NS get secret php-service-db php-service-mariadb-root
```

> MariaDB는 **처음 시작할 때(빈 볼륨)만** 이 값으로 DB·계정을 만든다. 이후 Secret의 비밀번호만 바꾸면 접속이 실패한다
> (비밀번호를 바꾸려면 DB에서 `ALTER USER` 후 Secret 수정).

### ② gitops 저장소 수정 (MariaDB 추가 + 앱에 환경변수 연결)

`saeoll-gitops` 쓰기 권한이 있는 계정(CI 계정 `saeoll` 또는 운영 관리자)으로:

```bash
git clone https://scm-manager.192.168.20.151.nip.io/scm/git/saeoll-gitops && cd saeoll-gitops
cp ~/Saeoll-PaaS/cicd-portal-deployment/samples/php-board/gitops/overlays/dev/mariadb.yaml apps/php-service/overlays/dev/
vi apps/php-service/overlays/dev/kustomization.yaml
```

`kustomization.yaml`은 **덮어쓰지 말고** 아래 두 부분만 추가한다(`newTag` 줄은 Jenkins가 관리하므로 그대로 둔다).
완성 예시: [`gitops/overlays/dev/kustomization.yaml`](gitops/overlays/dev/kustomization.yaml)

```yaml
resources:
  - ../../base
  - mariadb.yaml                    # 추가
...
patches:
  - target:                         # 기존 Ingress 패치는 그대로 두고 아래 블록 추가
      kind: Deployment
      name: php-service
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/envFrom
        value:
          - secretRef:
              name: php-service-db
```

```bash
git add -A && git commit -m "php-service dev: MariaDB + DB Secret" && git pull --rebase && git push origin HEAD:main
```

Argo CD `saeoll-php-service-dev`가 3분 안에(또는 ⟳ REFRESH) 반영한다. 확인:

```bash
kubectl -n saeoll-dev get pod,pvc
#   php-service-mariadb-0   1/1 Running,  pvc data-php-service-mariadb-0  Bound
kubectl -n saeoll-dev logs php-service-mariadb-0 | grep -i "ready for connections"
```

Argo CD 앱 화면의 트리에 `sts php-service-mariadb`, `svc php-service-mariadb`가 추가되고 Healthy여야 한다.

### ③ 소스 저장소(saeoll)에 게시판 소스 반영

개발자 PC의 saeoll 클론 폴더(develop 브랜치)에서:

```bash
git checkout develop && git pull
SAMPLE=~/Saeoll-PaaS/cicd-portal-deployment/samples/php-board/app     # 샘플 경로
cp -r "$SAMPLE/public" "$SAMPLE/src" "$SAMPLE/sql" .
grep -n '^FROM' Dockerfile           # php:8.3-apache-bookworm 이어야 함 (pdo_mysql 설치 포함)
git add public src sql && git commit -m "MariaDB 게시판 샘플" && git push origin develop
```

- `composer.json`은 기존 것을 그대로 쓴다(새로 덮으면 `composer.lock`과 맞지 않아 빌드 검증에서 실패할 수 있음).
- Dockerfile의 `RUN docker-php-ext-install pdo_mysql opcache`가 PDO MySQL 드라이버를 설치한다. 기존 Dockerfile을
  다른 내용으로 바꿨다면 이 줄이 있는지 확인한다.

Jenkins `saeoll/php-service-dev`가 5분 안에 빌드(또는 **Build Now**) → 이미지 갱신 → Argo CD가 새 Pod 배포.

### ④ 동작 확인

| 확인 | 방법 | 기대 결과 |
| --- | --- | --- |
| DB 연결 | `https://php-service-saeoll-dev.192.168.20.151.nip.io/dbcheck.php` | `"status": "ok"`, `server_version` 11.4.x, `posts` 개수 |
| 목록 | `https://php-service-saeoll-dev.192.168.20.151.nip.io/` | "게시글이 없습니다" |
| 쓰기 | **글쓰기** → 제목·작성자·비밀번호·내용 → 등록 | 보기 화면으로 이동 |
| 조회수 | 보기 화면 새로고침 | 조회 수 증가 |
| 수정 | **수정** → 틀린 비밀번호 / 맞는 비밀번호 | "비밀번호가 일치하지 않습니다" / 저장 |
| 검색·페이지 | 글 11개 이상 작성 후 검색창·페이지 번호 | 결과 건수·2페이지 |
| 삭제 | 보기 화면 아래 비밀번호 입력 → 삭제 | 목록으로 이동, 글 없어짐 |
| 보안 | 제목에 `<script>alert(1)</script>` 입력 | 실행되지 않고 글자 그대로 보임 |

DB에서 직접 확인:

```bash
kubectl -n saeoll-dev exec -it php-service-mariadb-0 -- sh -c \
  'mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE" -e "SELECT id,title,author,views,created_at FROM posts"'
```

### ⑤ 장애·지속성 테스트

| 테스트 | 명령 | 기대 결과 |
| --- | --- | --- |
| 웹 Pod 재시작 | `kubectl -n saeoll-dev delete pod -l app=php-service` | 새 Pod 기동 후 글 그대로 |
| DB Pod 재시작 | `kubectl -n saeoll-dev delete pod php-service-mariadb-0` | 1분 내 복구, 글 그대로 (PVC 보존) |
| DB 중지 | `kubectl -n saeoll-dev scale sts php-service-mariadb --replicas=0` | 게시판은 "DB 연결 오류 … 2002/2005" 화면, `/healthz.php`는 200, 웹 Pod는 **재시작되지 않음** |
| DB 복구 | Argo CD가 자동 복구(selfHeal)하거나 `--replicas=1` | 게시판 정상 |
| 잘못된 비밀번호 | Secret `DB_PASSWORD`를 틀리게 바꾸고 `kubectl -n saeoll-dev rollout restart deploy/php-service` | "1045 사용자 또는 비밀번호 오류". 원래 값으로 되돌리고 다시 restart |

> Secret을 바꾼 뒤에는 앱 Pod를 재시작해야 새 값이 적용된다(환경변수는 Pod 시작 때 읽음).

## 4. 방식 B: K-PaaS 공용 MariaDB 사용 (빠른 확인용)

MariaDB를 설치하지 않고 플랫폼 DB에 **전용 DB·계정**만 만든다. ②의 `mariadb.yaml`·`resources` 추가는 하지 않고
`envFrom` 패치만 넣는다.

자동: `./add-db.sh saeoll php-service dev shared` → DB·계정 `saeoll_php_service_dev`(그 DB에만 권한) 생성,
Secret·gitops 연결까지 한다(K-PaaS MariaDB root 비밀번호는 `cp-portal-vars.sh`의 `DATABASE_USER_PASSWORD`).
손으로 할 때:

```bash
source ~/Saeoll-PaaS/cp-portal-deployment/script/cp-portal-vars.sh      # DATABASE_USER_PASSWORD (K-PaaS MariaDB root)
DB_PW=$(openssl rand -hex 16)
kubectl -n mariadb exec -i mariadb-0 -- env MYSQL_PWD="$DATABASE_USER_PASSWORD" \
  sh -c 'c=$(command -v mariadb || command -v mysql); "$c" -uroot' <<SQL
CREATE DATABASE IF NOT EXISTS saeoll_board CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'saeoll_board'@'%' IDENTIFIED BY '$DB_PW';
GRANT ALL PRIVILEGES ON saeoll_board.* TO 'saeoll_board'@'%';
SQL
kubectl -n saeoll-dev create secret generic php-service-db \
  --from-literal=DB_HOST=mariadb.mariadb.svc.cluster.local --from-literal=DB_PORT=3306 \
  --from-literal=DB_NAME=saeoll_board --from-literal=DB_USER=saeoll_board --from-literal=DB_PASSWORD="$DB_PW"
unset DB_PW
```

계정 권한은 `saeoll_board` DB로만 제한한다(포털·Keycloak DB 접근 불가). 테스트 후에는 정리한다:
`DROP DATABASE saeoll_board; DROP USER 'saeoll_board'@'%';`

## 5. 운영(prod) 적용 시

1. `./add-db.sh saeoll php-service prod` (dev와 다른 비밀번호의 Secret + gitops `overlays/prod` 변경).
   손으로 할 때: ①과 동일하게 `NS=saeoll-prod`로 Secret 생성, `overlays/prod/`에 ②와 같은 변경 후 push.
2. 이미 있는 DB를 쓸 때(관리형 DB 등):
   `DB_HOST=<주소> DB_NAME=<DB> DB_USER=<계정> DB_PASSWORD=<비밀번호> ./add-db.sh saeoll php-service prod external`
3. 운영 관리자가 Argo CD `saeoll-php-service-prod`에서 **APP DIFF**로 확인 후 SYNC.
4. 백업: 방식 A는 정기 덤프를 받는다(예: `kubectl -n saeoll-prod exec php-service-mariadb-0 -- sh -c 'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction "$MARIADB_DATABASE"' > board-$(date +%F).sql`).
   중요한 운영 데이터는 이중화·백업이 갖춰진 별도 DB(관리형 DB, Galera/Operator 등) 사용을 검토한다.

앱은 세션을 쓰지 않으므로 prod `replicas: 2`에서도 그대로 동작한다.

## 6. 문제 해결

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| 게시판 "DB 연결 오류", `127.0.0.1` 표시 | Secret이 연결되지 않음(envFrom 패치 누락) | ② `kustomization.yaml` 패치 확인, Argo CD Synced 확인 |
| 앱 Pod `CreateContainerConfigError` | Secret `php-service-db` 없음 | ① Secret 생성 |
| `2002` / `2005` | DB 주소 오류, MariaDB 미기동 | `kubectl -n saeoll-dev get pod,svc`, `DB_HOST` 값 |
| `1045` | 계정·비밀번호 불일치 | Secret 값과 DB 계정 확인 (MariaDB는 첫 기동 때 값만 사용) |
| `1049` | DB 없음 | `DB_NAME` 확인, 방식 B는 `CREATE DATABASE` |
| MariaDB Pod·PVC `Pending`, 이벤트 `storageclass ... not found` | `mariadb.yaml`의 `storageClassName`이 클러스터에 없음 | `kubectl get storageclass`로 확인 → gitops `mariadb.yaml`의 `storageClassName` 줄 삭제(기본값 사용) 또는 실제 이름으로 수정 → push 후 `kubectl -n saeoll-dev delete sts php-service-mariadb` + `delete pvc data-php-service-mariadb-0` (볼륨 설정은 변경 불가라 재생성) |
| MariaDB `ImagePullBackOff` | Docker Hub 접근 불가 | Harbor에 `mariadb:11.4` 미러 후 `image` 변경 |
| 빌드 Build 단계 `composer validate` 실패 | `composer.json`을 덮어써 lock과 불일치 | 기존 `composer.json` 복원 |
| `could not find driver` | Dockerfile에 `pdo_mysql` 없음 | `docker-php-ext-install pdo_mysql` 줄 확인 |

## 7. 정리 (테스트 종료 후)

```bash
# gitops에서 mariadb.yaml·resources 줄·envFrom 패치 제거 후 push (Argo CD가 StatefulSet·Service 삭제)
kubectl -n saeoll-dev delete pvc data-php-service-mariadb-0       # 데이터 삭제 (PVC는 자동 삭제되지 않음)
kubectl -n saeoll-dev delete secret php-service-db php-service-mariadb-root
```

## 8. 로컬 실행 (선택)

PHP 8.1+ 와 MariaDB가 있는 PC에서:

```bash
cd app
DB_HOST=127.0.0.1 DB_NAME=board DB_USER=board DB_PASSWORD='...' php -S 127.0.0.1:8080 -t public
# http://127.0.0.1:8080/dbcheck.php
```
