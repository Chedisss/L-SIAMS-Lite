<?php
declare(strict_types=1);

namespace App\Services\Import;

use App\Core\Config;
use App\Core\Database;
use App\Services\MigrationService;
use PDO;
use RuntimeException;
use Throwable;

/**
 * Copy the MariaDB version's data into a new SQLite database.
 *
 * The SQLite database is built in a file beside the real one and only moved
 * into place once every check has passed, so a failed import changes nothing.
 * An existing database at the destination is kept, renamed, never deleted.
 *
 *  1. Build the schema to exactly the migrations the old database had run.
 *     The migrations carry the same names in both versions, so "the same
 *     schema" is something that can be asked for rather than hoped for.
 *  2. Empty it — the migrations insert reference rows the old database
 *     already has, under ids that may differ — and copy every row across in
 *     one transaction, with the triggers lifted. They would otherwise refuse
 *     legitimate history and, worse, count every student into a section a
 *     second time on top of the enrolled_count being copied.
 *  3. Put the triggers back, carry over the AUTO_INCREMENT counters so no id
 *     is ever handed out twice, and verify: for every table, the number of
 *     rows and a fingerprint of their contents must match what was read.
 *  4. Run whatever migrations this version has that the old one had not.
 *  5. Move the file into place.
 */
final class MariaDbImporter
{
    /** @var callable(string): void */
    private $log;

    /** @param callable(string): void $log */
    public function __construct(private readonly MariaDbSource $source, callable $log)
    {
        $this->log = $log;
    }

    /**
     * @return array{
     *   tables:int, rows:int, per_table:array<string,int>, migrations_after:list<string>,
     *   orphans:array<string,int>, previous:?string, path:string
     * }
     */
    public function run(string $target, bool $replaceExisting): array
    {
        if (is_file($target) && !$replaceExisting && self::hasData($target)) {
            throw new RuntimeException(
                'There is already a database with data at ' . $target . '. Re-run with --force to import anyway; '
                . 'the existing file is kept, renamed, not deleted.'
            );
        }

        ($this->log)('Reading ' . $this->source->describe());

        $sourceTables     = $this->source->tables();
        $sourceMigrations = $this->source->migrations();
        $names            = array_column($sourceMigrations, 'migration');

        $this->checkMigrations($names);

        $scratch = dirname($target) . '/lsiams.import-' . bin2hex(random_bytes(4)) . '.sqlite';
        $live    = (array) Config::get('database', []);

        if (!is_dir(dirname($target)) && !@mkdir(dirname($target), 0775, true)) {
            throw new RuntimeException('Could not create ' . dirname($target));
        }

        Config::set('database', ['path' => $scratch] + $live);
        Database::resetInstance();

        try {
            $db = Database::instance();

            ($this->log)(sprintf('Building the SQLite schema to the %d migrations the old database had', count($names)));
            MigrationService::applyPending($db, $names);

            $tables = $this->targetTables($db);
            $this->checkColumns($tables, $sourceTables);

            [$perTable, $total] = $this->copy($db, $tables);

            $after = MigrationService::applyPending($db, null, function (string $name): void {
                ($this->log)('Applying ' . $name . ' (newer than the old database)');
            });

            $integrity = (string) $db->scalar('PRAGMA integrity_check');

            if ($integrity !== 'ok') {
                throw new RuntimeException('The new database failed its integrity check: ' . $integrity);
            }

            foreach ($db->select("SELECT name FROM sqlite_master WHERE type = 'view'") as $view) {
                $db->select(sprintf('SELECT * FROM "%s" LIMIT 1', $view['name']));
            }

            $orphans = $db->foreignKeyViolations();
            $db->pdo()->exec('PRAGMA wal_checkpoint(TRUNCATE)');
        } catch (Throwable $e) {
            Database::instance()->disconnect();
            Database::resetInstance();
            Config::set('database', $live);
            self::remove($scratch);

            throw $e;
        }

        Database::instance()->disconnect();
        Database::resetInstance();
        Config::set('database', $live);

        $previous = $this->moveIntoPlace($scratch, $target);

        return [
            'tables'           => count($perTable),
            'rows'             => $total,
            'per_table'        => $perTable,
            'migrations_after' => $after,
            'orphans'          => $orphans,
            'previous'         => $previous,
            'path'             => $target,
        ];
    }

    /** @param list<string> $names */
    private function checkMigrations(array $names): void
    {
        if ($names === []) {
            throw new RuntimeException(
                'The old database has no schema_migrations rows, so there is no telling which version of L-SIAMS wrote it. '
                . 'Run "php bin/console migrate" on the MariaDB version first.'
            );
        }

        $known   = array_column(MigrationService::discover(), 'name');
        $unknown = array_values(array_diff($names, $known));

        if ($unknown !== []) {
            throw new RuntimeException(
                'The old database ran migrations this version does not have: ' . implode(', ', $unknown)
                . '. It was written by a newer L-SIAMS than this copy of L-SIAMS-Lite; update L-SIAMS-Lite first.'
            );
        }
    }

    /**
     * The SQLite tables and their writable columns, with each column's
     * storage class.
     *
     * @return array<string,array<string,string>>
     */
    private function targetTables(Database $db): array
    {
        $tables = [];

        foreach ($db->select("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name") as $row) {
            $table = (string) $row['name'];

            foreach ($db->select('SELECT name, type, hidden FROM pragma_table_xinfo(:t)', ['t' => $table]) as $column) {
                if ((int) $column['hidden'] === 0) {
                    $tables[$table][(string) $column['name']] = strtoupper((string) $column['type']);
                }
            }
        }

        return $tables;
    }

    /**
     * The two schemas must agree on every table and column that holds data;
     * built to the same migrations, they do. A mismatch means the old database
     * was changed by hand, and copying past it would lose something quietly.
     *
     * @param array<string,array<string,string>> $tables
     * @param array<string,list<array{name:string,type:string,generated:bool}>> $source
     */
    private function checkColumns(array $tables, array $source): void
    {
        $problems = [];

        foreach ($tables as $table => $columns) {
            if (!isset($source[$table])) {
                $problems[] = $table . ' is missing from the old database';
                continue;
            }

            $theirs = array_column(array_filter($source[$table], static fn (array $c): bool => !$c['generated']), 'name');
            $ours   = array_keys($columns);

            foreach (array_diff($theirs, $ours) as $extra) {
                $problems[] = "$table.$extra exists only in the old database";
            }

            foreach (array_diff($ours, $theirs) as $missing) {
                $problems[] = "$table.$missing is missing from the old database";
            }
        }

        foreach (array_diff(array_keys($source), array_keys($tables)) as $table) {
            if (!str_starts_with($table, 'v_')) {
                $problems[] = $table . ' exists only in the old database';
            }
        }

        if ($problems !== []) {
            throw new RuntimeException("The old database does not have the shape its migrations describe:\n  - " . implode("\n  - ", $problems));
        }
    }

    /**
     * Copy every row, then verify. One transaction: if verification fails,
     * nothing was written.
     *
     * @param  array<string,array<string,string>> $tables
     * @return array{0:array<string,int>,1:int}
     */
    private function copy(Database $db, array $tables): array
    {
        $pdo = $db->pdo();

        $triggers = array_column(
            $db->select("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND sql IS NOT NULL ORDER BY rowid"),
            'sql'
        );

        $pdo->exec('PRAGMA foreign_keys = OFF');

        try {
            return $db->transaction(function (Database $db) use ($pdo, $tables, $triggers): array {
                foreach ($db->select("SELECT name FROM sqlite_master WHERE type = 'trigger'") as $row) {
                    $pdo->exec(sprintf('DROP TRIGGER "%s"', $row['name']));
                }

                foreach (array_keys($tables) as $table) {
                    if ($table !== 'schema_migrations') {
                        $pdo->exec(sprintf('DELETE FROM "%s"', $table));
                    }
                }

                ($this->log)('Copying rows');

                $statements = [];
                $counts     = [];
                $prints     = [];
                $started    = microtime(true);
                $copied     = 0;

                $this->source->eachRow(function (string $table, array $row) use ($pdo, $tables, &$statements, &$counts, &$prints, &$copied, $started): void {
                    if ($table === 'schema_migrations' || !isset($tables[$table])) {
                        return;
                    }

                    $columns = array_keys($row);
                    $key     = $table . ':' . implode(',', $columns);

                    if (!isset($statements[$key])) {
                        $statements[$key] = $pdo->prepare(sprintf(
                            'INSERT INTO "%s" ("%s") VALUES (%s)',
                            $table,
                            implode('", "', $columns),
                            implode(', ', array_fill(0, count($columns), '?'))
                        ));
                    }

                    $statement = $statements[$key];
                    $index     = 1;

                    foreach ($row as $value) {
                        if ($value === null) {
                            $statement->bindValue($index++, null, PDO::PARAM_NULL);
                        } elseif ($value instanceof BinaryValue) {
                            $statement->bindValue($index++, $value->bytes, PDO::PARAM_LOB);
                        } elseif (is_int($value)) {
                            $statement->bindValue($index++, $value, PDO::PARAM_INT);
                        } else {
                            $statement->bindValue($index++, (string) $value, PDO::PARAM_STR);
                        }
                    }

                    $statement->execute();

                    $counts[$table] = ($counts[$table] ?? 0) + 1;
                    $prints[$table] = self::fold($prints[$table] ?? null, self::rowPrint($row, $tables[$table]));

                    if (++$copied % 20000 === 0) {
                        ($this->log)(sprintf('  %s rows (%.0fs)', number_format($copied), microtime(true) - $started));
                    }
                });

                $this->carryCounters($db, array_keys($tables));

                foreach ($triggers as $sql) {
                    $pdo->exec((string) $sql);
                }

                $this->carryMigrationHistory($db);

                ($this->log)('Verifying every table against what was read');
                $this->verify($db, $tables, $counts, $prints);

                ksort($counts);

                return [$counts, array_sum($counts)];
            });
        } finally {
            $pdo->exec('PRAGMA foreign_keys = ON');
        }
    }

    /**
     * AUTOINCREMENT counters: never lower than the old AUTO_INCREMENT, so an
     * id that MariaDB handed out — even for a row since deleted — is not
     * handed out again.
     *
     * @param list<string> $tables
     */
    private function carryCounters(Database $db, array $tables): void
    {
        $pdo = $db->pdo();

        foreach ($tables as $table) {
            $sql = (string) $db->scalar("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = :t", ['t' => $table]);

            if (stripos($sql, 'AUTOINCREMENT') === false) {
                continue;
            }

            $highest = (int) $db->scalar(sprintf('SELECT COALESCE(MAX(rowid), 0) FROM "%s"', $table));
            $next    = $this->source->autoIncrement($table);
            $seq     = max($highest, $next === null ? 0 : $next - 1);

            $pdo->prepare('DELETE FROM sqlite_sequence WHERE name = ?')->execute([$table]);

            if ($seq > 0) {
                $pdo->prepare('INSERT INTO sqlite_sequence (name, seq) VALUES (?, ?)')->execute([$table, $seq]);
            }
        }
    }

    /** When each migration first ran, as the old database recorded it. */
    private function carryMigrationHistory(Database $db): void
    {
        foreach ($this->source->migrations() as $row) {
            $db->execute(
                'UPDATE schema_migrations SET batch = :batch, applied_at = COALESCE(:at, applied_at) WHERE migration = :m',
                ['batch' => $row['batch'], 'at' => $row['applied_at'], 'm' => $row['migration']]
            );
        }
    }

    /**
     * @param array<string,array<string,string>> $tables
     * @param array<string,int>                  $counts
     * @param array<string,string>               $prints
     */
    private function verify(Database $db, array $tables, array $counts, array $prints): void
    {
        $problems = [];

        foreach ($tables as $table => $columns) {
            if ($table === 'schema_migrations') {
                continue;
            }

            $expected = $counts[$table] ?? 0;
            $actual   = (int) $db->scalar(sprintf('SELECT COUNT(*) FROM "%s"', $table));

            if ($expected !== $actual) {
                $problems[] = sprintf('%s: %d rows read, %d in SQLite', $table, $expected, $actual);
                continue;
            }

            $print = null;

            foreach ($db->select(sprintf('SELECT "%s" FROM "%s"', implode('", "', array_keys($columns)), $table)) as $row) {
                $print = self::fold($print, self::rowPrint($row, $columns));
            }

            if ($print !== ($prints[$table] ?? null)) {
                $problems[] = sprintf('%s: the same %d rows, but their contents differ', $table, $actual);
            }
        }

        if ($problems !== []) {
            throw new RuntimeException("The copy did not match the original, so nothing was kept:\n  - " . implode("\n  - ", $problems));
        }
    }

    /**
     * A row's fingerprint, written the way SQLite will store it: a number in a
     * numeric column compares as a number ("12.50" and 12.5 are the same
     * value), everything else byte for byte.
     *
     * @param array<string,mixed>  $row
     * @param array<string,string> $types
     */
    private static function rowPrint(array $row, array $types): string
    {
        $parts = [];

        foreach ($types as $name => $type) {
            $value = $row[$name] ?? null;

            if ($value === null) {
                $parts[] = "\0N";
            } elseif ($value instanceof BinaryValue || $type === 'BLOB') {
                // By the column, not the value: read back from SQLite the
                // bytes are a plain string.
                $parts[] = "\0B" . ($value instanceof BinaryValue ? $value->bytes : (string) $value);
            } elseif (($type === 'INTEGER' || $type === 'NUMERIC') && is_numeric($value)) {
                $parts[] = "\0#" . self::number($value);
            } else {
                $parts[] = "\0S" . (string) $value;
            }
        }

        return hash('sha256', implode("\x1f", $parts), true);
    }

    private static function number(mixed $value): string
    {
        $float = (float) $value;

        if (floor($float) === $float && abs($float) < 9.0e15) {
            return sprintf('%.0f', $float);
        }

        return sprintf('%.10g', $float);
    }

    /** Order-independent: rows are compared as a set, as they are stored. */
    private static function fold(?string $acc, string $print): string
    {
        return $acc === null ? $print : ($acc ^ $print);
    }

    private function moveIntoPlace(string $scratch, string $target): ?string
    {
        $previous = null;

        if (is_file($target)) {
            $previous = $target . '.before-import-' . date('Ymd-His');

            if (!@rename($target, $previous)) {
                self::remove($scratch);
                throw new RuntimeException(
                    'The existing database is in use, so it could not be set aside. Stop L-SIAMS (stop.bat, and the '
                    . 'worker if it is installed as a task) and run the import again. Nothing was changed.'
                );
            }

            foreach (['-wal', '-shm'] as $suffix) {
                if (is_file($target . $suffix)) {
                    @rename($target . $suffix, $previous . $suffix);
                }
            }
        }

        if (!@rename($scratch, $target)) {
            throw new RuntimeException('The new database was built at ' . $scratch . ' but could not be moved to ' . $target . '.');
        }

        foreach (['-wal', '-shm'] as $suffix) {
            @unlink($scratch . $suffix);
        }

        return $previous;
    }

    private static function hasData(string $path): bool
    {
        try {
            $pdo = new PDO('sqlite:' . $path, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);

            return (int) $pdo->query('SELECT COUNT(*) FROM users')->fetchColumn() > 0
                || (int) $pdo->query('SELECT COUNT(*) FROM students')->fetchColumn() > 0;
        } catch (Throwable) {
            return false;
        }
    }

    private static function remove(string $path): void
    {
        foreach ([$path, $path . '-wal', $path . '-shm'] as $file) {
            @unlink($file);
        }
    }
}
