package kr.saeoll.board;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.sql.Timestamp;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import org.springframework.jdbc.core.ConnectionCallback;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.support.GeneratedKeyHolder;
import org.springframework.stereotype.Repository;

/** posts table on MariaDB (JdbcTemplate). The table is created on first use, so an empty database works. */
@Repository
public class PostRepository {

    static final String SCHEMA = """
            CREATE TABLE IF NOT EXISTS posts (
              id            INT UNSIGNED NOT NULL AUTO_INCREMENT,
              title         VARCHAR(200) NOT NULL,
              content       TEXT         NOT NULL,
              author        VARCHAR(50)  NOT NULL,
              password_hash VARCHAR(255) NOT NULL,
              views         INT UNSIGNED NOT NULL DEFAULT 0,
              created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
              updated_at    DATETIME     NULL     ON UPDATE CURRENT_TIMESTAMP,
              PRIMARY KEY (id),
              KEY idx_created_at (created_at)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci""";

    private static final RowMapper<Post> MAPPER = (ResultSet rs, int n) -> new Post(
            rs.getLong("id"), rs.getString("title"), column(rs, "content"), rs.getString("author"),
            rs.getLong("views"), text(rs.getTimestamp("created_at")), text(timestamp(rs, "updated_at")),
            column(rs, "password_hash"));

    private final JdbcTemplate jdbc;
    private volatile boolean schemaReady;

    public PostRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    private JdbcTemplate db() {
        if (!schemaReady) {
            synchronized (this) {
                if (!schemaReady) {
                    jdbc.execute(SCHEMA);
                    schemaReady = true;
                }
            }
        }
        return jdbc;
    }

    public long count(String q) {
        List<Object> params = new ArrayList<>();
        Long n = db().queryForObject("SELECT COUNT(*) FROM posts" + where(q, params), Long.class, params.toArray());
        return n == null ? 0 : n;
    }

    public List<Post> list(String q, int page, int perPage) {
        List<Object> params = new ArrayList<>();
        String sql = "SELECT id, title, author, views, created_at FROM posts" + where(q, params)
                + " ORDER BY id DESC LIMIT ? OFFSET ?";
        params.add(perPage);
        params.add((page - 1) * perPage);
        return db().query(sql, MAPPER, params.toArray());
    }

    public Optional<Post> find(long id) {
        return db().query("SELECT * FROM posts WHERE id = ?", MAPPER, id).stream().findFirst();
    }

    public void countView(long id) {
        db().update("UPDATE posts SET views = views + 1, updated_at = updated_at WHERE id = ?", id);
    }

    public long create(String title, String content, String author, String passwordHash) {
        GeneratedKeyHolder keys = new GeneratedKeyHolder();
        db().update(con -> {
            var ps = con.prepareStatement("INSERT INTO posts (title, content, author, password_hash) VALUES (?, ?, ?, ?)",
                    Statement.RETURN_GENERATED_KEYS);
            ps.setString(1, title);
            ps.setString(2, content);
            ps.setString(3, author);
            ps.setString(4, passwordHash);
            return ps;
        }, keys);
        Map<String, Object> k = keys.getKeys();
        Object id = k != null && !k.isEmpty() ? k.values().iterator().next() : keys.getKey();
        return ((Number) id).longValue();
    }

    public void update(long id, String title, String content, String author) {
        db().update("UPDATE posts SET title = ?, content = ?, author = ? WHERE id = ?", title, content, author, id);
    }

    public void delete(long id) {
        db().update("DELETE FROM posts WHERE id = ?", id);
    }

    public Map<String, Object> check() {
        String version = db().execute((ConnectionCallback<String>) con -> con.getMetaData().getDatabaseProductVersion());
        Long posts = db().queryForObject("SELECT COUNT(*) FROM posts", Long.class);
        return Map.of("server_version", version, "posts", posts == null ? 0 : posts);
    }

    private static String where(String q, List<Object> params) {
        if (q == null || q.isBlank()) {
            return "";
        }
        String like = "%" + q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%";
        params.add(like);
        params.add(like);
        return " WHERE title LIKE ? OR content LIKE ?";
    }

    private static String column(ResultSet rs, String name) throws SQLException {
        return hasColumn(rs, name) ? rs.getString(name) : null;
    }

    private static Timestamp timestamp(ResultSet rs, String name) throws SQLException {
        return hasColumn(rs, name) ? rs.getTimestamp(name) : null;
    }

    private static boolean hasColumn(ResultSet rs, String name) throws SQLException {
        var meta = rs.getMetaData();
        for (int i = 1; i <= meta.getColumnCount(); i++) {
            if (name.equalsIgnoreCase(meta.getColumnLabel(i))) {
                return true;
            }
        }
        return false;
    }

    private static String text(Timestamp t) {
        return t == null ? null : t.toLocalDateTime().withNano(0).toString().replace('T', ' ');
    }
}
