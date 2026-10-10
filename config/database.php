<?php
declare(strict_types=1);

use App\Core\Env;

$root = dirname(__DIR__);
$path = (string) Env::get('DB_PATH', 'storage/database/lsiams.sqlite');

// A relative DB_PATH is taken from the installation folder, not from wherever
// the command happened to be started, so start.bat, the worker and the console
// all open the same file.
$isAbsolute = str_starts_with($path, '/')
    || str_starts_with($path, '\\')
    || preg_match('/^[A-Za-z]:[\\\\\\/]/', $path) === 1;

return [
    'driver' => 'sqlite',
    'path'   => $isAbsolute ? $path : $root . '/' . $path,

    // Milliseconds a writer waits for another writer to finish before giving
    // up. SQLite lets one connection write at a time, so a tap from a second
    // terminal queues behind the first for the few milliseconds a tap takes.
    // Five seconds is far beyond any real wait and still short enough that a
    // stuck process surfaces as an error instead of a hung request.
    'busy_timeout_ms' => (int) Env::get('DB_BUSY_TIMEOUT_MS', '5000'),

    // Retry policy for a write that still found the database busy after
    // busy_timeout_ms — the SQLite counterpart of the deadlock retry (Part 17.2).
    'deadlock_retry' => [
        'attempts'    => 3,
        'backoff_ms'  => [50, 150, 400],
    ],

    // The MariaDB/MySQL database an older installation used. Read only by
    // `console db:import-mysql`, which copies it into the SQLite file once.
    // These are the same .env keys the MariaDB version used, so an existing
    // .env already points at the right place.
    'mysql_source' => [
        'host'     => Env::get('DB_HOST', '127.0.0.1'),
        'port'     => (int) Env::get('DB_PORT', '3306'),
        'database' => Env::get('DB_NAME', 'lsiams_db'),
        'username' => Env::get('DB_USER', 'lsiams_app'),
        'password' => Env::get('DB_PASS', ''),
        'timezone' => Env::get('APP_TIMEZONE', 'Asia/Manila'),
    ],
];
