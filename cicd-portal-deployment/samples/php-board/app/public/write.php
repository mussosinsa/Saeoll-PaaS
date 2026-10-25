<?php
declare(strict_types=1);

require_once __DIR__ . '/../src/layout.php';

run_page(function (): void {
    $v = ['title' => '', 'author' => '', 'content' => ''];
    $errors = [];
    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        require_csrf();
        [$v, $errors] = read_post_form(true);
        if (!$errors) {
            db()->prepare('INSERT INTO posts (title, content, author, password_hash) VALUES (?, ?, ?, ?)')
                ->execute([$v['title'], $v['content'], $v['author'], password_hash($v['password'], PASSWORD_DEFAULT)]);
            redirect('/view.php?id=' . (int) db()->lastInsertId());
        }
    }
    page_header('글쓰기');
    foreach ($errors as $err) echo '<p class="error">' . e($err) . '</p>';
    echo '<form method="post">' . csrf_field()
       . '<label>제목<input type="text" name="title" maxlength="200" value="' . e($v['title']) . '" required></label>'
       . '<label>작성자<input type="text" name="author" maxlength="50" value="' . e($v['author']) . '" required></label>'
       . '<label>비밀번호 (수정·삭제용)<input type="password" name="password" minlength="4" maxlength="64" required></label>'
       . '<label>내용<textarea name="content" required>' . e($v['content']) . '</textarea></label>'
       . '<button class="btn" type="submit">등록</button> <a class="btn gray" href="/">취소</a></form>';
    page_footer();
});
