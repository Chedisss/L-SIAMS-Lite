<?php
declare(strict_types=1);

namespace App\Services\Import;

use App\Core\Clock;
use PDO;
use RuntimeException;
use Throwable;

/**
 * The MariaDB data, read from the running server — the database the old
 * version's .env points at (DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS).
 *
 * The connection is set up the way the old application set up its own: the
 * session time zone is APP_TIMEZONE, so TIMESTAMP columns come back as the
 * local times the application always showed. Rows are streamed, not
 * buffered, so the size of the attendance history does not matter.
 */
final class LiveMariaDbSource implements MariaDbSource
{
    private PDO $pdo;

    /** @var array<string,list<array{name:string,type:string,generated:bool}>>|null */
    private ?array $tables = null;

    /** @param array{host:string,port:int,database:string,username:string,password:string} $config */
    public function __construct(private readonly array $config)
    {
        if (!extension_loaded('pdo_mysql')) {
            throw new RuntimeException(
                'Reading the old database needs PHP\'s pdo_mysql extension, which is not loaded. '
                . 'In C:\\xampp\\php\\php.ini remove the ";" in front of "extension=pdo_mysql". '
                . 'Or import from a dump instead: db:import-mysql --from-file=<backup or .sql>.'
            );
        }

        try {
            $this->pdo = new PDO(
                sprintf('mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4', $config['host'], $config['port'], $config['database']),
                $config['username'],
                $config['password'],
                [
                    PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
                    PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                    PDO::ATTR_TIMEOUT            => 5,
                ]
            );
        } catch (Throwable $e) {
            throw new RuntimeException(sprintf(
                'Could not connect to MariaDB at %s:%d (database %s, user %s): %s. '
                . 'Start MySQL in the XAMPP Control Panel and try again, or import from a dump with --from-file.',
                $config['host'],
                $config['port'],
                $config['database'],
                $config['username'],
                $e->getMessage()
            ));
        }

        $offset = Clock::real()->format('P');
        $this->pdo->exec("SET time_zone = '" . $offset . "'");
    }

    public function describe(): string
    {
        return sprintf('MariaDB database %s on %s:%d', $this->config['database'], $this->config['host'], $this->config['port']);
    }

    public function tables(): array
    {
        if ($this->tables !== null) {
            return $this->tables;
        }

        $statement = $this->pdo->prepare(
            "SELECT c.TABLE_NAME, c.COLUMN_NAME, c.DATA_TYPE, c.EXTRA
               FROM information_schema.COLUMNS c
               JOIN information_schema.TABLES t
                 ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME
              WHERE c.TABLE_SCHEMA = :schema AND t.TABLE_TYPE = 'BASE TABLE'
              ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION"
        );
        $statement->execute(['schema' => $this->config['database']]);

        $tables = [];

        foreach ($statement as $row) {
            $tables[(string) $row['TABLE_NAME']][] = [
                'name'      => (string) $row['COLUMN_NAME'],
                'type'      => strtolower((string) $row['DATA_TYPE']),
                'generated' => stripos((string) $row['EXTRA'], 'GENERATED') !== false,
            ];
        }

        if ($tables === []) {
            throw new RuntimeException('The database ' . $this->config['database'] . ' has no tables.');
        }

        return $this->tables = $tables;
    }

    public function migrations(): array
    {
        if (!isset($this->tables()['schema_migrations'])) {
            return [];
        }

        $rows = $this->pdo->query('SELECT migration, batch, applied_at FROM schema_migrations ORDER BY migration')->fetchAll();

        return array_map(static fn (array $r): array => [
            'migration'  => (string) $r['migration'],
            'batch'      => (int) $r['batch'],
            'applied_at' => $r['applied_at'] === null ? null : (string) $r['applied_at'],
        ], $rows);
    }

    public function autoIncrement(string $table): ?int
    {
        $statement = $this->pdo->prepare(
            'SELECT AUTO_INCREMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA = :schema AND TABLE_NAME = :t'
        );
        $statement->execute(['schema' => $this->config['database'], 't' => $table]);
        $value = $statement->fetchColumn();

        return $value === false || $value === null ? null : (int) $value;
    }

    public function eachRow(callable $onRow): void
    {
        foreach ($this->tables() as $table => $columns) {
            $wanted = [];
            $binary = [];

            foreach ($columns as $column) {
                if ($column['generated']) {
                    continue;
                }

                $wanted[] = '`' . str_replace('`', '``', $column['name']) . '`';

                if (in_array($column['type'], ['binary', 'varbinary', 'blob', 'tinyblob', 'mediumblob', 'longblob'], true)) {
                    $binary[$column['name']] = true;
                }
            }

            // Unbuffered: rows arrive as they are read, so memory stays flat
            // however large the table is.
            $this->pdo->setAttribute(PDO::MYSQL_ATTR_USE_BUFFERED_QUERY, false);

            try {
                $statement = $this->pdo->query(sprintf('SELECT %s FROM `%s`', implode(', ', $wanted), str_replace('`', '``', $table)));

                foreach ($statement as $row) {
                    foreach ($binary as $name => $_) {
                        if ($row[$name] !== null) {
                            $row[$name] = new BinaryValue((string) $row[$name]);
                        }
                    }

                    $onRow($table, $row);
                }

                $statement->closeCursor();
            } finally {
                $this->pdo->setAttribute(PDO::MYSQL_ATTR_USE_BUFFERED_QUERY, true);
            }
        }
    }
}
