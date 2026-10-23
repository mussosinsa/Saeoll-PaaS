<?php
declare(strict_types=1);

header('Content-Type: application/json');
echo json_encode([
    'app' => getenv('APP_NAME') ?: 'php-sample',
    'php' => PHP_VERSION,
    'host' => gethostname(),
    'time' => date(DATE_ATOM),
]);
