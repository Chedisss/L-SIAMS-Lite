<?php
declare(strict_types=1);

/**
 * Environment probe for start.bat.
 *
 * start.bat used to ask these questions with inline `php -r "..."` snippets,
 * one of them nested inside a FOR /F. That put PHP source through two layers of
 * cmd.exe quote-stripping, and when a machine mangled it the result was:
 *
 *     PHP Parse error: syntax error, unexpected end of file ... on line 1
 *     [ok] PHP error:
 *
 * — a parse error from the probe, and the "version" printed as the second word
 * of the error message. Nothing was wrong with PHP; the launcher had simply
 * failed to ask. Moving the questions into a file removes every layer of
 * quoting between the batch file and the code, so there is nothing left to
 * mangle.
 *
 * Usage:
 *   php bin/env-check.php version     prints "8.2.4", exits 0
 *                                     exits 1 if older than 8.1
 *   php bin/env-check.php required    prints any missing required extensions
 *                                     exits 1 if any are missing
 *   php bin/env-check.php optional    prints any missing optional extensions
 *                                     exits 1 if any are missing
 *   php bin/env-check.php tls         prints APP_URL and exits 1 when it is
 *                                     https, which the built-in server cannot
 *                                     serve
 *   php bin/env-check.php database    exits 0 if the database file opens and has
 *                                     its tables; 3 if there is no file yet
 *
 * Kept free of the framework except where the check itself needs it: a
 * launcher that cannot boot the application still has to be able to say why.
 */

$command = $argv[1] ?? 'version';

switch ($command) {
    case 'version':
        echo PHP_VERSION, PHP_EOL;
        exit(PHP_VERSION_ID >= 80100 ? 0 : 1);

    case 'required':
    case 'optional':
        $needed = $command === 'required'
            ? ['pdo_sqlite', 'openssl', 'mbstring', 'json']
            // zip was here until the ZIP container was implemented in plain
            // PHP; nothing needs the extension now.
            : ['gd'];

        $missing = array_values(array_filter(
            $needed,
            static fn (string $extension): bool => !extension_loaded($extension)
        ));

        // The SQLite inside pdo_sqlite has to be new enough for the schema's
        // generated columns (3.31). Any PHP 8.1 build is; checked anyway, so
        // an unusual build says so here instead of failing in a migration.
        if ($command === 'required' && $missing === []) {
            $version = (string) (new PDO('sqlite::memory:'))->query('SELECT sqlite_version()')->fetchColumn();

            if (version_compare($version, '3.31.0', '<')) {
                $missing[] = 'SQLite 3.31+ (PHP has ' . $version . ')';
            }
        }

        if ($missing !== []) {
            echo implode(' ', $missing), PHP_EOL;
            exit(1);
        }

        exit(0);

    case 'keys':
        // Are the three cryptographic secrets actually present in .env?
        //
        // start.bat used to ask a different question — does .env EXIST — and
        // that is not the same thing. A .env copied from the example exists
        // and has all three keys blank, so the launcher sailed past and
        // started a system that cannot encrypt a terminal secret, hash an API
        // key or mint a realtime ticket. Every page needing one then failed,
        // and nothing on the way in had said a word about it.
        //
        // This reads the file directly rather than booting the framework: a
        // launcher that cannot start the application still has to be able to
        // say why it will not.
        $envFile = dirname(__DIR__) . '/.env';

        if (!is_file($envFile)) {
            echo 'no .env', PHP_EOL;
            exit(1);
        }

        $contents = (string) file_get_contents($envFile);
        $blank    = [];

        foreach (['APP_KEY', 'API_KEY_PEPPER', 'REALTIME_TICKET_SECRET'] as $name) {
            $set = preg_match('/^' . $name . '=(.*)$/m', $contents, $found) === 1
                && trim($found[1]) !== '';

            if (!$set) {
                $blank[] = $name;
            }
        }

        if ($blank !== []) {
            echo implode(' ', $blank), PHP_EOL;
            exit(1);
        }

        exit(0);

    case 'tls':
        // Is this installation configured for HTTPS?
        //
        // It matters to the launcher because PHP's built-in server — the one
        // start.bat runs — has no TLS support at all and never will. An
        // installation whose APP_URL says https:// is being served by Apache,
        // and start.bat would quietly put a second, plaintext copy of the site
        // on port 8080 beside it: same database, same sessions, no encryption,
        // and no sign from either that the other exists.
        //
        // Exits 1 when APP_URL is https, so the launcher can stop and explain.
        $envFile = dirname(__DIR__) . '/.env';

        if (!is_file($envFile)) {
            exit(0);
        }

        $contents = (string) file_get_contents($envFile);

        if (preg_match('/^APP_URL=\s*"?(\S+?)"?\s*$/mi', $contents, $found) !== 1) {
            exit(0);
        }

        if (stripos(trim($found[1]), 'https://') === 0) {
            echo trim($found[1]), PHP_EOL;
            exit(1);
        }

        exit(0);

    case 'database':
        // The database is a file in this folder, so there is no server to be
        // stopped and nothing to wait for. Three answers:
        //   0  it opens and has its tables
        //   3  there is no file yet — a new installation, or one that has not
        //      been brought over from MariaDB — which start.bat explains
        //   2  the file is there but will not open, or is not a database
        require __DIR__ . '/../bootstrap.php';

        $path = (string) App\Core\Config::get('database.path', '');

        // Checked before opening: opening a missing SQLite file creates an
        // empty one, and an empty file would pass for a database here.
        if (!is_file($path)) {
            fwrite(STDERR, 'No database file at ' . $path . PHP_EOL);
            exit(3);
        }

        try {
            App\Core\Database::instance()->scalar('SELECT COUNT(*) FROM schema_migrations');
            exit(0);
        } catch (Throwable $e) {
            // STDERR rather than STDOUT: start.bat sends both to nul and
            // prints its own guidance, so this stays out of the launcher. Run
            // by hand, the actual reason is the whole point.
            $reason = $e->getPrevious() !== null ? $e->getPrevious()->getMessage() : $e->getMessage();

            fwrite(STDERR, 'The database file would not open: ' . $reason . PHP_EOL);
            fwrite(STDERR, '  file=' . $path . PHP_EOL);

            exit(2);
        }

    default:
        fwrite(STDERR, "Unknown check: {$command}\n");
        exit(64);
}
