<?php
declare(strict_types=1);

namespace App\Services;

use App\Core\Database;
use App\Core\Exceptions\ValidationException;
use InvalidArgumentException;
use RuntimeException;

/**
 * Loads a school's starting data from one JSON file: grade levels, rooms,
 * subjects, sections, teachers (with their accounts), students and the weekly
 * timetable. `php bin/console data:load <file>` runs it.
 *
 * Every row goes through the same service the matching page uses, so the
 * rules are the ones an administrator typing it in would meet: a teacher may
 * only teach subjects of their departments and sections of their grade levels,
 * a section cannot double-book, a timetable cannot collide.
 *
 * The whole file is one transaction. A mistake anywhere means nothing is
 * written, and the message names the row.
 *
 * Grade levels, rooms and subjects that already exist (same code) are reused,
 * and so are teachers with the same email, so a second file for another grade
 * can name a teacher or room loaded by the first. Sections and students must
 * be new.
 *
 * The one rule relaxed is that a schedule's room must already have a terminal.
 * A school sets up its timetable before the terminals are registered; until a
 * terminal is assigned to the room, no session opens there.
 *
 * File layout (every list optional):
 *
 *   grade_levels: [{code, name, numeric_level}]
 *   classrooms:   [{room, capacity?}]
 *   subjects:     [{code, name, department, grade_levels: [code]}]
 *   sections:     [{code, name, grade_level, classroom, capacity?}]
 *   teachers:     [{key, first_name, middle_name?, last_name, department,
 *                   other_departments?: [code], grade_levels: [code],
 *                   email, username?}]      username given = a login is issued
 *   students:     [{student_number, section, first_name, middle_name?,
 *                   last_name, suffix?, gender, guardian_name, guardian_contact}]
 *   schedules:    [{section, subject, teacher, days: [day], start, end,
 *                   classroom?}]            classroom defaults to the section's
 */
final class SchoolDataLoader
{
    /** @var array<string,int> */
    private array $gradeLevels = [];

    /** @var array<string,int> */
    private array $classrooms = [];

    /** @var array<string,int> */
    private array $subjects = [];

    /** @var array<string,array{id:int,classroom:?int}> */
    private array $sections = [];

    /** @var array<string,int> */
    private array $teachers = [];

    /** @var array<string,int> */
    private array $departments = [];

    /** @var list<array{name:string,username:string,password:string}> */
    private array $accounts = [];

    /** @var array<string,int> */
    private array $counts = [];

    private string $where = '';

    public function __construct(private readonly int $adminUserId)
    {
    }

    /**
     * @param  array<string,mixed> $data
     * @return array{counts:array<string,int>,accounts:list<array{name:string,username:string,password:string}>}
     */
    public function load(array $data, bool $dryRun = false): array
    {
        $db = Database::instance();

        foreach ($db->select('SELECT department_code, department_id FROM departments WHERE deleted_at IS NULL') as $row) {
            $this->departments[strtoupper((string) $row['department_code'])] = (int) $row['department_id'];
        }

        try {
            $db->transaction(function () use ($data, $dryRun): void {
                $this->each($data, 'grade_levels', fn (array $r) => $this->gradeLevel($r));
                $this->each($data, 'classrooms', fn (array $r) => $this->classroom($r));
                $this->each($data, 'subjects', fn (array $r) => $this->subject($r));
                $this->each($data, 'sections', fn (array $r) => $this->section($r));
                $this->each($data, 'teachers', fn (array $r) => $this->teacher($r));
                $this->each($data, 'students', fn (array $r) => $this->student($r));
                $this->each($data, 'schedules', fn (array $r) => $this->schedule($r));

                if ($dryRun) {
                    throw new DryRunFinished();
                }
            });
        } catch (DryRunFinished) {
            // Everything was checked; the rollback is the point.
        } catch (ValidationException $e) {
            throw new RuntimeException($this->where . ': ' . self::describe($e), 0, $e);
        } catch (InvalidArgumentException $e) {
            throw new RuntimeException($this->where . ': ' . $e->getMessage(), 0, $e);
        }

        return ['counts' => $this->counts, 'accounts' => $dryRun ? [] : $this->accounts];
    }

    /** @param callable(array<string,mixed>):void $handle */
    private function each(array $data, string $list, callable $handle): void
    {
        foreach ((array) ($data[$list] ?? []) as $index => $row) {
            if (!is_array($row)) {
                throw new InvalidArgumentException(sprintf('%s #%d is not an object.', $list, $index + 1));
            }

            $this->where = sprintf('%s #%d (%s)', $list, $index + 1, self::label($row));
            $handle($row);
        }
    }

    // ------------------------------------------------------------- rows --

    private function gradeLevel(array $r): void
    {
        $code = strtoupper(self::req($r, 'code'));
        $id   = Database::instance()->scalar('SELECT grade_level_id FROM grade_levels WHERE grade_level_code = :c', ['c' => $code]);

        $this->gradeLevels[$code] = $id !== null ? (int) $id : $this->count('grade levels', AcademicStructureService::createGradeLevel([
            'grade_level_code' => $code,
            'grade_level_name' => self::req($r, 'name'),
            'numeric_level'    => (int) self::req($r, 'numeric_level'),
        ]));
    }

    private function classroom(array $r): void
    {
        $room = strtoupper(self::req($r, 'room'));
        $id   = Database::instance()->scalar(
            'SELECT classroom_id FROM classrooms WHERE room_number = :r AND deleted_at IS NULL',
            ['r' => $room]
        );

        $this->classrooms[$room] = $id !== null ? (int) $id : $this->count('classrooms', AcademicStructureService::createClassroom([
            'room_number' => $room,
            'capacity'    => (int) ($r['capacity'] ?? 45),
        ]));
    }

    private function subject(array $r): void
    {
        $code = strtoupper(self::req($r, 'code'));
        $id   = Database::instance()->scalar(
            'SELECT subject_id FROM subjects WHERE subject_code = :c AND deleted_at IS NULL',
            ['c' => $code]
        );

        $this->subjects[$code] = $id !== null ? (int) $id : $this->count('subjects', AcademicStructureService::createSubject([
            'subject_code'    => $code,
            'subject_name'    => self::req($r, 'name'),
            'department_id'   => $this->department(self::req($r, 'department')),
            'grade_level_ids' => array_map(fn ($g) => $this->gradeLevelId((string) $g), (array) ($r['grade_levels'] ?? [])),
        ]));
    }

    private function section(array $r): void
    {
        $code      = strtoupper(self::req($r, 'code'));
        $classroom = isset($r['classroom']) ? $this->classroomId((string) $r['classroom']) : null;

        $id = AcademicStructureService::createSection([
            'section_code'         => $code,
            'section_name'         => self::req($r, 'name'),
            'grade_level_id'       => $this->gradeLevelId(self::req($r, 'grade_level')),
            'capacity'             => (int) ($r['capacity'] ?? 45),
            'default_classroom_id' => $classroom,
        ], $this->adminUserId);

        $this->sections[$code] = ['id' => $this->count('sections', $id), 'classroom' => $classroom];
    }

    private function teacher(array $r): void
    {
        $db    = Database::instance();
        $key   = strtolower(self::req($r, 'key'));
        $email = mb_strtolower(self::req($r, 'email'));

        $existing = $db->scalar(
            'SELECT teacher_id FROM teachers WHERE email = :e AND deleted_at IS NULL',
            ['e' => $email]
        );

        if ($existing !== null) {
            $this->teachers[$key] = (int) $existing;

            return;
        }

        $department = $this->department(self::req($r, 'department'));

        $teacherId = TeacherService::create([
            'employee_number' => TeacherService::nextEmployeeNumber(),
            'department_id'   => $department,
            'first_name'      => self::req($r, 'first_name'),
            'middle_name'     => $r['middle_name'] ?? null,
            'last_name'       => self::req($r, 'last_name'),
            'email'           => $email,
            'position'        => $r['position'] ?? 'Teacher',
            'grade_level_ids' => array_map(fn ($g) => $this->gradeLevelId((string) $g), (array) ($r['grade_levels'] ?? [])),
        ], $this->adminUserId);

        // Secondary departments, e.g. a TLE teacher who also takes Journalism.
        foreach ((array) ($r['other_departments'] ?? []) as $code) {
            $db->execute(
                'INSERT OR IGNORE INTO teacher_departments (teacher_id, department_id, is_primary, assigned_by)
                      VALUES (:t, :d, 0, :u)',
                ['t' => $teacherId, 'd' => $this->department((string) $code), 'u' => $this->adminUserId]
            );
        }

        $this->teachers[$key] = $this->count('teachers', $teacherId);

        if (!empty($r['username'])) {
            $account = UserRegistrationService::issueAccountToTeacher($teacherId, (string) $r['username'], $this->adminUserId);

            $this->accounts[] = [
                'name'     => trim(self::req($r, 'first_name') . ' ' . self::req($r, 'last_name')),
                'username' => $account['username'],
                'password' => $account['password'],
            ];
        }
    }

    private function student(array $r): void
    {
        $this->count('students', StudentService::create([
            'student_number'   => self::req($r, 'student_number'),
            'section_id'       => $this->sectionId(self::req($r, 'section')),
            'first_name'       => self::req($r, 'first_name'),
            'middle_name'      => $r['middle_name'] ?? null,
            'last_name'        => self::req($r, 'last_name'),
            'suffix'           => $r['suffix'] ?? null,
            'gender'           => self::req($r, 'gender'),
            'guardian_name'    => self::req($r, 'guardian_name'),
            'guardian_contact' => self::req($r, 'guardian_contact'),
        ], $this->adminUserId));
    }

    private function schedule(array $r): void
    {
        $sectionCode = strtoupper(self::req($r, 'section'));
        $sectionId   = $this->sectionId($sectionCode);
        $classroomId = isset($r['classroom'])
            ? $this->classroomId((string) $r['classroom'])
            : ($this->sections[$sectionCode]['classroom'] ?? null);

        if ($classroomId === null) {
            throw new InvalidArgumentException('no classroom, and the section has no default room.');
        }

        $start   = self::time(self::req($r, 'start'));
        $end     = self::time(self::req($r, 'end'));
        $windows = self::windowsFor((int) ((strtotime("1970-01-01 {$end}") - strtotime("1970-01-01 {$start}")) / 60));

        foreach ((array) ($r['days'] ?? []) as $day) {
            $this->where = sprintf('schedule %s %s %s %s–%s', $sectionCode, self::req($r, 'subject'), $day, $start, $end);

            $this->count('schedules', ScheduleService::create([
                'teacher_id'   => $this->teacherId(self::req($r, 'teacher')),
                'subject_id'   => $this->subjectId(self::req($r, 'subject')),
                'section_id'   => $sectionId,
                'classroom_id' => $classroomId,
                'day_of_week'  => ucfirst(strtolower((string) $day)),
                'start_time'   => $start,
                'end_time'     => $end,
            ] + $windows, $this->adminUserId, false, false));
        }
    }

    // ----------------------------------------------------------- helpers --

    /**
     * Tap windows that fit the lesson. The defaults (in until 30 minutes, out
     * from 10 before the end) need a lesson longer than 40 minutes; a 30- or
     * 40-minute period gets proportionally tighter ones. Late stays at 15
     * minutes where the lesson allows it.
     *
     * @return array<string,int>
     */
    public static function windowsFor(int $minutes): array
    {
        return match (true) {
            $minutes > 40  => ['time_in_window_open' => 10, 'late_threshold_minutes' => 15, 'time_in_window_close' => 30,
                               'time_out_window_open' => 10, 'time_out_window_close' => 15, 'minimum_dwell_minutes' => 20],
            $minutes >= 35 => ['time_in_window_open' => 10, 'late_threshold_minutes' => 15, 'time_in_window_close' => 20,
                               'time_out_window_open' => 10, 'time_out_window_close' => 15, 'minimum_dwell_minutes' => 20],
            default        => ['time_in_window_open' => 10, 'late_threshold_minutes' => 10, 'time_in_window_close' => 15,
                               'time_out_window_open' => 5, 'time_out_window_close' => 15, 'minimum_dwell_minutes' => 15],
        };
    }

    private function count(string $what, int $id): int
    {
        $this->counts[$what] = ($this->counts[$what] ?? 0) + 1;

        return $id;
    }

    private function department(string $code): int
    {
        return $this->departments[strtoupper($code)]
            ?? throw new InvalidArgumentException(sprintf('unknown department "%s". Known: %s.',
                $code, implode(', ', array_keys($this->departments))));
    }

    private function gradeLevelId(string $code): int
    {
        $code = strtoupper($code);

        if (!isset($this->gradeLevels[$code])) {
            $id = Database::instance()->scalar('SELECT grade_level_id FROM grade_levels WHERE grade_level_code = :c', ['c' => $code]);
            $this->gradeLevels[$code] = $id !== null ? (int) $id
                : throw new InvalidArgumentException(sprintf('unknown grade level "%s".', $code));
        }

        return $this->gradeLevels[$code];
    }

    private function classroomId(string $room): int
    {
        return $this->classrooms[strtoupper($room)]
            ?? throw new InvalidArgumentException(sprintf('classroom \"%s\" is not in the file\'s classrooms list.', $room));
    }

    private function subjectId(string $code): int
    {
        return $this->subjects[strtoupper($code)]
            ?? throw new InvalidArgumentException(sprintf('subject \"%s\" is not in the file\'s subjects list.', $code));
    }

    private function sectionId(string $code): int
    {
        return $this->sections[strtoupper($code)]['id']
            ?? throw new InvalidArgumentException(sprintf('section \"%s\" is not in the file\'s sections list.', $code));
    }

    private function teacherId(string $key): int
    {
        return $this->teachers[strtolower($key)]
            ?? throw new InvalidArgumentException(sprintf('teacher \"%s\" is not in the file\'s teachers list.', $key));
    }

    private static function req(array $r, string $field): string
    {
        $value = trim((string) ($r[$field] ?? ''));

        if ($value === '') {
            throw new InvalidArgumentException(sprintf('"%s" is missing.', $field));
        }

        return $value;
    }

    private static function time(string $value): string
    {
        $parsed = strtotime('1970-01-01 ' . $value);

        if ($parsed === false) {
            throw new InvalidArgumentException(sprintf('"%s" is not a time.', $value));
        }

        return date('H:i:s', $parsed);
    }

    private static function label(array $r): string
    {
        foreach (['student_number', 'code', 'room', 'key', 'subject'] as $field) {
            if (!empty($r[$field])) {
                return (string) $r[$field];
            }
        }

        return '?';
    }

    private static function describe(ValidationException $e): string
    {
        $messages = [];

        foreach ($e->errors() as $field => $list) {
            foreach ((array) $list as $message) {
                $messages[] = $field . ': ' . $message;
            }
        }

        return $messages === [] ? $e->getMessage() : implode('; ', $messages);
    }
}

/** @internal Rolls back a dry run once every row has been checked. */
final class DryRunFinished extends RuntimeException
{
}
