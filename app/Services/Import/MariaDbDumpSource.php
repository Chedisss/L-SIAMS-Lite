<?php
declare(strict_types=1);

namespace App\Services\Import;

use App\Core\Clock;
use App\Services\BackupService;
use DateTimeImmutable;
use DateTimeZone;
use RuntimeException;

/**
 * The MariaDB data, read from a dump file — for when the old server will not
 * start, or is already gone.
 *
 * Accepted: a phpMyAdmin export or a mysqldump (.sql or .sql.gz), and a backup
 * archive made by the MariaDB version of L-SIAMS (.sql.gz.lsiams or
 * .sql.gz.enc), which is decrypted with this installation's APP_KEY — the same
 * key, because the .env came along.
 *
 * Only two kinds of statement matter: CREATE TABLE, for each table's column
 * order and types, and INSERT, for the rows. Everything else — views,
 * triggers, SET lines, LOCK TABLES — is read past. The one SET that is acted on
 * is the time zone: mysqldump and phpMyAdmin write TIMESTAMP columns in UTC
 * and say so with SET TIME_ZONE='+00:00', and those values are moved back to
 * APP_TIMEZONE, which is what the application always read them in.
 *
 * The file is read twice: once for the table definitions and schema_migrations
 * (the SQLite database has to be built to match before any row can go in),
 * then again for the rows. Neither pass holds more than one statement in
 * memory, so a large attendance history is no problem — except an encrypted
 * archive, which has to be decrypted whole.
 */
final class MariaDbDumpSource implements MariaDbSource
{
    /** @var array<string,list<array{name:string,type:string,generated:bool}>> */
    private array $tables = [];

    /** @var array<string,int> */
    private array $autoIncrement = [];

    /** @var list<array{migration:string,batch:int,applied_at:?string}> */
    private array $migrations = [];

    /** Offset the dump wrote TIMESTAMP columns in, e.g. '+00:00'; null = local. */
    private ?string $timeZone = null;

    private string $sqlPath;

    private bool $temporary = false;

    private bool $scanned = false;

    /** Whether the file said what time zone its TIMESTAMP columns are in. */
    private bool $timeZoneKnown = false;

    /**
     * @param string|null $assumeTimeZone the offset TIMESTAMP columns were
     *        written in, for a dump that does not say (--timezone=+00:00)
     */
    public function __construct(private readonly string $path, private readonly ?string $assumeTimeZone = null)
    {
        if (!is_file($path) || !is_readable($path)) {
            throw new RuntimeException('No readable file at ' . $path);
        }

        $head = (string) file_get_contents($path, false, null, 0, 16);

        if (str_starts_with($head, "LSIAMSBK")) {
            // A backup archive from the MariaDB version: same format, same key.
            $this->sqlPath   = self::temporaryFile((string) BackupService::decryptFile($path));
            $this->temporary = true;
        } elseif (str_starts_with($head, "\x1f\x8b")) {
            $sql = gzdecode((string) file_get_contents($path));

            if ($sql === false) {
                throw new RuntimeException('The .gz file is damaged and could not be decompressed.');
            }

            $this->sqlPath   = self::temporaryFile($sql);
            $this->temporary = true;
        } else {
            $this->sqlPath = $path;
        }
    }

    public function __destruct()
    {
        if ($this->temporary) {
            @unlink($this->sqlPath);
        }
    }

    public function describe(): string
    {
        return 'the dump file ' . basename($this->path)
            . ($this->timeZone !== null ? ' (TIMESTAMP columns written at UTC' . ($this->timeZone === '+00:00' ? '' : $this->timeZone) . ')' : '');
    }

    public function tables(): array
    {
        $this->scan();

        return $this->tables;
    }

    public function migrations(): array
    {
        $this->scan();

        return $this->migrations;
    }

    public function autoIncrement(string $table): ?int
    {
        $this->scan();

        return $this->autoIncrement[$table] ?? null;
    }

    public function eachRow(callable $onRow): void
    {
        $this->scan();

        foreach ($this->statements() as $statement) {
            $insert = self::insertTarget($statement);

            if ($insert === null || !isset($this->tables[$insert])) {
                continue;
            }

            foreach ($this->parseInsert($statement) as [$table, $row]) {
                $onRow($table, $row);
            }
        }
    }

    // ------------------------------------------------------------- pass 1 --

    /** Table definitions, AUTO_INCREMENT values, the time zone and the migrations. */
    private function scan(): void
    {
        if ($this->scanned) {
            return;
        }

        $this->scanned = true;

        // A backup made by the MariaDB version of L-SIAMS was written through
        // the application's own connection, so in APP_TIMEZONE. It says so in
        // its first line.
        $handle = fopen($this->sqlPath, 'rb');

        if ($handle !== false) {
            $first = (string) fgets($handle);
            fclose($handle);

            if (str_starts_with(ltrim($first, "\xEF\xBB\xBF"), '-- L-SIAMS database backup')) {
                $this->timeZoneKnown = true;
            }
        }

        foreach ($this->statements() as $statement) {
            if (self::insertTarget($statement) !== null) {
                if (self::insertTarget($statement) === 'schema_migrations' && isset($this->tables['schema_migrations'])) {
                    foreach ($this->parseInsert($statement) as [, $row]) {
                        $this->migrations[] = [
                            'migration'  => (string) $row['migration'],
                            'batch'      => (int) ($row['batch'] ?? 1),
                            'applied_at' => isset($row['applied_at']) ? (string) $row['applied_at'] : null,
                        ];
                    }
                }

                continue;
            }

            // Everything else is small — SET lines and table definitions — so
            // removing its comments with a regular expression is safe.
            $code = self::withoutComments($statement, true);

            if (preg_match("/^SET\s+(?:@@session\.)?TIME_ZONE\s*=\s*['\"]([^'\"]+)['\"]/i", $code, $m) === 1) {
                $this->timeZone      = self::isLocalOffset($m[1]) ? null : $m[1];
                $this->timeZoneKnown = true;
                continue;
            }



            if (preg_match('/^CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?`?([^`\s(]+)`?\s*\(/i', $code, $m) === 1) {
                $this->readCreateTable($m[1], $code);
            }
        }

        if ($this->tables === []) {
            throw new RuntimeException('No CREATE TABLE statements found. Export the database with its structure, not data only.');
        }

        if ($this->assumeTimeZone !== null) {
            $this->timeZone      = self::isLocalOffset($this->assumeTimeZone) ? null : $this->assumeTimeZone;
            $this->timeZoneKnown = true;
        }
    }

    /**
     * Said when the file does not state which time zone its TIMESTAMP columns
     * are in. mysqldump --skip-tz-utc writes them in the server's own zone and
     * does not say which; on the school's PC that is local time, which is what
     * is assumed — but it cannot be read from the file, so it is said aloud.
     */
    public function timeZoneNote(): ?string
    {
        $this->scan();

        if ($this->timeZoneKnown) {
            return null;
        }

        return 'The file does not say which time zone its TIMESTAMP columns (created_at, updated_at, ...) '
            . 'were written in, so they were read as ' . Clock::real()->format('P') . ' (APP_TIMEZONE). That is right '
            . 'for a dump made on the school PC. If the times come out shifted, import again with '
            . '--timezone=+00:00 (or whichever offset the dump was made in).';
    }

    private function readCreateTable(string $table, string $sql): void
    {
        $open    = strpos($sql, '(');
        $close   = strrpos($sql, ')');
        $body    = substr($sql, $open + 1, $close - $open - 1);
        $columns = [];

        foreach (preg_split('/\n/', $body) ?: [] as $line) {
            if (preg_match('/^\s*`([^`]+)`\s+([a-z]+)/i', $line, $m) !== 1) {
                continue;
            }

            $columns[] = [
                'name'      => $m[1],
                'type'      => strtolower($m[2]),
                'generated' => preg_match('/\bGENERATED\s+ALWAYS\b|\bAS\s*\(.*\)\s*(STORED|VIRTUAL|PERSISTENT)\b/i', $line) === 1,
            ];
        }

        // A view's stand-in (phpMyAdmin writes one as a real CREATE TABLE)
        // has columns too, but never any rows, and the importer only copies
        // tables the SQLite schema has; harmless either way.
        $this->tables[$table] = $columns;

        if (preg_match('/\)\s*[^)]*\bAUTO_INCREMENT\s*=\s*(\d+)/i', substr($sql, $close), $m) === 1) {
            $this->autoIncrement[$table] = (int) $m[1];
        }
    }

    // ------------------------------------------------------------- pass 2 --

    /**
     * Parse one INSERT into [table, row] pairs.
     *
     * @return list<array{0:string,1:array<string,mixed>}>
     */
    private function parseInsert(string $statement): array
    {
        $sql = self::withoutLeadingComments($statement);

        if (preg_match('/^(?:INSERT|REPLACE)\s+(?:IGNORE\s+)?(?:INTO\s+)?`?([^`\s(]+)`?\s*(?:\(([^)]*)\))?\s*VALUES\s*/i', $sql, $m) !== 1) {
            return [];
        }

        $table      = $m[1];
        $definition = $this->tables[$table] ?? [];
        $names      = isset($m[2]) && trim($m[2]) !== ''
            ? array_map(static fn (string $c): string => trim($c, " \t\n\r`"), explode(',', $m[2]))
            : array_column($definition, 'name');

        $generated = [];
        $timestamp = [];
        $binary    = [];

        foreach ($definition as $column) {
            if ($column['generated']) {
                $generated[$column['name']] = true;
            }
            if ($column['type'] === 'timestamp') {
                $timestamp[$column['name']] = true;
            }
            if (in_array($column['type'], ['binary', 'varbinary', 'blob', 'tinyblob', 'mediumblob', 'longblob'], true)) {
                $binary[$column['name']] = true;
            }
        }

        $rows = [];
        $pos  = strlen($m[0]);
        $len  = strlen($sql);

        while ($pos < $len) {
            $pos = self::skipSpace($sql, $pos);

            if ($pos >= $len || $sql[$pos] !== '(') {
                break;
            }

            $pos++;
            $values = [];

            while (true) {
                $pos = self::skipSpace($sql, $pos);
                [$value, $pos] = self::readValue($sql, $pos);
                $values[] = $value;
                $pos = self::skipSpace($sql, $pos);

                if (($sql[$pos] ?? '') === ',') {
                    $pos++;
                    continue;
                }

                if (($sql[$pos] ?? '') === ')') {
                    $pos++;
                    break;
                }

                throw new RuntimeException(sprintf('Could not read a row of %s near: %s', $table, substr($sql, max(0, $pos - 40), 80)));
            }

            if (count($values) !== count($names)) {
                throw new RuntimeException(sprintf(
                    'A row of %s has %d values for %d columns.',
                    $table,
                    count($values),
                    count($names)
                ));
            }

            $row = [];

            foreach ($names as $index => $name) {
                $value = $values[$index];

                if (isset($generated[$name]) || $value instanceof DefaultValue) {
                    continue;
                }

                if ($value !== null && isset($timestamp[$name]) && $this->timeZone !== null && is_string($value)) {
                    $value = self::toLocal($value, $this->timeZone);
                }

                if ($value !== null && isset($binary[$name]) && !$value instanceof BinaryValue) {
                    $value = new BinaryValue((string) $value);
                }

                $row[$name] = $value;
            }

            $rows[] = [$table, $row];

            $pos = self::skipSpace($sql, $pos);

            if (($sql[$pos] ?? '') === ',') {
                $pos++;
                continue;
            }

            break;
        }

        return $rows;
    }

    /**
     * One literal at $pos, as MySQL writes it in a dump.
     *
     * @return array{0:mixed,1:int}
     */
    private static function readValue(string $sql, int $pos): array
    {
        $rest = substr($sql, $pos, 12);

        if (strncasecmp($rest, 'NULL', 4) === 0) {
            return [null, $pos + 4];
        }

        if (strncasecmp($rest, 'DEFAULT', 7) === 0) {
            return [new DefaultValue(), $pos + 7];
        }

        // A character-set introducer: _binary'..', _utf8mb4'..'.
        if (preg_match('/^_([a-z0-9]+)\s*/i', $rest, $m) === 1) {
            [$string, $next] = self::readString($sql, $pos + strlen($m[0]));

            return [strtolower($m[1]) === 'binary' ? new BinaryValue($string) : $string, $next];
        }

        $char = $sql[$pos] ?? '';

        if ($char === "'" || $char === '"') {
            return self::readString($sql, $pos);
        }

        // 0xABCD and X'ABCD': bytes.
        if (preg_match('/^0x([0-9a-f]*)/i', substr($sql, $pos, 2 + 2 * 1024 * 1024), $m) === 1) {
            return [new BinaryValue((string) hex2bin(strlen($m[1]) % 2 === 1 ? '0' . $m[1] : $m[1])), $pos + strlen($m[0])];
        }

        if (($char === 'x' || $char === 'X') && ($sql[$pos + 1] ?? '') === "'") {
            [$hex, $next] = self::readString($sql, $pos + 1);

            return [new BinaryValue((string) hex2bin($hex)), $next];
        }

        if (($char === 'b' || $char === 'B') && ($sql[$pos + 1] ?? '') === "'") {
            [$bits, $next] = self::readString($sql, $pos + 1);

            return [(string) bindec($bits), $next];
        }

        if (preg_match('/^[-+]?(?:\d+\.?\d*|\.\d+)(?:e[-+]?\d+)?/i', substr($sql, $pos, 64), $m) === 1) {
            return [$m[0], $pos + strlen($m[0])];
        }

        throw new RuntimeException('Unrecognised value near: ' . substr($sql, max(0, $pos - 20), 60));
    }

    /**
     * A quoted string with MySQL's escapes: backslash sequences, and the quote
     * written twice.
     *
     * @return array{0:string,1:int}
     */
    private static function readString(string $sql, int $pos): array
    {
        $quote = $sql[$pos];
        $pos++;
        $out = '';
        $len = strlen($sql);

        while ($pos < $len) {
            $run  = strcspn($sql, $quote . '\\', $pos);
            $out .= substr($sql, $pos, $run);
            $pos += $run;

            if ($pos >= $len) {
                break;
            }

            if ($sql[$pos] === '\\') {
                $next = $sql[$pos + 1] ?? '';
                $out .= match ($next) {
                    '0'     => "\0",
                    'b'     => "\x08",
                    'n'     => "\n",
                    'r'     => "\r",
                    't'     => "\t",
                    'Z'     => "\x1a",
                    // MySQL keeps the backslash for these two: they only
                    // mean something inside a LIKE pattern.
                    '%'     => '\\%',
                    '_'     => '\\_',
                    default => $next,
                };
                $pos += 2;
                continue;
            }

            // The quote character: doubled is a literal quote, single ends it.
            if (($sql[$pos + 1] ?? '') === $quote) {
                $out .= $quote;
                $pos += 2;
                continue;
            }

            return [$out, $pos + 1];
        }

        throw new RuntimeException('A quoted value never closes — the file is truncated.');
    }

    private static function skipSpace(string $sql, int $pos): int
    {
        return $pos + strspn($sql, " \t\r\n", $pos);
    }

    // ------------------------------------------------------- statements --

    /**
     * Every statement in the file, split on the current delimiter wherever it
     * falls outside quotes and comments. DELIMITER lines (around triggers) are
     * honoured, so a trigger body stays in one piece.
     *
     * @return \Generator<int,string>
     */
    private function statements(): \Generator
    {
        $handle = fopen($this->sqlPath, 'rb');

        if ($handle === false) {
            throw new RuntimeException('Could not open ' . $this->sqlPath);
        }

        $delimiter = ';';
        $buffer    = '';
        $state     = null; // null, "'", '"', '`', '*' (block comment)
        $first     = true;

        try {
            while (($line = fgets($handle)) !== false) {
                if ($first) {
                    $line  = (string) preg_replace('/^\xEF\xBB\xBF/', '', $line);
                    $first = false;
                }

                if ($state === null && trim($buffer) === '' && preg_match('/^\s*DELIMITER\s+(\S+)/i', $line, $m) === 1) {
                    $delimiter = $m[1];
                    $buffer    = '';
                    continue;
                }

                if ($state === null && trim($buffer) === '' && preg_match('/^\s*(--\s|--$|#)/', $line) === 1) {
                    continue;
                }

                $len = strlen($line);
                $i   = 0;

                while ($i < $len) {
                    $c = $line[$i];

                    if ($state === "'" || $state === '"' || $state === '`') {
                        $run = strcspn($line, $state . '\\', $i);
                        $buffer .= substr($line, $i, $run);
                        $i += $run;

                        if ($i >= $len) {
                            break;
                        }

                        if ($line[$i] === '\\' && $state !== '`') {
                            $buffer .= substr($line, $i, 2);
                            $i += 2;
                            continue;
                        }

                        $buffer .= $line[$i];
                        $i++;
                        $state = null;
                        continue;
                    }

                    if ($state === '*') {
                        $end = strpos($line, '*/', $i);

                        if ($end === false) {
                            $buffer .= substr($line, $i);
                            break;
                        }

                        $buffer .= substr($line, $i, $end + 2 - $i);
                        $i = $end + 2;
                        $state = null;
                        continue;
                    }

                    if ($c === "'" || $c === '"' || $c === '`') {
                        $state = $c;
                        $buffer .= $c;
                        $i++;
                        continue;
                    }

                    if ($c === '/' && ($line[$i + 1] ?? '') === '*') {
                        $state = '*';
                        $buffer .= '/*';
                        $i += 2;
                        continue;
                    }

                    if ($c === '-' && ($line[$i + 1] ?? '') === '-' && preg_match('/\s/', $line[$i + 2] ?? "\n") === 1) {
                        $buffer .= "\n";
                        break;
                    }

                    if ($c === '#') {
                        $buffer .= "\n";
                        break;
                    }

                    if ($c === $delimiter[0] && substr($line, $i, strlen($delimiter)) === $delimiter) {
                        if (trim($buffer) !== '') {
                            yield $buffer;
                        }

                        $buffer = '';
                        $i += strlen($delimiter);
                        continue;
                    }

                    $buffer .= $c;
                    $i++;
                }
            }

            if (trim($buffer) !== '') {
                yield $buffer;
            }
        } finally {
            fclose($handle);
        }
    }

    /**
     * The statement with any comments in front of it removed, by plain string
     * scanning: an INSERT can be a megabyte long, and its rows may contain
     * anything, so it is never handed to a regular expression whole.
     */
    private static function withoutLeadingComments(string $sql): string
    {
        $pos = 0;
        $len = strlen($sql);

        while (true) {
            $pos += strspn($sql, " \t\r\n", $pos);

            if (substr($sql, $pos, 2) === '/*' && !str_starts_with(substr($sql, $pos, 3), '/*!')) {
                $end = strpos($sql, '*/', $pos + 2);
                $pos = $end === false ? $len : $end + 2;
                continue;
            }

            return substr($sql, $pos);
        }
    }

    /** The table an INSERT writes to, or null when the statement is not one. */
    private static function insertTarget(string $statement): ?string
    {
        $head = self::withoutLeadingComments(substr($statement, 0, 2000));

        if (preg_match('/^(?:INSERT|REPLACE)\s+(?:IGNORE\s+)?(?:INTO\s+)?`?([^`\s(]+)`?/i', $head, $m) === 1) {
            return $m[1];
        }

        return null;
    }

    /**
     * The statement with comments removed. With $unwrapConditional, the body
     * of a MySQL conditional comment — /*!40103 SET TIME_ZONE='+00:00' *\/ —
     * is kept as code, because that is how mysqldump writes the SET lines.
     */
    private static function withoutComments(string $sql, bool $unwrapConditional): string
    {
        if (!str_contains($sql, '/*')) {
            return trim($sql);
        }

        // Only the leading part matters for classifying a statement, and the
        // rows of a large INSERT never contain a comment worth removing.
        $out = preg_replace_callback(
            "/'(?:[^'\\\\]|\\\\.|'')*'|\\/\\*(!\\d*)?(.*?)\\*\\//s",
            static function (array $m) use ($unwrapConditional): string {
                if (!isset($m[2])) {
                    return $m[0];
                }

                return ($m[1] ?? '') !== '' && $unwrapConditional ? ' ' . $m[2] . ' ' : ' ';
            },
            $sql
        );

        if ($out === null) {
            throw new RuntimeException('A statement in the dump could not be read: ' . substr(trim($sql), 0, 80));
        }

        return trim($out);
    }

    private static function isLocalOffset(string $zone): bool
    {
        $tz = Clock::timezone();

        try {
            $offset = (new DateTimeImmutable('now', new DateTimeZone($zone)))->getOffset();
        } catch (\Throwable) {
            return false;
        }

        return $offset === (new DateTimeImmutable('now', $tz))->getOffset() && $zone !== 'SYSTEM';
    }

    /** A TIMESTAMP written in $zone, as the time APP_TIMEZONE calls it. */
    private static function toLocal(string $value, string $zone): string
    {
        if (str_starts_with($value, '0000-00-00')) {
            return $value;
        }

        try {
            return (new DateTimeImmutable($value, new DateTimeZone($zone)))
                ->setTimezone(Clock::timezone())
                ->format('Y-m-d H:i:s');
        } catch (\Throwable) {
            return $value;
        }
    }

    private static function temporaryFile(string $contents): string
    {
        $path = tempnam(sys_get_temp_dir(), 'lsiams-import-');

        if ($path === false || file_put_contents($path, $contents) === false) {
            throw new RuntimeException('Could not write a temporary file for the import.');
        }

        @chmod($path, 0600);

        return $path;
    }
}
