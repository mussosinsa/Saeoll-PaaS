# vue-board (Vue 3 + nginx)

Vue 3 게시판 화면. 빌드 결과를 nginx가 제공하고 `/api/`를 같은 네임스페이스의 백엔드(node-board 기본, spring-board 선택)로
프록시한다. DB는 쓰지 않는다. 배포 방법: [샘플 README](../README.md) 2장 (유형 `vue`).

```text
package.json, package-lock.json   vue 3.5, vite 6
index.html, src/main.js, src/App.vue    해시 라우팅(#/, #/posts/:id, #/write, #/posts/:id/edit), 하단에 API·DB 상태
src/components/PostList.vue       목록·검색·페이지
src/components/PostView.vue       보기·삭제(비밀번호)
src/components/PostForm.vue       글쓰기·수정(비밀번호)
src/api.js                        /api 호출, 오류 메시지 처리
vite.config.js                    npm run dev 시 /api → VITE_API_TARGET (기본 http://127.0.0.1:8080)
nginx/default.conf.template       8080, /healthz, /api/ 프록시, SPA 폴백
nginx/05-api-upstream.envsh       API_UPSTREAM = http://<API_SERVICE>[-dev|-prod].<Pod 네임스페이스>.svc.cluster.local
Dockerfile                        node:20-alpine 로 빌드 → nginx:1.27-alpine (ENV API_SERVICE=node-board)
```

| 환경변수 | 기본값 | 설명 |
| --- | --- | --- |
| `API_SERVICE` | `node-board` | 같은 네임스페이스의 백엔드 Service 이름 (`spring-board`로 변경 가능) 
|  |  | 업체가 `--namespace single`이면 이 Pod의 환경에 맞춰 `-dev`/`-prod`를 자동으로 붙임 (`node-board-dev`) |
| `API_UPSTREAM` | (자동) | 직접 지정 시 전체 URL (예: `http://node-board.saeoll-dev.svc.cluster.local`) |

nginx는 API 주소를 요청할 때마다 조회하므로 백엔드가 아직 없어도 기동한다(그동안 화면에 "API 서버에 연결할 수 없습니다").

## 로컬 실행

```bash
npm ci
VITE_API_TARGET=http://127.0.0.1:8080 npm run dev     # node-board 또는 spring-board 를 8080에 띄운 상태
npm run build                                         # dist/
```
