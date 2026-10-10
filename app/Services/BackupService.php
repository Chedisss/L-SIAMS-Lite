<?php
declare(strict_types=1);

namespace App\Services;

use App\Core\Clock;
use App\Core\Config;
use App\Core\Crypto;
use App\Core\Database;
use App\Core\Exceptions\ValidationException;
use App\Core\Logger;
use Throwable;

/**
 * Database backup, verification and restore (Part 6).
 *
 * The dump is plain SQL produced in PHP from the SQLite file: every table,
 * index, view and trigger as SQLite stored it, and every row. It is written
 * while the system runs — a read transaction sees one consistent moment and
 * blocks no terminal — and restored inside a single transaction, so a restore
 * that fails part-way leaves the database exactly as it was. Archives are
 * gzipped and then encrypted with AES-256-GCM, because a backup file is a
 * complete copy of every attendance record and every password hash in the
 * school.
 */
final class BackupService
{
    private const MAGIC = "LSIAMSBK\x01";

    /**
     * @return array{backup_id:int,filename:string,size:int,checksum:string,tables:int,duration:float}
     */
    public static function create(string $triggerType = 'manual', ?int $userId = null): array
    {
        $started   = microtime(true);
        $directory = (string) Config::get('app.paths.backups');

        if (!is_dir($directory)) {
            @mkdir($directory, 0750, true);
        }

        $name     = sprintf('lsiams-%s-%s', $triggerType, Clock::now()->format('Ymd-His'));
        // Not '.enc'. Windows hands that extension to whichever program
        // claimed it — commonly Wireshark — so a school's backup arrived
        // looking like a packet capture, with an icon that invited somebody to
        // open it in the wrong program entirely. '.lsiams' is claimed by
        // nothing, so the file shows as what it is: a file only this system
        // knows how to read.
        //
        // The archive itself is unchanged: gzipped SQL, AES-256-GCM under
        // APP_KEY. Only the name it is written under is different, and
        // backup:decrypt still accepts both so every existing '.sql.gz.enc'
        // archive keeps working.
        $filename = $name . '.sql.gz.lsiams';
        $path     = $directory . '/' . $filename;

        $backupId = (int) Database::instance()->insert('backups', [
            'backup_name'  => $name,
            'file_path'    => $filename,
            'trigger_type' => $triggerType,
            'status'       => 'running',
            'is_encrypted' => 1,
            'is_compressed' => 1,
            'created_by'   => $userId,
            'created_at'   => Clock::nowString(),
        ]);

        try {
            $dump   = self::dump($tableCount);
            $packed = self::pack($dump);

            file_put_contents($path, $packed);
            @chmod($path, 0600);

            $checksum = hash('sha256', $packed);
            $duration = microtime(true) - $started;

            Database::instance()->update('backups', [
                'file_size'        => strlen($packed),
                'checksum'         => $checksum,
                'table_count'      => $tableCount,
                'status'           => 'completed',
                'duration_seconds' => (int) round($duration),
            ], ['backup_id' => $backupId]);

            AuditService::log(
                AuditService::BACKUP_CREATED,
                'backup',
                'backup',
                $backupId,
                null,
                ['name' => $name, 'tables' => $tableCount, 'bytes' => strlen($packed)],
                sprintf('%s backup created (%d tables, %s).', ucfirst($triggerType), $tableCount, self::humanSize(strlen($packed))),
                'success',
                $userId
            );

            NotificationService::toAdministrators(
                'backup',
                'Backup completed',
                sprintf('%s — %d tables, %s.', $name, $tableCount, self::humanSize(strlen($packed))),
                'normal',
                '/admin/backup'
            );

            return [
                'backup_id' => $backupId,
                'filename'  => $filename,
                'size'      => strlen($packed),
                'checksum'  => $checksum,
                'tables'    => $tableCount,
                'duration'  => round($duration, 2),
            ];
        } catch (Throwable $e) {
            Database::instance()->update('backups', [
                'status'        => 'failed',
                'error_message' => mb_substr($e->getMessage(), 0, 500),
            ], ['backup_id' => $backupId]);

            Logger::critical('Backup failed', ['backup_id' => $backupId, 'error' => $e->getMessage()]);

            NotificationService::toAdministrators(
                'backup',
                'Backup failed',
                'The scheduled backup did not complete: ' . $e->getMessage(),
                'critical',
                '/admin/backup'
            );

            throw $e;
        }
    }

    /**
     * Produce a restorable SQL dump of the whole schema and its data.
     *
     * Tables first, each followed by its rows, then indexes and views, and
     * triggers last. Created any earlier, the triggers would fire on the
     * INSERTs above them — refusing rows the guards exist to protect and
     * stamping updated_at on every restored row. They are not optional
     * decoration either: the rules that make attendance, audit logs, security
     * logs and login history undeletable are triggers, and a dump without them
     * restores a database that silently permits what the system refuses.
     */
    public static function dump(?int &$tableCount = null): string
    {
        $db  = Database::instance();
        $pdo = $db->pdo();

        // A read transaction: under WAL every SELECT below sees the same
        // moment, while taps keep writing. Database::transaction() would take
        // the write lock instead and hold up every terminal for the duration.
        $ownTransaction = !$db->inTransaction();

        if ($ownTransaction) {
            $pdo->exec('BEGIN');
        }

        try {
            $objects = $db->select(
                "SELECT type, name, tbl_name, sql FROM sqlite_master
                  WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'
                  ORDER BY rowid"
            );

            $sql = "-- L-SIAMS database backup (SQLite)\n"
                . '-- Generated: ' . Clock::atom() . "\n"
                . '-- Database: ' . basename($db->path()) . "\n\n";

            $tableCount = 0;

            foreach ($objects as $object) {
                if ($object['type'] !== 'table') {
                    continue;
                }

                $table = (string) $object['name'];
                $tableCount++;

                $sql .= sprintf("DROP TABLE IF EXISTS \"%s\";\n%s;\n\n", $table, (string) $object['sql']);
                $sql .= self::dumpRows($db, $table);
            }

            // AUTOINCREMENT counters, so an id used before the backup is not
            // handed out again after a restore.
            if ($db->scalar("SELECT 1 FROM sqlite_master WHERE name = 'sqlite_sequence'") !== null) {
                $sql .= "DELETE FROM sqlite_sequence;\n";

                foreach ($db->select('SELECT name, seq FROM sqlite_sequence') as $row) {
                    $sql .= sprintf("INSERT INTO sqlite_sequence (name, seq) VALUES (%s, %d);\n", $pdo->quote((string) $row['name']), (int) $row['seq']);
                }

                $sql .= "\n";
            }

            foreach (['index', 'view', 'trigger'] as $type) {
                foreach ($objects as $object) {
                    if ($object['type'] === $type) {
                        $sql .= rtrim((string) $object['sql'], "; \n") . ";\n\n";
                    }
                }
            }
        } finally {
            if ($ownTransaction) {
                $pdo->exec('COMMIT');
            }
        }

        return $sql;
    }

    /** INSERT statements for every row of one table, generated columns left out. */
    private static function dumpRows(Database $db, string $table): string
    {
        $pdo     = $db->pdo();
        $columns = [];
        $blobs   = [];

        foreach ($db->select('SELECT name, type, hidden FROM pragma_table_xinfo(:t)', ['t' => $table]) as $column) {
            // hidden 2 and 3 are generated columns: SQLite computes them and
            // refuses a value for them.
            if ((int) $column['hidden'] !== 0) {
                continue;
            }

            $columns[] = (string) $column['name'];

            if (strtoupper((string) $column['type']) === 'BLOB') {
                $blobs[(string) $column['name']] = true;
            }
        }

        if ($columns === []) {
            return '';
        }

        $quoted = '"' . implode('", "', $columns) . '"';
        $out    = '';

        // Chunked by rowid so a large attendance_records table is never held
        // in memory at once, and so the walk cannot skip or repeat a row.
        $after     = PHP_INT_MIN;
        $chunkSize = 500;

        while (true) {
            $rows = $db->select(
                sprintf('SELECT rowid AS __rowid, %s FROM "%s" WHERE rowid > :after ORDER BY rowid LIMIT %d', $quoted, $table, $chunkSize),
                ['after' => $after]
            );

            if ($rows === []) {
                break;
            }

            $values = [];

            foreach ($rows as $record) {
                $after = (int) $record['__rowid'];
                unset($record['__rowid']);

                $cells = [];

                foreach ($record as $name => $value) {
                    $cells[] = match (true) {
                        $value === null => 'NULL',
                        isset($blobs[$name]) => "X'" . bin2hex((string) $value) . "'",
                        is_int($value) => (string) $value,
                        is_float($value) => var_export($value, true),
                        is_bool($value) => $value ? '1' : '0',
                        default => $pdo->quote((string) $value),
                    };
                }

                $values[] = '(' . implode(', ', $cells) . ')';
            }

            $out .= sprintf("INSERT INTO \"%s\" (%s) VALUES\n%s;\n", $table, $quoted, implode(",\n", $values));

            if (count($rows) < $chunkSize) {
                break;
            }
        }

        return $out === '' ? '' : $out . "\n";
    }

    /**
     * Read a backup archive off disk and return the plain SQL inside it.
     *
     * Restoring through the admin pages needs the `backups` row that describes
     * the archive — which is itself in the database, so it is gone in exactly
     * the situation a backup exists for. This path needs nothing but the file
     * and the APP_KEY it was encrypted with.
     */
    public static function decryptFile(string $path): string
    {
        if (!is_file($path) || !is_readable($path)) {
            throw new ValidationException(['file' => ['No readable file at ' . $path . '.']]);
        }

        return self::unpack((string) file_get_contents($path));
    }

    /** gzip, then AES-256-GCM, with a magic header so the format is identifiable. */
    private static function pack(string $sql): string
    {
        $compressed = gzencode($sql, 9);

        if ($compressed === false) {
            throw new \RuntimeException('Backup compression failed.');
        }

        return self::MAGIC . Crypto::encrypt($compressed);
    }

    private static function unpack(string $payload): string
    {
        if (!str_starts_with($payload, self::MAGIC)) {
            throw new ValidationException(['file' => ['This file is not a recognised L-SIAMS backup.']]);
        }

        $ciphertext = substr($payload, strlen(self::MAGIC));
        $compressed = Crypto::decrypt($ciphertext);
        $sql        = gzdecode($compressed);

        if ($sql === false) {
            throw new ValidationException(['file' => ['The backup archive is corrupt.']]);
        }

        return $sql;
    }

    /**
     * Verify integrity without restoring: checksum, decryptability, and that
     * the SQL actually parses to a plausible dump.
     *
     * @return array{ok:bool,checks:array<string,bool>,message:string}
     */
    public static function verify(int $backupId): array
    {
        $backup = self::find($backupId);

        if ($backup === null) {
            throw new ValidationException(['backup_id' => ['Backup not found.']]);
        }

        $path   = (string) Config::get('app.paths.backups') . '/' . $backup['file_path'];
        $checks = ['file_exists' => is_readable($path)];

        if (!$checks['file_exists']) {
            return ['ok' => false, 'checks' => $checks, 'message' => 'The backup file is missing from disk.'];
        }

        $payload                = (string) file_get_contents($path);
        $checks['checksum']     = hash('sha256', $payload) === (string) $backup['checksum'];
        $checks['decryptable']  = false;
        $checks['well_formed']  = false;

        try {
            $sql                   = self::unpack($payload);
            $checks['decryptable'] = true;
            $checks['well_formed'] = str_contains($sql, 'CREATE TABLE') && str_contains($sql, 'attendance_records')
                && !self::isMariaDbDump($sql);
        } catch (Throwable) {
            // Leave the flags false; the caller reports the failure.
        }

        $ok = !in_array(false, $checks, true);

        if ($ok) {
            Database::instance()->update('backups', [
                'status'      => 'verified',
                'verified_at' => Clock::nowString(),
            ], ['backup_id' => $backupId]);
        }

        return [
            'ok'      => $ok,
            'checks'  => $checks,
            'message' => $ok
                ? 'Backup verified: checksum matches, archive decrypts, and the dump is well formed.'
                : 'Verification failed. Do not rely on this backup.',
        ];
    }

    /**
     * Restore a backup.
     *
     * Destructive and irreversible, so the caller must have re-authenticated
     * the administrator's password (enforced in the controller) and the backup
     * must verify first. A pre-restore safety backup is taken automatically.
     *
     * @return array{tables:int,safety_backup:string}
     */
    public static function restore(int $backupId, int $userId): array
    {
        $verification = self::verify($backupId);

        if (!$verification['ok']) {
            throw new ValidationException(['backup_id' => ['This backup failed verification and will not be restored.']]);
        }

        $backup = self::find($backupId);
        $path   = (string) Config::get('app.paths.backups') . '/' . $backup['file_path'];
        $sql    = self::unpack((string) file_get_contents($path));

        // Take a safety copy first — restoring the wrong archive is the most
        // expensive mistake available on this page.
        $safety = self::create('manual', $userId);

        $executed = self::replaceDatabaseWith($sql);

        Database::instance()->update('backups', [
            'status'      => 'restored',
            'restored_at' => Clock::nowString(),
            'restored_by' => $userId,
        ], ['backup_id' => $backupId]);

        AuditService::log(
            AuditService::BACKUP_RESTORED,
            'backup',
            'backup',
            $backupId,
            null,
            ['tables' => $executed, 'safety_backup' => $safety['filename']],
            sprintf(
                'Database restored from %s (%d tables). Safety backup %s was taken first.',
                $backup['backup_name'],
                $executed,
                $safety['filename']
            ),
            'success',
            $userId
        );

        NotificationService::toAdministrators(
            'backup',
            'Database restored',
            sprintf('Restored from %s. A safety backup was taken beforehand.', $backup['backup_name']),
            'critical',
            '/admin/backup'
        );

        return ['tables' => $executed, 'safety_backup' => $safety['filename']];
    }

    /**
     * Swap the whole database for the contents of a dump, as one transaction.
     *
     * Everything currently in the file is dropped and the dump run in its
     * place. If any statement fails the transaction rolls back and the
     * database is exactly as it was — a restore cannot leave a half-replaced
     * database behind.
     *
     * Foreign keys are off while it runs, because the dump creates tables in
     * file order rather than dependency order. The PRAGMAs only take effect
     * outside a transaction, hence the order.
     *
     * Returns the number of tables the dump created.
     */
    public static function replaceDatabaseWith(string $sql): int
    {
        if (self::isMariaDbDump($sql)) {
            throw new ValidationException(['file' => [
                'This is a backup from the MariaDB version of L-SIAMS. It cannot be restored '
                . 'into SQLite directly; import the old database with "console db:import-mysql" instead.',
            ]]);
        }

        $db  = Database::instance();
        $pdo = $db->pdo();

        $pdo->exec('PRAGMA foreign_keys = OFF');
        $pdo->exec('PRAGMA legacy_alter_table = ON');

        try {
            return (int) $db->transaction(static function (Database $db) use ($pdo, $sql): int {
                foreach (['view', 'trigger', 'table'] as $type) {
                    $names = $db->select(
                        "SELECT name FROM sqlite_master WHERE type = :type AND name NOT LIKE 'sqlite_%'",
                        ['type' => $type]
                    );

                    foreach ($names as $row) {
                        $pdo->exec(sprintf('DROP %s IF EXISTS "%s"', strtoupper($type), str_replace('"', '""', (string) $row['name'])));
                    }
                }

                // pdo_sqlite runs every statement in the string, in order.
                $pdo->exec($sql);

                // A backup brings back exactly what it holds. Rows that were
                // already orphaned when it was taken come back orphaned, and
                // refusing them would make a sound backup unrestorable; they
                // are logged so somebody can look. A damaged archive is caught
                // long before this, by the AES-GCM tag and gzip.
                $orphans = $db->foreignKeyViolations();

                if ($orphans !== []) {
                    Logger::warning('Restored database contains rows whose parent row is missing', ['counts' => $orphans]);
                }

                return (int) $db->scalar("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'");
            });
        } finally {
            $pdo->exec('PRAGMA legacy_alter_table = OFF');
            $pdo->exec('PRAGMA foreign_keys = ON');
            $db->forgetPendingMigrations();
        }
    }

    /** A dump written by the MariaDB version, or by mysqldump / phpMyAdmin. */
    public static function isMariaDbDump(string $sql): bool
    {
        $head = substr($sql, 0, 20000);

        return preg_match('/ENGINE\s*=\s*InnoDB|SET FOREIGN_KEY_CHECKS|^\s*DELIMITER\s|\/\*!40\d{3}/mi', $head) === 1;
    }

    /** @return array<string,mixed>|null */
    public static function find(int $backupId): ?array
    {
        return Database::instance()->selectOne(
            'SELECT b.*, u.username AS created_by_username
               FROM backups b
               LEFT JOIN users u ON u.user_id = b.created_by
              WHERE b.backup_id = :id',
            ['id' => $backupId]
        );
    }

    /** @return list<array<string,mixed>> */
    /**
     * When the last successful automatic backup ran, or null if none has.
     *
     * The schedule panel shows this so "nightly backups are on" can be told
     * apart from "nightly backups are on and one actually happened" — the gap
     * between the two being a worker that is not running at the scheduled hour.
     */
    public static function lastScheduledAt(): ?string
    {
        // Any status other than 'running' or 'failed' means the file was
        // written — a later verify or restore advances the row past
        // 'completed', and it still counts as a backup that happened.
        $at = Database::instance()->scalar(
            "SELECT MAX(created_at) FROM backups
              WHERE trigger_type = 'scheduled'
                AND status IN ('completed', 'verified', 'restored')"
        );

        return is_string($at) ? $at : null;
    }

    public static function history(int $limit = 50): array
    {
        return Database::instance()->select(
            'SELECT b.*, u.username AS created_by_username, r.username AS restored_by_username
               FROM backups b
               LEFT JOIN users u ON u.user_id = b.created_by
               LEFT JOIN users r ON r.user_id = b.restored_by
              ORDER BY b.backup_id DESC LIMIT ' . max(1, min($limit, 200))
        );
    }

    /** Download bytes for an existing backup. @return array{content:string,filename:string} */
    public static function download(int $backupId): array
    {
        $backup = self::find($backupId);

        if ($backup === null) {
            throw new ValidationException(['backup_id' => ['Backup not found.']]);
        }

        $path = (string) Config::get('app.paths.backups') . '/' . $backup['file_path'];

        if (!is_readable($path)) {
            throw new ValidationException(['backup_id' => ['The backup file is missing from disk.']]);
        }

        AuditService::log(
            'BACKUP_DOWNLOADED',
            'backup',
            'backup',
            $backupId,
            null,
            null,
            sprintf('Backup %s downloaded.', $backup['backup_name'])
        );

        return [
            'content'  => (string) file_get_contents($path),
            'filename' => (string) $backup['file_path'],
        ];
    }

    /** Retention sweep: keep the most recent $keep archives. */
    public static function pruneOld(int $keep = 30): int
    {
        $old = Database::instance()->select(
            "SELECT backup_id, file_path FROM backups
              WHERE status IN ('completed','verified')
              ORDER BY backup_id DESC
              LIMIT 500 OFFSET " . max(1, $keep)
        );

        $directory = (string) Config::get('app.paths.backups');
        $removed   = 0;

        foreach ($old as $backup) {
            $path = $directory . '/' . $backup['file_path'];

            if (is_file($path) && @unlink($path)) {
                $removed++;
            }

            // 'pruned', not 'failed'. This backup did not fail — it did
            // exactly what the retention policy asked of it. Filing a
            // successful backup under failures makes a working policy look
            // like a run of failures on the Backups page, which is the fastest
            // way to stop somebody trusting their backups.
            Database::instance()->update(
                'backups',
                ['status' => 'pruned', 'error_message' => 'Archive removed by the retention policy.'],
                ['backup_id' => (int) $backup['backup_id']]
            );
        }

        return $removed;
    }

    public static function humanSize(int $bytes): string
    {
        $units = ['B', 'KB', 'MB', 'GB'];
        $index = 0;

        while ($bytes >= 1024 && $index < count($units) - 1) {
            $bytes /= 1024;
            $index++;
        }

        return round((float) $bytes, $index === 0 ? 0 : 1) . ' ' . $units[$index];
    }
}
