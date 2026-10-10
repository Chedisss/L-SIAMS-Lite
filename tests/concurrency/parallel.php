#!/usr/bin/env php
<?php
declare(strict_types=1);

/**
 * Real multi-process concurrency test.
 *
 * run.php drives every race from a single process, which proves the logic but
 * not the database underneath it. At a school the taps come from several
 * terminals at once, each handled by its own PHP process, while the worker,
 * the realtime server and the dashboards read the same file. SQLite lets one
 * connection write at a time, so this is where "database is locked" or a
 * double-counted tap would show up if the locking were wrong.
 *
 * So this starts real processes:
 *   - two tappers per terminal, each tapping every card of that terminal's
 *     section in its own random order, so every card is raced by two
 *     processes while every terminal writes at the same moment;
 *   - readers that run the dashboard and report queries in a loop the whole
 *     time, as the realtime server, the worker and open browsers do.
 * All of them wait on a start barrier and are released together.
 *
 *   php tests/concurrency/parallel.php [--terminals=4] [--students=40] [--readers=2] [--gap-ms=0]
 *
 * --gap-ms puts a random pause of up to that many milliseconds between one
 * tapper's taps. 0 (the default) is the worst case, every process tapping as
 * fast as it can; a real terminal sees a tap every second or two.
 *
 * WARNING: like run.php, this creates and removes TEST-CONC- data. Point it at
 * a test database, never at a school's real one.
 */

if (PHP_SAPI !== 'cli') {
    fwrite(STDERR, "Run this from the command line.\n");
    exit(1);
}

require dirname(__DIR__, 2) . '/bootstrap.php';
require __DIR__ . '/Fixture.php';

use App\Core\Clock;
use App\Core\Database;
use App\Core\Exceptions\BusinessRuleException;
use App\Services\AttendanceService;
use App\Services\AttendanceSessionService;
use App\Services\SettingsService;

SettingsService::hydrate();

$options = ['terminals' => 4, 'students' => 40, 'readers' => 2, 'gap-ms' => 0];
$role    = null;
$job     = null;

foreach (array_slice($argv, 1) as $argument) {
    if (preg_match('/^--(terminals|students|readers|gap-ms)=(\d+)$/', $argument, $m) === 1) {
        $options[$m[1]] = $m[1] === 'gap-ms' ? (int) $m[2] : max(1, (int) $m[2]);
    } elseif (preg_match('/^--(tapper|reader)=(.+)$/', $argument, $m) === 1) {
        $role = $m[1];
        $job  = $m[2];
    }
}

// ----------------------------------------------------------------- child --

if ($role !== null) {
    $spec = json_decode((string) file_get_contents($job), true, 512, JSON_THROW_ON_ERROR);
    Clock::freeze(new DateTimeImmutable((string) $spec['now'], Clock::timezone()));
    $db = Database::instance();

    // The barrier: nobody starts until the parent says go, so the processes
    // genuinely collide instead of running one after another.
    while (!is_file((string) $spec['go'])) {
        usleep(2000);
    }

    $result = ['accepted' => 0, 'duplicate' => 0, 'other' => [], 'errors' => [], 'latency' => [], 'reads' => 0];

    if ($role === 'tapper') {
        $device = $db->selectOne('SELECT * FROM devices WHERE id = :id', ['id' => (int) $spec['device']]) ?? [];

        foreach ($spec['cards'] as $card) {
            if ((int) $spec['gap'] > 0) {
                usleep(random_int(0, (int) $spec['gap']) * 1000);
            }

            $started = hrtime(true);

            try {
                AttendanceService::tap($device, (string) $card, null, AttendanceService::INTENT_TIME_IN);
                $result['accepted']++;
            } catch (BusinessRuleException $e) {
                in_array($e->errorCode(), ['DUPLICATE_TIME_IN', 'ALREADY_COMPLETE'], true)
                    ? $result['duplicate']++
                    : $result['other'][] = $e->errorCode();
            } catch (Throwable $e) {
                $result['errors'][] = get_class($e) . ': ' . $e->getMessage();
            }

            $result['latency'][] = (hrtime(true) - $started) / 1e6;
        }
    } else {
        while (!is_file((string) $spec['stop'])) {
            try {
                $db->select('SELECT * FROM v_attendance_detail ORDER BY attendance_id DESC LIMIT 50');
                $db->select('SELECT * FROM v_device_status');
                $db->scalar('SELECT COUNT(*) FROM attendance_records');
                $db->select('SELECT * FROM v_section_summary');
                $result['reads']++;
            } catch (Throwable $e) {
                $result['errors'][] = get_class($e) . ': ' . $e->getMessage();
            }
        }
    }

    file_put_contents((string) $spec['out'], json_encode($result));
    exit(0);
}

// ---------------------------------------------------------------- parent --

$work = sys_get_temp_dir() . '/lsiams-parallel-' . bin2hex(random_bytes(4));
mkdir($work);

$failures = 0;
$check    = static function (string $name, bool $ok, string $detail = '') use (&$failures): void {
    echo ($ok ? '  ✓ ' : '  ✗ ') . $name . ($detail !== '' && !$ok ? "\n      " . $detail : '') . "\n";
    $failures += $ok ? 0 : 1;
};

Clock::freeze(Clock::now()->setTime(10, 0, 0));

$db      = Database::instance();
$fixture = new Fixture();
$n       = $options['terminals'];

echo "\n  Multi-process concurrency: {$n} terminals, 2 tappers each, {$options['readers']} readers\n";
echo '  ' . str_repeat('─', 66) . "\n";

try {
    $fixture->build($n, $options['students'], $n);

    $sessions = [];

    for ($i = 0; $i < $n; $i++) {
        $sessions[$i] = AttendanceSessionService::open($fixture->device($i), $fixture->teacher(), $fixture->schedule($i), 0);
    }

    $go       = $work . '/go';
    $stop     = $work . '/stop';
    $children = [];
    $taps     = 0;

    $spawn = static function (string $role, array $spec) use ($work, &$children): void {
        $index        = count($children);
        $spec['out']  = $work . "/out-{$index}.json";
        $jobFile      = $work . "/job-{$index}.json";
        file_put_contents($jobFile, json_encode($spec));

        $process = proc_open(
            [PHP_BINARY, __FILE__, "--{$role}={$jobFile}"],
            [0 => ['file', '/dev/null', 'r'], 1 => ['file', $work . "/stdout-{$index}.txt", 'w'], 2 => ['file', $work . "/stderr-{$index}.txt", 'w']],
            $pipes
        );

        $children[] = ['process' => $process, 'role' => $role, 'out' => $spec['out'], 'stderr' => $work . "/stderr-{$index}.txt"];
    };

    $common = ['now' => Clock::now()->format('Y-m-d H:i:s'), 'go' => $go, 'stop' => $stop, 'gap' => $options['gap-ms']];

    for ($i = 0; $i < $n; $i++) {
        $cards = array_values($fixture->ids['cards'][$fixture->ids['sections'][$i]]);

        foreach ([1, 2] as $_) {
            shuffle($cards);
            $spawn('tapper', $common + ['device' => $fixture->ids['devices'][$i], 'cards' => $cards]);
            $taps += count($cards);
        }
    }

    for ($r = 0; $r < $options['readers']; $r++) {
        $spawn('reader', $common);
    }

    usleep(300000); // let every child reach the barrier
    $started = microtime(true);
    touch($go);

    // Tappers first; readers keep reading until every tap is done.
    foreach ($children as $child) {
        if ($child['role'] === 'tapper') {
            proc_close($child['process']);
        }
    }

    $elapsed = microtime(true) - $started;
    touch($stop);

    foreach ($children as $child) {
        if ($child['role'] === 'reader') {
            proc_close($child['process']);
        }
    }

    $accepted = $duplicate = $reads = 0;
    $other    = $errors = $latency = [];

    foreach ($children as $child) {
        if (!is_file($child['out'])) {
            $errors[] = 'a ' . $child['role'] . ' wrote no result: ' . trim((string) file_get_contents($child['stderr']));
            continue;
        }

        $r          = json_decode((string) file_get_contents($child['out']), true);
        $accepted  += $r['accepted'];
        $duplicate += $r['duplicate'];
        $reads     += $r['reads'];
        $other      = array_merge($other, $r['other']);
        $errors     = array_merge($errors, $r['errors']);
        $latency    = array_merge($latency, $r['latency']);
    }

    sort($latency);
    $pct = static fn (float $p): float => $latency === [] ? 0.0 : $latency[(int) min(count($latency) - 1, floor($p * count($latency)))];

    $students = $n * $options['students'];
    $rows     = 0;
    $perSessionOk = true;

    foreach ($sessions as $i => $session) {
        $count = (int) $db->scalar('SELECT COUNT(*) FROM attendance_records WHERE session_id = :id', ['id' => $session['session_id']]);
        $rows += $count;
        $perSessionOk = $perSessionOk && $count === $options['students'];
    }

    $doubles = (int) $db->scalar(
        'SELECT COUNT(*) FROM (SELECT session_id, student_id FROM attendance_records
                                WHERE session_id IN (' . implode(',', array_map(static fn ($s) => (int) $s['session_id'], $sessions)) . ')
                                GROUP BY session_id, student_id HAVING COUNT(*) > 1)'
    );

    $check(sprintf('%d taps from %d processes finished in %.2fs', $taps, count($children) - $options['readers'], $elapsed), true);
    $check('every student has exactly one attendance record in their session', $perSessionOk && $rows === $students,
        sprintf('%d records for %d students', $rows, $students));
    $check('no student was recorded twice', $doubles === 0, $doubles . ' doubled');
    $check('exactly one of each raced pair of taps was accepted', $accepted === $students,
        sprintf('accepted=%d students=%d', $accepted, $students));
    $check('every other tap was rejected as a duplicate', $accepted + $duplicate === $taps,
        sprintf('accepted=%d duplicate=%d other=%s', $accepted, $duplicate, implode(',', array_unique($other))));
    $check('no tap failed with an error (no "database is locked")', $errors === [],
        implode("\n      ", array_slice(array_unique($errors), 0, 5)));
    $check(sprintf('readers ran %d rounds of dashboard queries alongside, none failed', $reads), $reads > 0 && $errors === []);
    $check('the database file is intact', (string) $db->scalar('PRAGMA integrity_check') === 'ok');

    printf("    tap latency: median %.1f ms, 95th percentile %.1f ms, slowest %.1f ms\n", $pct(0.5), $pct(0.95), $latency === [] ? 0 : end($latency));
} catch (Throwable $e) {
    $check('setup', false, $e->getMessage());
} finally {
    $fixture->teardown();

    foreach (glob($work . '/*') ?: [] as $file) {
        @unlink($file);
    }

    @rmdir($work);
}

echo "\n  " . ($failures === 0 ? 'All checks passed.' : $failures . ' check(s) failed.') . "\n\n";
exit($failures === 0 ? 0 : 1);
