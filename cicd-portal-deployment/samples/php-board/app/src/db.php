<?php
declare(strict_types=1);

// MariaDB connection from environment variables (Kubernetes Secret -> Deployment env):
//   DB_HOST, DB_PORT (3306), DB_NAME, DB_USER, DB_PASSWORD
// Never put the password in the source or the gitops repository.

function db_config(): array
{
    return [
        'host' => getenv('DB_HOST') ?: '127.0.0.1',
        'port' => (int) (getenv('DB_PORT') ?: 3306),
        'name' => getenv('DB_NAME') ?: 'board',
        'user' => getenv('DB_USER') ?: 'board',
        'password' => getenv('DB_PASSWORD') ?: '',
    ];
}

function db(): PDO
{
    static $pdo = null;
    if ($pdo instanceof PDO) {
        return $pdo;
    }
    $c = db_config();
    $dsn = sprintf('mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4', $c['host'], $c['port'], $c['name']);
    $pdo = new PDO($dsn, $c['user'], $c['password'], [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        PDO::ATTR_EMULATE_PREPARES => false,
        PDO::ATTR_TIMEOUT => 5,
    ]);
    ensure_schema($pdo);
    return $pdo;
}

// Creates the table on first use, so a new empty database works without a manual SQL step
// (same statement as sql/schema.sql).
function ensure_schema(PDO $pdo): void
{
    $pdo->exec(<<<'SQL'
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
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
        SQL);
}

function find_post(int $id): ?array
{
    $stmt = db()->prepare('SELECT * FROM posts WHERE id = ?');
    $stmt->execute([$id]);
    $post = $stmt->fetch();
    return $post ?: null;
}
