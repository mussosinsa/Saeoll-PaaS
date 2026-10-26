package kr.saeoll.board;

import java.sql.SQLException;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.bind.annotation.RestControllerAdvice;

/** /healthz (Kubernetes probe, no DB), /api/dbcheck (DB check) and DB error responses. */
@RestController
@RestControllerAdvice
public class StatusController {

    private static final Logger log = LoggerFactory.getLogger(StatusController.class);

    private final PostRepository posts;
    @Value("${DB_HOST:127.0.0.1}") private String dbHost;
    @Value("${DB_PORT:3306}") private int dbPort;
    @Value("${DB_NAME:board}") private String dbName;
    @Value("${DB_USER:board}") private String dbUser;
    @Value("${DB_PASSWORD:}") private String dbPassword;
    @Value("${APP_NAME:spring-board}") private String appName;

    public StatusController(PostRepository posts) {
        this.posts = posts;
    }

    @GetMapping("/healthz")
    public String healthz() {
        return "ok";
    }

    @GetMapping("/")
    public Map<String, String> index() {
        return Map.of("app", appName, "api", "/api/posts", "dbcheck", "/api/dbcheck");
    }

    @GetMapping("/api/dbcheck")
    public ResponseEntity<Map<String, Object>> dbcheck() {
        Map<String, Object> r = new LinkedHashMap<>();
        r.put("db_host", dbHost);
        r.put("db_port", dbPort);
        r.put("db_name", dbName);
        r.put("db_user", dbUser);
        r.put("password_set", !dbPassword.isEmpty());
        try {
            long started = System.currentTimeMillis();
            Map<String, Object> c = posts.check();
            r.put("status", "ok");
            r.putAll(c);
            r.put("elapsed_ms", System.currentTimeMillis() - started);
            return ResponseEntity.ok(r);
        } catch (DataAccessException e) {
            log.error("dbcheck: {}", e.getMostSpecificCause().getMessage());
            r.put("status", "error");
            r.put("error", hint(e));
            return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body(r);
        }
    }

    @ExceptionHandler(DataAccessException.class)
    public ResponseEntity<Map<String, Object>> databaseError(DataAccessException e) {
        log.error("database error: {}", e.getMostSpecificCause().getMessage());
        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE)
                .body(Map.of("errors", List.of("데이터베이스에 연결할 수 없습니다."), "cause", hint(e)));
    }

    /** MariaDB error -> hint (same wording as samples/php-board) */
    static String hint(DataAccessException e) {
        Throwable cause = e.getMostSpecificCause();
        int code = cause instanceof SQLException sql ? sql.getErrorCode() : 0;
        String message = String.valueOf(cause.getMessage());
        if (code == 1045) return "1045 사용자 또는 비밀번호 오류 (DB_USER / DB_PASSWORD)";
        if (code == 1049) return "1049 데이터베이스 없음 (DB_NAME)";
        if (message.contains("UnknownHost") || message.contains("unknown host")) return "2005 호스트 이름을 찾을 수 없음 (DB_HOST)";
        if (message.contains("Connection refused") || message.contains("timed out") || message.contains("Socket fail")) {
            return "2002 서버에 접속할 수 없음 (DB_HOST / DB_PORT, MariaDB Pod 상태)";
        }
        return message;
    }
}
