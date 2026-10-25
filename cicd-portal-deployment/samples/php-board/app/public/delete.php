<?php
declare(strict_types=1);

require_once __DIR__ . '/../src/layout.php';

run_page(function (): void {
    if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
        redirect('/');
    }
    require_csrf();
    $id = (int) ($_POST['id'] ?? 0);
    $post = find_post($id);
    if ($post !== null && password_verify((string) ($_POST['password'] ?? ''), $post['password_hash'])) {
        db()->prepare('DELETE FROM posts WHERE id = ?')->execute([$id]);
        redirect('/');
    }
    http_response_code($post === null ? 404 : 403);
    page_header('삭제 실패');
    echo '<p class="error">' . ($post === null ? '글을 찾을 수 없습니다.' : '비밀번호가 일치하지 않습니다.') . '</p>';
    echo '<p><a href="' . ($post === null ? '/' : '/view.php?id=' . $id) . '">돌아가기</a></p>';
    page_footer();
});
