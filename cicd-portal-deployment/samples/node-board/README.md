# node-board (Node.js + MariaDB)

Node.js 20 게시판 REST API(프레임워크 없이 `node:http`, DB 드라이버 `mariadb`). 배포 방법: [샘플 README](../README.md) 2장 (유형 `node`).

```text
package.json, package-lock.json   의존성: mariadb / npm test = node --test
Dockerfile                        node:20-alpine, npm ci --omit=dev, 8080, 사용자 node
server.js                         HTTP 서버 8080, SIGTERM 시 정상 종료
src/app.js                        라우팅·검증·비밀번호(scrypt)·DB 오류 → 503 + 원인
src/db.js                         MariaDB 풀(DB_* 환경변수, 지연 연결), posts 테이블 자동 생성
test/app.test.js                  메모리 저장소로 API 테스트 (DB 불필요)
```

Jenkins(포털 Jenkinsfile): Build `npm ci` → Test `npm test` → Image(kaniko).

## 로컬 실행

```bash
npm ci && npm test
DB_HOST=127.0.0.1 DB_NAME=board DB_USER=board DB_PASSWORD='...' PORT=8080 npm start
curl localhost:8080/api/dbcheck
```
