# spring-board (Java Spring Boot + MariaDB)

Spring Boot 3.3 (Java 17, Gradle) 게시판 REST API. 배포 방법: [샘플 README](../README.md) 2장 (유형 `java-gradle`).

```text
build.gradle, settings.gradle   Spring Boot 3.3.5: web, jdbc, spring-security-crypto(BCrypt), mariadb-java-client / 테스트 H2
Dockerfile                      gradle:8.10-jdk17 로 bootJar → eclipse-temurin:17-jre, 8080, 비루트(10001)
src/main/java/kr/saeoll/board/
  BoardApplication.java         시작 클래스
  PostRepository.java           JdbcTemplate, posts 테이블 자동 생성(첫 사용 시)
  PostController.java           /api/posts CRUD, 입력 검증, 비밀번호 확인
  StatusController.java         /healthz, /, /api/dbcheck, DB 오류 → 503 + 원인(1045/1049/2002/2005)
  Post.java                     응답 객체 (passwordHash 는 응답에서 제외)
src/main/resources/application.properties
                                jdbc:mariadb://${DB_HOST}:${DB_PORT}/${DB_NAME}, ${DB_USER}/${DB_PASSWORD}
                                DB 없이도 기동(hikari initialization-fail-timeout=-1)
src/test/java/.../BoardApplicationTest.java   MockMvc + H2(MariaDB 모드): healthz, dbcheck, CRUD·비밀번호
```

Jenkins(포털 Jenkinsfile): Build `gradle assemble` → Test `gradle check`(H2, DB 불필요, JUnit 리포트) → Image(kaniko).

## 로컬 실행

```bash
gradle check                                   # 테스트 (JDK 17 이상)
gradle bootJar
DB_HOST=127.0.0.1 DB_NAME=board DB_USER=board DB_PASSWORD='...' java -jar build/libs/spring-board-1.0.0.jar
curl localhost:8080/api/dbcheck
```

다른 DB(예: PostgreSQL)를 쓰려면 드라이버와 `spring.datasource.url`, `PostRepository.SCHEMA`를 바꾼다.
