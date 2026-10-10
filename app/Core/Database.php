<?php
declare(strict_types=1);

namespace App\Core;

use PDO;
use PDOException;
use PDOStatement;
use RuntimeException;
use Throwable;

/**
 * PDO wrapper for the whole application.
 *
 * Every query in L-SIAMS goes through here, and every one of them is a prepared
 * statement — there is no method on this class that accepts interpolated user
 * input. Transaction helpers implement the retry policy from Part 17.2 so
 * callers never have to reason about a busy database themselves.
 *
 * The store is a single SQLite file (config/database.php). One connection
 * writes at a time; see beginTransaction() for how that stands in for the row
 * locks the MariaDB version took.
 */
final class Database
{
    private static ?Database $instance = null;

    private ?PDO $pdo = null;
    /** @var array<string,mixed> */
    private array $config;
    private int $transactionDepth = 0;
    private int $queryCount = 0;
    private float $queryTime = 0.0;

    /** @param array<string,mixed> $config */
    private function __construct(array $config)
    {
        $this->config = $config;
    }

    public static function instance(): self
    {
        if (self::$instance === null) {
            /** @var array<string,mixed> $config */
            $config = Config::get('database', []);
            self::$instance = new self($config);
        }

        return self::$instance;
    }

    public static function resetInstance(): void
    {
        self::$instance = null;
    }

    public function pdo(): PDO
    {
        if ($this->pdo instanceof PDO) {
            return $this->pdo;
        }

        $path = $this->path();

        $options = [
            PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_STRINGIFY_FETCHES  => false,
            // pdo_sqlite reads this as the busy timeout, in seconds. The
            // PRAGMA below sets the same thing to the millisecond.
            PDO::ATTR_TIMEOUT            => max(1, intdiv($this->busyTimeoutMs(), 1000)),
        ];

        try {
            $directory = dirname($path);

            if (!is_dir($directory) && !@mkdir($directory, 0775, true) && !is_dir($directory)) {
                throw new RuntimeException('The database folder could not be created: ' . $directory);
            }

            // PDO::connect() hands back the driver subclass on PHP 8.4+, which
            // is where createFunction() lives; older versions only have the
            // sqliteCreateFunction() spelling on plain PDO.
            $this->pdo = method_exists(PDO::class, 'connect')
                ? PDO::connect('sqlite:' . $path, null, null, $options)
                : new PDO('sqlite:' . $path, null, null, $options);

            // WAL lets every reader carry on while one connection writes, which
            // is what keeps the dashboard, the realtime server and the worker
            // from queueing behind a tap. It is a property of the file and
            // survives reconnects; asking again is cheap.
            $this->pdo->exec('PRAGMA journal_mode = WAL');
            // NORMAL is the documented safe setting under WAL: a power cut can
            // lose the last moments of commits but never corrupts the file.
            $this->pdo->exec('PRAGMA synchronous = NORMAL');
            // SQLite ships with foreign keys off, per connection. Every
            // relationship in the schema depends on them being enforced.
            $this->pdo->exec('PRAGMA foreign_keys = ON');
            $this->pdo->exec('PRAGMA busy_timeout = ' . $this->busyTimeoutMs());

            self::registerFunctions($this->pdo);
        } catch (PDOException $e) {
            Logger::critical('Database connection failed', ['code' => $e->getCode(), 'path' => $path]);
            $this->pdo = null;
            throw new RuntimeException('Database connection failed.', 0, $e);
        }

        return $this->pdo;
    }

    /** Absolute path of the SQLite file this installation uses. */
    public function path(): string
    {
        return (string) ($this->config['path'] ?? '');
    }

    /** Close the file, so it can be copied or replaced. Reopens on next use. */
    public function disconnect(): void
    {
        $this->pdo              = null;
        $this->transactionDepth = 0;
        $this->columnCache      = null;
    }

    private function busyTimeoutMs(): int
    {
        return max(100, (int) ($this->config['busy_timeout_ms'] ?? 5000));
    }

    /**
     * The handful of MySQL functions the application's SQL still speaks.
     *
     * NOW() and CURDATE() are the important two. SQLite's own CURRENT_TIMESTAMP
     * is UTC, while every stored time in L-SIAMS is local time in
     * APP_TIMEZONE, exactly as MariaDB's NOW() returned it with the session
     * time zone the old connection set. Real time is used, not Clock::now():
     * MariaDB's NOW() never honoured a frozen or shifted application clock
     * either, and code that needs that clock passes it in as a parameter.
     *
     * The rest keep queries readable without rewriting them: CONCAT() is NULL
     * if any argument is (as in MySQL, and unlike a bare ||), FIELD() gives an
     * enum its declared sort order, and TIMESTAMPDIFF() takes its unit as a
     * quoted string because SQLite would read a bare SECOND as a column name.
     */
    public static function registerFunctions(PDO $pdo): void
    {
        $register = static function (string $name, callable $fn, int $args, bool $deterministic) use ($pdo): void {
            $flags = $deterministic ? PDO::SQLITE_DETERMINISTIC : 0;

            if (method_exists($pdo, 'createFunction')) {
                $pdo->createFunction($name, $fn, $args, $flags);
            } else {
                $pdo->sqliteCreateFunction($name, $fn, $args, $flags);
            }
        };

        $register('now', static fn (): string => Clock::real()->format('Y-m-d H:i:s'), 0, false);
        $register('curdate', static fn (): string => Clock::real()->format('Y-m-d'), 0, false);

        $register('concat', static function (mixed ...$parts): ?string {
            foreach ($parts as $part) {
                if ($part === null) {
                    return null;
                }
            }

            return implode('', array_map(static fn (mixed $p): string => (string) $p, $parts));
        }, -1, true);

        $register('field', static function (mixed $needle, mixed ...$list): int {
            if ($needle === null) {
                return 0;
            }

            foreach ($list as $index => $candidate) {
                if ($candidate !== null && strcasecmp((string) $candidate, (string) $needle) === 0) {
                    return $index + 1;
                }
            }

            return 0;
        }, -1, true);

        $register('timestampdiff', static function (mixed $unit, mixed $from, mixed $to): ?int {
            if ($from === null || $to === null) {
                return null;
            }

            $seconds = strtotime((string) $to . ' UTC') - strtotime((string) $from . ' UTC');

            $divisor = match (strtoupper((string) $unit)) {
                'SECOND' => 1,
                'MINUTE' => 60,
                'HOUR'   => 3600,
                'DAY'    => 86400,
                'WEEK'   => 604800,
                default  => throw new RuntimeException('TIMESTAMPDIFF unit not supported: ' . (string) $unit),
            };

            // MySQL truncates toward zero; intdiv does the same.
            return intdiv($seconds, $divisor);
        }, 3, true);

        // floor() and ceil() are part of SQLite's optional math functions,
        // which not every PHP build compiles in. Supplied only where missing.
        try {
            $pdo->query('SELECT floor(1.5), ceil(1.5)');
        } catch (PDOException) {
            $register('floor', static fn (mixed $v): ?float => $v === null ? null : floor((float) $v), 1, true);
            $register('ceil', static fn (mixed $v): ?float => $v === null ? null : ceil((float) $v), 1, true);
        }

        // JSON is compiled into every SQLite PHP has shipped for years, but
        // the CHECK constraints depend on json_valid(), so a build without it
        // gets an equivalent rather than an install that cannot write a log.
        try {
            $pdo->query("SELECT json_valid('{}')");
        } catch (PDOException) {
            $register('json_valid', static function (mixed $value): ?int {
                if ($value === null) {
                    return null;
                }

                json_decode((string) $value);

                return json_last_error() === JSON_ERROR_NONE ? 1 : 0;
            }, 1, true);
        }
    }

    /** @param array<string|int,mixed> $bindings */
    public function query(string $sql, array $bindings = []): PDOStatement
    {
        $started = microtime(true);

        [$sql, $bindings] = self::expandRepeatedPlaceholders($sql, $bindings);

        try {
            $statement = $this->pdo()->prepare($sql);
            $this->bindValues($statement, $bindings);
            $statement->execute();
        } catch (PDOException $e) {
            Logger::error('Query failed', [
                'sql'   => self::redactSql($sql),
                'code'  => $e->getCode(),
                'error' => $e->getMessage(),
            ]);
            throw $e;
        } finally {
            $this->queryCount++;
            $this->queryTime += microtime(true) - $started;
        }

        return $statement;
    }

    /**
     * Give every occurrence of a repeated named placeholder its own name.
     *
     * Emulated prepares let `:now` appear twice in one statement and bind once.
     * Native prepares — which this class insists on, because they are what
     * actually stops SQL injection — do not: the driver sends each marker to the
     * server separately, and a second occurrence with no binding of its own
     * fails with HY093 "Invalid parameter number".
     *
     * Rather than forbid the pattern and rely on every author remembering, the
     * rewrite happens here: `:now` used three times becomes `:now`, `:now__2`,
     * `:now__3`, each bound to the same value. Call sites stay readable, native
     * prepares stay on, and a query that reads naturally cannot fail at runtime
     * for a reason that has nothing to do with its logic.
     *
     * Only genuine placeholders are touched. A `:` inside a quoted literal is
     * skipped, as is `::` (a cast), so rewriting cannot alter what the statement
     * means.
     *
     * @param  array<string|int,mixed> $bindings
     * @return array{0:string, 1:array<string|int,mixed>}
     */
    private static function expandRepeatedPlaceholders(string $sql, array $bindings): array
    {
        // Positional bindings have no names to collide, and a statement with no
        // colon cannot contain a named placeholder. Both are the common case.
        if ($bindings === [] || !str_contains($sql, ':') || array_is_list($bindings)) {
            return [$sql, $bindings];
        }

        $seen  = [];
        $extra = [];

        $rewritten = preg_replace_callback(
            // A quoted literal or a comment is consumed by the first two
            // alternatives so its contents can never match as a placeholder.
            '/\'(?:[^\'\\\\]|\\\\.)*\'|"(?:[^"\\\\]|\\\\.)*"|::|:([a-zA-Z_][a-zA-Z0-9_]*)/',
            static function (array $m) use (&$seen, &$extra, $bindings): string {
                // No captured name: this was a string literal or a cast.
                if (!isset($m[1]) || $m[1] === '') {
                    return $m[0];
                }

                $name  = $m[1];
                $count = ($seen[$name] = ($seen[$name] ?? 0) + 1);

                if ($count === 1) {
                    return ':' . $name;
                }

                // Only rewrite when a value was actually supplied under this
                // name; otherwise leave it alone so the driver reports the
                // missing binding rather than this silently inventing one.
                if (!array_key_exists($name, $bindings) && !array_key_exists(':' . $name, $bindings)) {
                    return $m[0];
                }

                $alias         = $name . '__' . $count;
                $extra[$alias] = $bindings[$name] ?? $bindings[':' . $name];

                return ':' . $alias;
            },
            $sql
        );

        // preg_replace_callback returns null only on a PCRE failure; if that
        // ever happened, running the original statement is the safe fallback.
        if ($rewritten === null || $extra === []) {
            return [$sql, $bindings];
        }

        return [$rewritten, $bindings + $extra];
    }

    /** @param array<string|int,mixed> $bindings */
    private function bindValues(PDOStatement $statement, array $bindings): void
    {
        foreach ($bindings as $key => $value) {
            $param = is_int($key) ? $key + 1 : (str_starts_with($key, ':') ? $key : ':' . $key);

            $type = match (true) {
                is_int($value)  => PDO::PARAM_INT,
                is_bool($value) => PDO::PARAM_BOOL,
                $value === null => PDO::PARAM_NULL,
                default         => PDO::PARAM_STR,
            };

            if ($value instanceof \DateTimeInterface) {
                $value = $value->format('Y-m-d H:i:s');
                $type  = PDO::PARAM_STR;
            }

            $statement->bindValue($param, $value, $type);
        }
    }

    /**
     * @param  array<string|int,mixed> $bindings
     * @return array<string,mixed>|null
     */
    public function selectOne(string $sql, array $bindings = []): ?array
    {
        $row = $this->query($sql, $bindings)->fetch();

        return $row === false ? null : $row;
    }

    /**
     * @param  array<string|int,mixed> $bindings
     * @return list<array<string,mixed>>
     */
    public function select(string $sql, array $bindings = []): array
    {
        /** @var list<array<string,mixed>> $rows */
        $rows = $this->query($sql, $bindings)->fetchAll();

        return $rows;
    }

    /** @param array<string|int,mixed> $bindings */
    public function scalar(string $sql, array $bindings = []): mixed
    {
        $value = $this->query($sql, $bindings)->fetchColumn();

        return $value === false ? null : $value;
    }

    /** @param array<string|int,mixed> $bindings */
    public function execute(string $sql, array $bindings = []): int
    {
        return $this->query($sql, $bindings)->rowCount();
    }

    /**
     * Does this table actually have this column?
     *
     * For the narrow case of a schema that is behind the code — the server
     * files updated but `migrate` not yet run, which happens whenever someone
     * pulls and skips the database step, or restores an older backup over a
     * newer checkout.
     *
     * It exists because of a real outage. A terminal's heartbeat began
     * reporting two new optional fields; on an un-migrated database the
     * UPDATE naming those columns threw, and the endpoint answered 500. The
     * heartbeat is the terminal's lifeline — it is how the server knows the
     * device is alive at all — so an optional telemetry field must never be
     * able to take it down. Skipping a column the schema cannot hold loses
     * one detail; failing the request loses the device.
     *
     * Use this only for genuinely optional data. Anything the system depends
     * on should fail loudly against a schema that cannot store it, and a
     * misspelled required column silently vanishing is far worse than an
     * error.
     *
     * Cached per process: the answer cannot change while a request runs, and
     * this is called on a path that executes every thirty seconds per
     * terminal.
     *
     * @var array<string,bool>|null
     */
    private ?array $columnCache = null;

    /** @var list<string>|null */
    private ?array $pendingMigrationCache = null;

    /**
     * Migration files on disk that this database has never run.
     *
     * The single most likely thing to be wrong after an update, and until now
     * the application said nothing about it: the code expects columns the
     * database does not have yet, so the dashboard, the attendance list and
     * every student and session page answer 500 with "An unexpected error
     * occurred" — which describes a bug, not a database four migrations
     * behind. update.bat runs the migrations, so this only bites somebody who
     * updated another way, which is exactly the person with no reason to
     * suspect it.
     *
     * Deliberately total: any failure here — no table, no directory, no
     * permission — returns an empty list. This runs on the error path and in
     * the layout, and a diagnostic that can itself throw is worse than no
     * diagnostic at all.
     *
     * @return list<string>
     */
    public function pendingMigrations(): array
    {
        if ($this->pendingMigrationCache !== null) {
            return $this->pendingMigrationCache;
        }

        $this->pendingMigrationCache = [];

        try {
            $directory = (string) Config::get('app.paths.migrations', '');

            if ($directory === '' || !is_dir($directory)) {
                return [];
            }

            $files = glob($directory . '/*.sql') ?: [];

            if ($files === []) {
                return [];
            }

            $applied = [];

            foreach ($this->select('SELECT migration FROM schema_migrations') as $row) {
                $applied[(string) $row['migration']] = true;
            }

            $pending = [];

            foreach ($files as $path) {
                $name = basename($path);

                if (!isset($applied[$name])) {
                    $pending[] = $name;
                }
            }

            sort($pending, SORT_NATURAL);

            return $this->pendingMigrationCache = $pending;
        } catch (Throwable) {
            return [];
        }
    }

    /**
     * Ask again next time.
     *
     * The answer cannot change while a request runs, which is why it is cached
     * — but a long-lived process that has just applied a migration, or a test
     * that changes what is applied, needs the cache to let go.
     */
    public function forgetPendingMigrations(): void
    {
        $this->pendingMigrationCache = null;
    }

    public function hasColumn(string $table, string $column): bool
    {
        $key = $table . '.' . $column;

        if ($this->columnCache === null) {
            $this->columnCache = [];
        }

        if (!array_key_exists($key, $this->columnCache)) {
            $this->columnCache[$key] = $this->scalar(
                'SELECT 1 FROM pragma_table_xinfo(:t) WHERE name = :c LIMIT 1',
                ['t' => $table, 'c' => $column]
            ) !== null;
        }

        return $this->columnCache[$key];
    }

    /** @param array<string,mixed> $data */
    public function insert(string $table, array $data): string
    {
        $columns      = array_keys($data);
        $placeholders = array_map(static fn (string $c): string => ':' . $c, $columns);

        $sql = sprintf(
            'INSERT INTO `%s` (%s) VALUES (%s)',
            $table,
            '`' . implode('`, `', $columns) . '`',
            implode(', ', $placeholders)
        );

        $this->query($sql, $data);

        return $this->pdo()->lastInsertId();
    }

    /**
     * @param array<string,mixed>     $data
     * @param array<string,mixed>     $where
     */
    public function update(string $table, array $data, array $where): int
    {
        if ($data === [] || $where === []) {
            throw new RuntimeException('update() requires both data and a where clause.');
        }

        $sets   = [];
        $params = [];

        foreach ($data as $column => $value) {
            $sets[]              = sprintf('`%s` = :set_%s', $column, $column);
            $params['set_' . $column] = $value;
        }

        $conditions = [];
        foreach ($where as $column => $value) {
            $conditions[]              = sprintf('`%s` = :where_%s', $column, $column);
            $params['where_' . $column] = $value;
        }

        $sql = sprintf(
            'UPDATE `%s` SET %s WHERE %s',
            $table,
            implode(', ', $sets),
            implode(' AND ', $conditions)
        );

        return $this->execute($sql, $params);
    }

    // ---------------------------------------------------------------- txn --

    /**
     * Transactions start IMMEDIATE: the write lock is taken at BEGIN, waiting
     * up to busy_timeout_ms for another writer to finish.
     *
     * This is what replaces the row locks (SELECT ... FOR UPDATE) the MariaDB
     * version relied on. SQLite has one writer at a time, so a transaction
     * that holds the write lock from its first statement cannot have the rows
     * it read changed underneath it — the guarantee FOR UPDATE gave, for the
     * whole database rather than a row. A DEFERRED transaction would read
     * first and then try to upgrade to a writer, and under WAL that upgrade
     * fails at once with SQLITE_BUSY instead of waiting.
     *
     * PDO::beginTransaction() always issues a deferred BEGIN, so the statements
     * are sent directly and PDO's own transaction flag is never used.
     */
    public function beginTransaction(): void
    {
        if ($this->transactionDepth === 0) {
            $this->pdo()->exec('BEGIN IMMEDIATE');
        } else {
            $this->pdo()->exec('SAVEPOINT sp_' . $this->transactionDepth);
        }

        $this->transactionDepth++;
    }

    public function commit(): void
    {
        if ($this->transactionDepth === 0) {
            return;
        }

        $this->transactionDepth--;

        if ($this->transactionDepth === 0) {
            $this->pdo()->exec('COMMIT');
        } else {
            $this->pdo()->exec('RELEASE SAVEPOINT sp_' . $this->transactionDepth);
        }
    }

    public function rollBack(): void
    {
        if ($this->transactionDepth === 0) {
            return;
        }

        $this->transactionDepth--;

        if ($this->transactionDepth === 0) {
            // A failed COMMIT, or an error SQLite answered by rolling back on
            // its own, leaves nothing to roll back; asking again would throw
            // over the exception that is already on its way out.
            try {
                $this->pdo()->exec('ROLLBACK');
            } catch (PDOException) {
            }
        } else {
            $this->pdo()->exec('ROLLBACK TO SAVEPOINT sp_' . $this->transactionDepth);
        }
    }

    public function inTransaction(): bool
    {
        return $this->transactionDepth > 0;
    }

    /**
     * Run a closure inside a transaction, retrying when the database stayed
     * busy past its timeout, with the backoff schedule from config. Any other exception rolls
     * back once and propagates — a partially-written attendance record is never
     * acceptable (Part 5, "never partially save attendance").
     *
     * @template T
     * @param  callable(Database):T $callback
     * @return T
     */
    public function transaction(callable $callback): mixed
    {
        /** @var array{attempts:int,backoff_ms:list<int>} $retry */
        $retry    = Config::get('database.deadlock_retry', ['attempts' => 3, 'backoff_ms' => [50, 150, 400]]);
        $attempts = max(1, (int) $retry['attempts']);
        $backoff  = $retry['backoff_ms'];

        for ($attempt = 0; $attempt < $attempts; $attempt++) {
            $this->beginTransaction();

            try {
                $result = $callback($this);
                $this->commit();

                return $result;
            } catch (Throwable $e) {
                $this->rollBack();

                if ($this->isRetryable($e) && $attempt < $attempts - 1) {
                    $sleepMs = $backoff[$attempt] ?? 400;
                    Logger::warning('Database busy, retrying the transaction', [
                        'attempt'  => $attempt + 1,
                        'sleep_ms' => $sleepMs,
                    ]);
                    usleep($sleepMs * 1000);
                    continue;
                }

                throw $e;
            }
        }

        throw new RuntimeException('Transaction exhausted all retry attempts.');
    }

    /**
     * SQLITE_BUSY (5) and SQLITE_LOCKED (6): another connection held the write
     * lock for longer than busy_timeout_ms. Nothing was written, so the whole
     * transaction is safe to run again — the same reasoning the MariaDB
     * version applied to a deadlock.
     */
    private function isRetryable(Throwable $e): bool
    {
        if (!$e instanceof PDOException) {
            return false;
        }

        $driverCode = (int) ($e->errorInfo[1] ?? 0);

        return in_array($driverCode, [5, 6], true)
            || str_contains($e->getMessage(), 'database is locked');
    }

    /** A UNIQUE or PRIMARY KEY constraint refused the row. */
    public static function isDuplicateKey(Throwable $e): bool
    {
        return $e instanceof PDOException
            && (int) ($e->errorInfo[1] ?? 0) === 19
            && str_contains($e->getMessage(), 'UNIQUE constraint failed');
    }

    /**
     * The name of the unique index a duplicate collided with, as the MariaDB
     * schema named it (PRIMARY for a primary key).
     *
     * MySQL put the index name in the error. SQLite names the columns instead
     * — "UNIQUE constraint failed: attendance_records.session_id,
     * attendance_records.student_id" — so the index is found by matching those
     * columns against the table's unique indexes. Callers decide what to tell
     * the user from this name, so it has to be the same name they expect.
     */
    public static function duplicateKeyName(Throwable $e): ?string
    {
        if (!self::isDuplicateKey($e)) {
            return null;
        }

        if (preg_match('/UNIQUE constraint failed: (.+)$/m', $e->getMessage(), $m) !== 1) {
            return null;
        }

        $table   = null;
        $columns = [];

        foreach (explode(',', $m[1]) as $qualified) {
            $parts = explode('.', trim($qualified), 2);

            if (count($parts) !== 2) {
                return null;
            }

            $table     = $parts[0];
            $columns[] = $parts[1];
        }

        if ($table === null || preg_match('/^\w+$/', $table) !== 1) {
            return null;
        }

        try {
            $pdo = self::instance()->pdo();

            foreach ($pdo->query('PRAGMA index_list(' . $table . ')')->fetchAll(PDO::FETCH_ASSOC) as $index) {
                if ((int) $index['unique'] !== 1) {
                    continue;
                }

                $indexed = $pdo->query('PRAGMA index_info(' . $pdo->quote((string) $index['name']) . ')')
                    ->fetchAll(PDO::FETCH_COLUMN, 2);

                if ($indexed !== $columns) {
                    continue;
                }

                if ($index['origin'] === 'pk') {
                    return 'PRIMARY';
                }

                // Index names are per table in MySQL and per database in
                // SQLite; a name used by several tables carries the table as
                // a prefix (see database/migrations), which is not part of
                // the name the application knows it by.
                $name  = (string) $index['name'];
                $split = strpos($name, '__');

                return $split === false ? $name : substr($name, $split + 2);
            }

            // An INTEGER PRIMARY KEY is the rowid and has no index to list.
            return count($columns) === 1 ? 'PRIMARY' : null;
        } catch (Throwable) {
            return null;
        }
    }

    /** A FOREIGN KEY constraint refused the change. */
    public static function isForeignKeyViolation(Throwable $e): bool
    {
        return $e instanceof PDOException
            && (int) ($e->errorInfo[1] ?? 0) === 19
            && str_contains($e->getMessage(), 'FOREIGN KEY constraint failed');
    }

    public function queryCount(): int
    {
        return $this->queryCount;
    }

    public function queryTimeMs(): float
    {
        return round($this->queryTime * 1000, 2);
    }

    private static function redactSql(string $sql): string
    {
        return substr(preg_replace('/\s+/', ' ', $sql) ?? $sql, 0, 500);
    }
}
