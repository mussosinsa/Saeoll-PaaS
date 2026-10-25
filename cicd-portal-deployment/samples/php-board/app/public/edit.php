<?php
declare(strict_types=1);

require_once __DIR__ . '/../src/layout.php';

run_page(function (): void {
    $id = (int) ($_GET['id'] ?? $_POST['id'] ?? 0);
    $post = find_post($id);
    if ($post === null) {
        http_response_code(404);
        page_header('없는 글');
        echo '<p class="error">글을 찾을 수 없습니다.</p><p><a href="/">목록</a></p>';
        page_footer();
        return;
    }
    $v = $post;
    $errors = [];
    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        require_csrf();
        [$v, $errors] = read_post_form(false);
        if (!password_verify($v['password'], $post['password_hash'])) {
            $errors[] = '비밀번호가 일치하지 않습니다.';
        }
        if (!$errors) {
            db()->prepare('UPDATE posts SET title = ?, content = ?, author = ? WHERE id = ?')
                ->execute([$v['title'], $v['content'], $v['author'], $id]);
            redirect('/view.php?id=' . $id);
        }
    }
    page_header('수정');
    foreach ($errors as $err) echo '<p class="error">' . e($err) . '</p>';
    echo '<form method="post">' . csrf_field() . '<input type="hidden" name="id" value="' . $id . '">'
       . '<label>제목<input type="text" name="title" maxlength="200" value="' . e($v['title']) . '" required></label>'
       . '<label>작성자<input type="text" name="author" maxlength="50" value="' . e($v['author']) . '" required></label>'
       . '<label>비밀번호 (작성 시 입력한 값)<input type="password" name="password" required></label>'
       . '<label>내용<textarea name="content" required>' . e($v['content']) . '</textarea></label>'
       . '<button class="btn" type="submit">저장</button> <a class="btn gray" href="/view.php?id=' . $id . '">취소</a></form>';
    page_footer();
});
