<?php
declare(strict_types=1);

require_once __DIR__ . '/db.php';

function e(?string $s): string
{
    return htmlspecialchars((string) $s, ENT_QUOTES, 'UTF-8');
}

function redirect(string $url): never
{
    header('Location: ' . $url, true, 303);
    exit;
}

// CSRF protection without server sessions (works with several replicas):
// a random token in a cookie that every form must send back.
function csrf_token(): string
{
    static $token = null;
    if ($token === null) {
        $token = $_COOKIE['csrf'] ?? '';
        if (!preg_match('/^[a-f0-9]{64}$/', $token)) {
            $token = bin2hex(random_bytes(32));
            setcookie('csrf', $token, ['path' => '/', 'httponly' => true, 'samesite' => 'Strict',
                                       'secure' => ($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https']);
        }
    }
    return $token;
}

function csrf_field(): string
{
    return '<input type="hidden" name="csrf" value="' . e(csrf_token()) . '">';
}

function require_csrf(): void
{
    $cookie = $_COOKIE['csrf'] ?? '';
    $sent = $_POST['csrf'] ?? '';
    if ($cookie === '' || !is_string($sent) || !hash_equals($cookie, $sent)) {
        http_response_code(400);
        page_header('잘못된 요청');
        echo '<p class="error">요청이 만료되었습니다. 이전 화면을 새로고침한 뒤 다시 시도하세요.</p>';
        page_footer();
        exit;
    }
}

// Form values: title, content, author (+ password). Returns [values, errors].
function read_post_form(bool $needPassword): array
{
    $v = [];
    foreach (['title' => 200, 'author' => 50, 'content' => 10000, 'password' => 64] as $field => $max) {
        $v[$field] = trim((string) ($_POST[$field] ?? ''));
    }
    $errors = [];
    if ($v['title'] === '' || mb_strlen($v['title']) > 200) $errors[] = '제목은 1~200자로 입력하세요.';
    if ($v['author'] === '' || mb_strlen($v['author']) > 50) $errors[] = '작성자는 1~50자로 입력하세요.';
    if ($v['content'] === '' || mb_strlen($v['content']) > 10000) $errors[] = '내용은 1~10,000자로 입력하세요.';
    if ($needPassword && (mb_strlen($v['password']) < 4 || mb_strlen($v['password']) > 64)) {
        $errors[] = '비밀번호는 4~64자로 입력하세요.';
    }
    return [$v, $errors];
}

// Shows a friendly page when MariaDB is unreachable (details go to the container log).
function run_page(callable $page): void
{
    try {
        $page();
    } catch (PDOException $ex) {
        error_log('[php-board] database error: ' . $ex->getMessage());
        http_response_code(503);
        $c = db_config();
        page_header('DB 연결 오류');
        echo '<p class="error">데이터베이스에 연결할 수 없습니다.</p>';
        echo '<p>접속 대상: <code>' . e($c['user']) . '@' . e($c['host']) . ':' . $c['port'] . '/' . e($c['name']) . '</code></p>';
        echo '<p>원인: <code>' . e(db_error_hint($ex)) . '</code></p>';
        echo '<p><a href="/dbcheck.php">DB 연결 점검(JSON)</a></p>';
        page_footer();
    }
}

function db_error_hint(PDOException $ex): string
{
    $code = (int) ($ex->errorInfo[1] ?? 0);
    return match ($code) {
        1045 => '1045 사용자 또는 비밀번호 오류 (DB_USER / DB_PASSWORD)',
        1049 => '1049 데이터베이스 없음 (DB_NAME)',
        2002 => '2002 서버에 접속할 수 없음 (DB_HOST / DB_PORT, MariaDB Pod 상태, NetworkPolicy)',
        2005 => '2005 호스트 이름을 찾을 수 없음 (DB_HOST)',
        default => $code > 0 ? "MariaDB 오류 $code" : $ex->getMessage(),
    };
}

function page_header(string $title): void
{
    $app = getenv('APP_NAME') ?: 'PHP 게시판';
    echo '<!doctype html><html lang="ko"><head><meta charset="utf-8">';
    echo '<meta name="viewport" content="width=device-width, initial-scale=1">';
    echo '<title>' . e($title) . ' - ' . e($app) . '</title>';
    echo '<style>
      body{font-family:system-ui,"Malgun Gothic",sans-serif;max-width:860px;margin:0 auto;padding:16px;color:#222}
      header{display:flex;justify-content:space-between;align-items:center;border-bottom:2px solid #333;margin-bottom:16px}
      header a{color:#222;text-decoration:none}
      table{width:100%;border-collapse:collapse}th,td{padding:8px;border-bottom:1px solid #ddd;text-align:left}
      td.num,th.num{text-align:right;width:70px}a{color:#0b5ed7}
      input[type=text],input[type=password],textarea{width:100%;box-sizing:border-box;padding:8px;margin:4px 0 12px}
      textarea{min-height:220px}.btn{display:inline-block;padding:6px 14px;border:1px solid #0b5ed7;border-radius:4px;background:#0b5ed7;color:#fff;text-decoration:none;cursor:pointer}
      .btn.gray{background:#fff;color:#0b5ed7}.btn.red{background:#dc3545;border-color:#dc3545}
      .error{color:#dc3545}.meta{color:#666;font-size:.9em}.content{white-space:pre-wrap;padding:16px 0;border-bottom:1px solid #ddd}
      .pager a,.pager strong{margin:0 4px}footer{margin-top:32px;color:#888;font-size:.8em}
    </style></head><body>';
    echo '<header><h1><a href="/">' . e($app) . '</a></h1><a class="btn" href="/write.php">글쓰기</a></header>';
}

function page_footer(): void
{
    echo '<footer>host ' . e(gethostname() ?: '') . ' · PHP ' . PHP_VERSION . ' · <a href="/dbcheck.php">DB 점검</a></footer>';
    echo '</body></html>';
}
