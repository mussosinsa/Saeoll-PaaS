package kr.saeoll.board;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * Board REST API, same contract as samples/node-board (used by samples/vue-board):
 * GET /api/posts?q=&page=, GET/PUT/DELETE /api/posts/{id}, POST /api/posts.
 */
@RestController
@RequestMapping("/api/posts")
public class PostController {

    static final int PER_PAGE = 10;

    public record PostForm(String title, String author, String content, String password) {
    }

    private final PostRepository posts;
    private final BCryptPasswordEncoder encoder = new BCryptPasswordEncoder();

    public PostController(PostRepository posts) {
        this.posts = posts;
    }

    @GetMapping
    public Map<String, Object> list(@RequestParam(defaultValue = "") String q,
                                    @RequestParam(defaultValue = "1") int page) {
        q = q.trim();
        long total = posts.count(q);
        int pages = (int) Math.max(1, (total + PER_PAGE - 1) / PER_PAGE);
        page = Math.min(Math.max(1, page), pages);
        return Map.of("total", total, "page", page, "pages", pages, "items", posts.list(q, page, PER_PAGE));
    }

    @GetMapping("/{id}")
    public ResponseEntity<?> view(@PathVariable long id) {
        posts.countView(id);
        return posts.find(id).<ResponseEntity<?>>map(ResponseEntity::ok).orElseGet(PostController::notFound);
    }

    @PostMapping
    public ResponseEntity<?> create(@RequestBody PostForm form) {
        List<String> errors = validate(form, true);
        if (!errors.isEmpty()) {
            return ResponseEntity.badRequest().body(Map.of("errors", errors));
        }
        long id = posts.create(form.title().trim(), form.content().trim(), form.author().trim(),
                encoder.encode(form.password()));
        return ResponseEntity.status(HttpStatus.CREATED).body(Map.of("id", id));
    }

    @PutMapping("/{id}")
    public ResponseEntity<?> update(@PathVariable long id, @RequestBody PostForm form) {
        var post = posts.find(id);
        if (post.isEmpty()) {
            return notFound();
        }
        if (!passwordMatches(form.password(), post.get())) {
            return forbidden();
        }
        List<String> errors = validate(form, false);
        if (!errors.isEmpty()) {
            return ResponseEntity.badRequest().body(Map.of("errors", errors));
        }
        posts.update(id, form.title().trim(), form.content().trim(), form.author().trim());
        return ResponseEntity.ok(posts.find(id).orElseThrow());
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<?> delete(@PathVariable long id, @RequestBody(required = false) PostForm form) {
        var post = posts.find(id);
        if (post.isEmpty()) {
            return notFound();
        }
        if (form == null || !passwordMatches(form.password(), post.get())) {
            return forbidden();
        }
        posts.delete(id);
        return ResponseEntity.noContent().build();
    }

    private boolean passwordMatches(String password, Post post) {
        return password != null && encoder.matches(password, post.passwordHash());
    }

    static List<String> validate(PostForm f, boolean needPassword) {
        List<String> errors = new ArrayList<>();
        if (blankOrLonger(f.title(), 200)) errors.add("제목은 1~200자로 입력하세요.");
        if (blankOrLonger(f.author(), 50)) errors.add("작성자는 1~50자로 입력하세요.");
        if (blankOrLonger(f.content(), 10000)) errors.add("내용은 1~10,000자로 입력하세요.");
        if (needPassword && (f.password() == null || f.password().length() < 4 || f.password().length() > 64)) {
            errors.add("비밀번호는 4~64자로 입력하세요.");
        }
        return errors;
    }

    private static boolean blankOrLonger(String s, int max) {
        return s == null || s.isBlank() || s.trim().length() > max;
    }

    private static ResponseEntity<?> notFound() {
        return ResponseEntity.status(HttpStatus.NOT_FOUND).body(Map.of("errors", List.of("글을 찾을 수 없습니다.")));
    }

    private static ResponseEntity<?> forbidden() {
        return ResponseEntity.status(HttpStatus.FORBIDDEN).body(Map.of("errors", List.of("비밀번호가 일치하지 않습니다.")));
    }
}
