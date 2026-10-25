<?php
declare(strict_types=1);

// DB connection check (JSON). Not used as the Kubernetes health check: a DB outage must not
// restart the web pods. Kubernetes probes use /healthz.php.
require_once __DIR__ . '/../src/db.php';

header('Content-Type: application/json; charset=utf-8');
$c = db_config();
$result = ['db_host' => $c['host'], 'db_port' => $c['port'], 'db_name' => $c['name'], 'db_user' => $c['user'],
           'password_set' => $c['password'] !== ''];
try {
    $started = microtime(true);
    $pdo = db();
    $result['status'] = 'ok';
    $result['server_version'] = $pdo->query('SELECT VERSION()')->fetchColumn();
    $result['posts'] = (int) $pdo->query('SELECT COUNT(*) FROM posts')->fetchColumn();
    $result['elapsed_ms'] = (int) round((microtime(true) - $started) * 1000);
} catch (PDOException $ex) {
    http_response_code(503);
    error_log('[php-board] dbcheck: ' . $ex->getMessage());
    $result['status'] = 'error';
    $result['error_code'] = (int) ($ex->errorInfo[1] ?? 0);
    $result['error'] = $ex->getMessage();
}
echo json_encode($result, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT), "\n";
