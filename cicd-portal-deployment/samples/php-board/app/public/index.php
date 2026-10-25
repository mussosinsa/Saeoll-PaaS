<?php
declare(strict_types=1);

require_once __DIR__ . '/../src/layout.php';

run_page(function (): void {
    $perPage = 10;
    $q = trim((string) ($_GET['q'] ?? ''));
    $page = max(1, (int) ($_GET['page'] ?? 1));

    $where = '';
    $params = [];
    if ($q !== '') {
        $where = 'WHERE title LIKE ? OR content LIKE ?';
        $like = '%' . addcslashes($q, '%_\\') . '%';
        $params = [$like, $like];
    }
    $count = db()->prepare("SELECT COUNT(*) FROM posts $where");
    $count->execute($params);
    $total = (int) $count->fetchColumn();
    $pages = max(1, (int) ceil($total / $perPage));
    $page = min($page, $pages);

    $list = db()->prepare("SELECT id, title, author, views, created_at FROM posts $where
                           ORDER BY id DESC LIMIT $perPage OFFSET " . (($page - 1) * $perPage));
    $list->execute($params);
    $rows = $list->fetchAll();

    page_header('목록');
    echo '<form method="get"><input type="text" name="q" value="' . e($q) . '" placeholder="제목·내용 검색"></form>';
    echo '<p class="meta">전체 ' . $total . '건</p>';
    echo '<table><tr><th class="num">번호</th><th>제목</th><th>작성자</th><th>작성일</th><th class="num">조회</th></tr>';
    if (!$rows) {
        echo '<tr><td colspan="5">게시글이 없습니다. <a href="/write.php">첫 글을 작성</a>해 보세요.</td></tr>';
    }
    foreach ($rows as $r) {
        echo '<tr><td class="num">' . (int) $r['id'] . '</td>'
           . '<td><a href="/view.php?id=' . (int) $r['id'] . '">' . e($r['title']) . '</a></td>'
           . '<td>' . e($r['author']) . '</td><td>' . e(substr((string) $r['created_at'], 0, 16)) . '</td>'
           . '<td class="num">' . (int) $r['views'] . '</td></tr>';
    }
    echo '</table><p class="pager">';
    for ($i = 1; $i <= $pages; $i++) {
        echo $i === $page ? "<strong>$i</strong>"
                          : '<a href="/?page=' . $i . ($q !== '' ? '&amp;q=' . urlencode($q) : '') . '">' . $i . '</a>';
    }
    echo '</p>';
    page_footer();
});
