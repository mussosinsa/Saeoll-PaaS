<?php
declare(strict_types=1);

require_once __DIR__ . '/../src/layout.php';

run_page(function (): void {
    $id = (int) ($_GET['id'] ?? 0);
    db()->prepare('UPDATE posts SET views = views + 1, updated_at = updated_at WHERE id = ?')->execute([$id]);
    $post = find_post($id);
    if ($post === null) {
        http_response_code(404);
        page_header('없는 글');
        echo '<p class="error">글을 찾을 수 없습니다.</p><p><a href="/">목록</a></p>';
        page_footer();
        return;
    }
    page_header($post['title']);
    echo '<h2>' . e($post['title']) . '</h2>';
    echo '<p class="meta">' . e($post['author']) . ' · ' . e($post['created_at'])
       . ($post['updated_at'] ? ' (수정 ' . e($post['updated_at']) . ')' : '') . ' · 조회 ' . (int) $post['views'] . '</p>';
    echo '<div class="content">' . e($post['content']) . '</div>';
    echo '<p><a class="btn gray" href="/">목록</a> <a class="btn gray" href="/edit.php?id=' . (int) $post['id'] . '">수정</a></p>';
    echo '<form method="post" action="/delete.php">' . csrf_field()
       . '<input type="hidden" name="id" value="' . (int) $post['id'] . '">'
       . '<input type="password" name="password" placeholder="삭제하려면 작성 시 비밀번호 입력" required>'
       . '<button class="btn red" type="submit">삭제</button></form>';
    page_footer();
});
