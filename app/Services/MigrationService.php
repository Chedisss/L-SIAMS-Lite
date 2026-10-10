<?php
declare(strict_types=1);

namespace App\Services;

use App\Core\Config;
use App\Core\Database;
use RuntimeException;

/**
 * The migration runner: finds the files in database/migrations and applies
 * one at a time, each as a single transaction.
 *
 * Shared by `php bin/console migrate` and by the MariaDB import, which builds
 * its SQLite database to exactly the migrations the old database had.
 */
final class MigrationService
{
    /** @return list<array{name:string,path:string,checksum:string}> */
    public static function discover(): array
    {
        $directory = (string) Config::get('app.paths.migrations');
        $files     = glob($directory . '/*.sql') ?: [];

        sort($files, SORT_NATURAL);

        return array_map(static fn (string $path): array => [
            'name'     => basename($path),
            'path'     => $path,
            'checksum' => hash_file('sha256', $path),
        ], $files);
    }

    /**
     * Create the bookkeeping table on a new database file. Checked first rather
     * than relying on IF NOT EXISTS alone, so read-only callers such as `doctor`
     * and `migrate:status` never write to the file just by looking at it.
     */
    public static function ensureTable(Database $db): void
    {
        $exists = (int) $db->scalar(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = :name",
            ['name' => 'schema_migrations']
        );

        if ($exists > 0) {
            return;
        }

        $db->pdo()->exec(
            'CREATE TABLE IF NOT EXISTS schema_migrations (
                migration  TEXT    NOT NULL PRIMARY KEY,
                batch      INTEGER NOT NULL,
                checksum   TEXT    NOT NULL,
                applied_at TEXT    NOT NULL DEFAULT (now())
            )'
        );
    }

    /**
     * Apply one migration file and record it, as a single transaction.
     *
     * SQLite runs schema changes inside a transaction like any other write, so a
     * migration either happens completely, recorded in schema_migrations, or not
     * at all — there is no half-applied state to recover from on the next run.
     *
     * Foreign keys are switched off while it runs, because several migrations
     * rebuild a table (create the new shape, copy, drop the old one, rename), and
     * with them on, dropping a table that others reference would fire their ON
     * DELETE actions. legacy_alter_table keeps a rename from rewriting the views
     * and triggers that refer to the table by name. Both have to be set outside
     * the transaction, where SQLite honours them. Before committing,
     * foreign_key_check confirms the migration broke no reference that resolved
     * before it ran; if it did, the migration is rolled back rather than leaving a
     * broken link behind.
     *
     * @param array{migration:string,batch:int,checksum:string} $record
     */
    public static function run(Database $db, string $sql, array $record): void
    {
        $pdo = $db->pdo();
        $pdo->exec('PRAGMA foreign_keys = OFF');
        $pdo->exec('PRAGMA legacy_alter_table = ON');

        try {
            $db->transaction(static function (Database $db) use ($pdo, $sql, $record): void {
                // Rows that were already orphaned before this migration — an old
                // import done with checks off, say — are not its fault, and must
                // not stop every future migration from running.
                $before = $db->foreignKeyViolations();

                // pdo_sqlite runs every statement in the string, triggers included.
                $pdo->exec($sql);

                $broken = Database::newViolations($before, $db->foreignKeyViolations());

                if ($broken !== []) {
                    throw new RuntimeException(sprintf(
                        'it would leave rows pointing at something that does not exist (%s).',
                        implode(', ', array_map(static fn (string $k, int $n): string => "$n in $k", array_keys($broken), $broken))
                    ));
                }

                $db->insert('schema_migrations', $record);
            });
        } finally {
            $pdo->exec('PRAGMA legacy_alter_table = OFF');
            $pdo->exec('PRAGMA foreign_keys = ON');
            $db->forgetPendingMigrations();
        }
    }

    /**
     * Apply, in order, every migration on disk that this database has not
     * run, optionally stopping at a given set.
     *
     * @param  list<string>|null $only names to apply (null: all pending)
     * @return list<string>      names applied
     */
    public static function applyPending(Database $db, ?array $only = null, ?callable $before = null): array
    {
        self::ensureTable($db);

        $applied = array_flip(array_map('strval', array_column($db->select('SELECT migration FROM schema_migrations'), 'migration')));
        $batch   = (int) $db->scalar('SELECT COALESCE(MAX(batch), 0) + 1 FROM schema_migrations');
        $done    = [];

        foreach (self::discover() as $migration) {
            if (isset($applied[$migration['name']])) {
                continue;
            }

            if ($only !== null && !in_array($migration['name'], $only, true)) {
                continue;
            }

            if ($before !== null) {
                $before($migration['name']);
            }

            self::run($db, (string) file_get_contents($migration['path']), [
                'migration' => $migration['name'],
                'batch'     => $batch,
                'checksum'  => $migration['checksum'],
            ]);

            $done[] = $migration['name'];
        }

        return $done;
    }
}
