<?php
declare(strict_types=1);

/**
 * The test fixture shared by run.php and parallel.php: a department, a
 * teacher, sections of students with cards, classrooms, devices and a
 * schedule for each, all prefixed TEST-CONC- so teardown() can find them.
 */

use App\Core\Clock;
use App\Core\Database;

/**
 * Builds a self-contained scenario: departments, sections, students, cards,
 * devices and schedules, all prefixed so teardown can find them again.
 */
final class Fixture
{
    public const PREFIX = 'TEST-CONC-';

    private Database $db;
    /** @var array<string,mixed> */
    public array $ids = [];

    public function __construct()
    {
        $this->db = Database::instance();
    }

    /** @return array<string,mixed> */
    public function build(int $sectionCount = 2, int $studentsPerSection = 45, int $deviceCount = 2): array
    {
        $this->teardown();

        $now  = Clock::nowString();
        $year = (int) $this->db->scalar('SELECT school_year_id FROM school_years WHERE is_current = 1 LIMIT 1');

        if ($year === 0) {
            $year = (int) $this->db->insert('school_years', [
                'year_label' => self::PREFIX . 'YEAR',
                'start_date' => Clock::now()->modify('-3 months')->format('Y-m-d'),
                'end_date'   => Clock::now()->modify('+9 months')->format('Y-m-d'),
                'is_current' => 1,
                'status'     => 'active',
            ]);
        }

        $departmentId = (int) $this->db->insert('departments', [
            'department_code' => self::PREFIX . 'DEP',
            'department_name' => self::PREFIX . 'Department',
            'status'          => 'active',
            'created_at'      => $now,
            'updated_at'      => $now,
        ]);

        $gradeLevelId = (int) $this->db->scalar(
            'SELECT grade_level_id FROM grade_levels ORDER BY numeric_level DESC LIMIT 1'
        );

        $subjectId = (int) $this->db->insert('subjects', [
            'subject_code'  => self::PREFIX . 'SUB',
            'subject_name'  => self::PREFIX . 'Subject',
            'department_id' => $departmentId,
            'status'        => 'active',
            'created_at'    => $now,
            'updated_at'    => $now,
        ]);

        $this->db->execute(
            'INSERT OR IGNORE INTO subject_grade_levels (subject_id, grade_level_id) VALUES (:s, :g)',
            ['s' => $subjectId, 'g' => $gradeLevelId]
        );

        $teacherId = (int) $this->db->insert('teachers', [
            'employee_number' => self::PREFIX . 'T1',
            'department_id'   => $departmentId,
            'first_name'      => 'Concurrency',
            'last_name'       => 'Tester',
            'email'           => 'concurrency.tester@' . strtolower(self::PREFIX) . 'test.local',
            'status'          => 'active',
            'fingerprint_status' => 'enrolled',
            'created_at'      => $now,
            'updated_at'      => $now,
        ]);

        $this->db->execute(
            'INSERT OR IGNORE INTO teacher_grade_levels (teacher_id, grade_level_id) VALUES (:t, :g)',
            ['t' => $teacherId, 'g' => $gradeLevelId]
        );

        $this->db->execute(
            'INSERT OR IGNORE INTO teacher_departments (teacher_id, department_id, is_primary) VALUES (:t, :d, 1)',
            ['t' => $teacherId, 'd' => $departmentId]
        );

        $fingerprintId = (int) $this->db->insert('fingerprint_templates', [
            'teacher_id'         => $teacherId,
            'sensor_template_id' => 900,
            'enrollment_date'    => $now,
            'status'             => 'active',
            'created_at'         => $now,
            'updated_at'         => $now,
        ]);

        $sections = [];
        $students = [];
        $cards    = [];

        for ($s = 0; $s < $sectionCount; $s++) {
            $sectionId = (int) $this->db->insert('sections', [
                'section_code'   => self::PREFIX . 'SEC' . $s,
                'section_name'   => 'Test Section ' . $s,
                'grade_level_id' => $gradeLevelId,
                'capacity'       => max(50, $studentsPerSection + 5),
                'school_year_id' => $year,
                'status'         => 'active',
                'created_at'     => $now,
                'updated_at'     => $now,
            ]);

            $sections[] = $sectionId;

            for ($i = 0; $i < $studentsPerSection; $i++) {
                $studentId = (int) $this->db->insert('students', [
                    'student_number'   => sprintf('%sS%d-%03d', self::PREFIX, $s, $i),
                    'section_id'       => $sectionId,
                    'first_name'       => 'Student' . $i,
                    'last_name'        => 'Section' . $s,
                    'guardian_name'    => 'Guardian ' . $i,
                    'guardian_contact' => '09170000000',
                    'status'           => 'active',
                    'created_at'       => $now,
                    'updated_at'       => $now,
                ]);

                $uid = strtoupper(sprintf('%02X%02X%06X', 0xC0 + $s, $i, random_int(0, 0xFFFFFF)));

                $this->db->insert('rfid_cards', [
                    'student_id' => $studentId,
                    'card_uid'   => $uid,
                    'issue_date' => Clock::today(),
                    'status'     => 'active',
                    'created_at' => $now,
                    'updated_at' => $now,
                ]);

                $students[$sectionId][] = $studentId;
                $cards[$sectionId][]    = $uid;

                $this->db->execute(
                    'INSERT OR IGNORE INTO student_subject_enrolments
                          (student_id, subject_id, section_id, school_year_id, status, created_at, updated_at)
                     VALUES (:st, :sub, :sec, :yr, \'enrolled\', :now, :now)',
                    ['st' => $studentId, 'sub' => $subjectId, 'sec' => $sectionId, 'yr' => $year, 'now' => $now]
                );
            }
        }

        $classrooms = [];
        $devices    = [];
        $schedules  = [];

        for ($d = 0; $d < $deviceCount; $d++) {
            $classroomId = (int) $this->db->insert('classrooms', [
                'room_number' => self::PREFIX . 'R' . $d,
                'capacity'    => 60,
                'status'      => 'active',
                'created_at'  => $now,
                'updated_at'  => $now,
            ]);

            $deviceRowId = (int) $this->db->insert('devices', [
                'device_id'    => sprintf('%sDEV%03d', self::PREFIX, $d),
                'device_name'  => 'Test Terminal ' . $d,
                'mac_address'  => sprintf('AA:BB:CC:00:%02X:%02X', $d, random_int(0, 255)),
                'classroom_id' => $classroomId,
                'device_role'  => 'both',
                'status'       => 'active',
                'claim_status' => 'claimed',
                'timezone'     => 'Asia/Manila',
                'created_at'   => $now,
                'updated_at'   => $now,
            ]);

            // Windows are set wide so the tests exercise concurrency rather
            // than tripping over clock boundaries. The suite freezes the clock
            // at 10:00 precisely so this window is always well inside the day —
            // see the Clock::freeze() call where the runner is constructed.
            $start = Clock::now()->modify('-10 minutes');
            $end   = Clock::now()->modify('+110 minutes');

            $scheduleId = (int) $this->db->insert('schedules', [
                'teacher_id'     => $teacherId,
                'subject_id'     => $subjectId,
                'section_id'     => $sections[$d % count($sections)],
                'classroom_id'   => $classroomId,
                'school_year_id' => $year,
                'day_of_week'    => Clock::now()->format('l'),
                'start_time'     => $start->format('H:i:s'),
                'end_time'       => $end->format('H:i:s'),
                'time_in_window_open'    => 30,
                'late_threshold_minutes' => 15,
                'time_in_window_close'   => 60,
                'time_out_window_open'   => 30,
                'time_out_window_close'  => 30,
                'minimum_dwell_minutes'  => 1,
                'status'     => 'active',
                'created_at' => $now,
                'updated_at' => $now,
            ]);

            $classrooms[] = $classroomId;
            $devices[]    = $deviceRowId;
            $schedules[]  = $scheduleId;
        }

        return $this->ids = [
            'department_id'  => $departmentId,
            'grade_level_id' => $gradeLevelId,
            'subject_id'     => $subjectId,
            'teacher_id'     => $teacherId,
            'fingerprint_id' => $fingerprintId,
            'school_year_id' => $year,
            'sections'       => $sections,
            'students'       => $students,
            'cards'          => $cards,
            'classrooms'     => $classrooms,
            'devices'        => $devices,
            'schedules'      => $schedules,
        ];
    }

    /** @return array<string,mixed> */
    public function device(int $index = 0): array
    {
        return $this->db->selectOne(
            'SELECT * FROM devices WHERE id = :id',
            ['id' => $this->ids['devices'][$index]]
        ) ?? [];
    }

    /** @return array<string,mixed> */
    public function schedule(int $index = 0): array
    {
        return $this->db->selectOne(
            'SELECT sch.*, s.subject_code, s.subject_name, sec.section_code, c.room_number
               FROM schedules sch
               JOIN subjects s   ON s.subject_id = sch.subject_id
               JOIN sections sec ON sec.section_id = sch.section_id
               JOIN classrooms c ON c.classroom_id = sch.classroom_id
              WHERE sch.schedule_id = :id',
            ['id' => $this->ids['schedules'][$index]]
        ) ?? [];
    }

    /** @return array<string,mixed> */
    public function teacher(): array
    {
        return $this->db->selectOne(
            'SELECT * FROM teachers WHERE teacher_id = :id',
            ['id' => $this->ids['teacher_id']]
        ) ?? [];
    }

    /** Remove every row this fixture created, in dependency order. */
    public function teardown(): void
    {
        $db     = $this->db;
        $prefix = self::PREFIX . '%';

        $db->pdo()->exec('PRAGMA foreign_keys = OFF');

        // Attendance history is protected by a BEFORE DELETE trigger, so test
        // rows have to be removed with the trigger temporarily out of the way.
        // This is the only place in the entire system that does this, and it
        // only ever touches TEST-CONC- prefixed data.
        $db->pdo()->exec('DROP TRIGGER IF EXISTS trg_attendance_no_delete');

        $db->execute(
            'DELETE FROM attendance_records
              WHERE session_id IN (SELECT s.session_id
                                     FROM attendance_sessions s
                                     JOIN devices d ON d.id = s.device_row_id
                                    WHERE d.device_id LIKE :prefix)',
            ['prefix' => $prefix]
        );

        $db->execute(
            'DELETE FROM rfid_logs
              WHERE device_row_id IN (SELECT id FROM devices WHERE device_id LIKE :prefix)',
            ['prefix' => $prefix]
        );

        $db->execute(
            'DELETE FROM attendance_sessions
              WHERE device_row_id IN (SELECT id FROM devices WHERE device_id LIKE :prefix)',
            ['prefix' => $prefix]
        );

        $db->execute('DELETE FROM fingerprint_logs WHERE teacher_id IN
            (SELECT teacher_id FROM teachers WHERE employee_number LIKE :prefix)', ['prefix' => $prefix]);
        $db->execute('DELETE FROM fingerprint_templates WHERE teacher_id IN
            (SELECT teacher_id FROM teachers WHERE employee_number LIKE :prefix)', ['prefix' => $prefix]);

        $db->execute('DELETE FROM student_subject_enrolments WHERE student_id IN
            (SELECT student_id FROM students WHERE student_number LIKE :prefix)', ['prefix' => $prefix]);
        $db->execute('DELETE FROM student_section_history WHERE student_id IN
            (SELECT student_id FROM students WHERE student_number LIKE :prefix)', ['prefix' => $prefix]);
        $db->execute('DELETE FROM rfid_cards WHERE student_id IN
            (SELECT student_id FROM students WHERE student_number LIKE :prefix)', ['prefix' => $prefix]);
        $db->execute('DELETE FROM students WHERE student_number LIKE :prefix', ['prefix' => $prefix]);

        $db->execute('DELETE FROM device_nonces WHERE device_row_id IN
            (SELECT id FROM devices WHERE device_id LIKE :prefix)', ['prefix' => $prefix]);
        $db->execute('DELETE FROM device_heartbeats WHERE device_row_id IN
            (SELECT id FROM devices WHERE device_id LIKE :prefix)', ['prefix' => $prefix]);
        $db->execute('DELETE FROM device_logs WHERE device_id_text LIKE :prefix', ['prefix' => $prefix]);
        $db->execute('DELETE FROM api_key_history WHERE device_row_id IN
            (SELECT id FROM devices WHERE device_id LIKE :prefix)', ['prefix' => $prefix]);
        $db->execute('DELETE FROM api_keys WHERE device_row_id IN
            (SELECT id FROM devices WHERE device_id LIKE :prefix)', ['prefix' => $prefix]);
        $db->execute('DELETE FROM device_claims WHERE device_row_id IN
            (SELECT id FROM devices WHERE device_id LIKE :prefix)', ['prefix' => $prefix]);

        $db->execute('DELETE FROM schedules WHERE classroom_id IN
            (SELECT classroom_id FROM classrooms WHERE room_number LIKE :prefix)', ['prefix' => $prefix]);
        $db->execute('DELETE FROM devices WHERE device_id LIKE :prefix', ['prefix' => $prefix]);
        $db->execute('DELETE FROM classrooms WHERE room_number LIKE :prefix', ['prefix' => $prefix]);

        $db->execute('DELETE FROM teacher_sections WHERE section_id IN
            (SELECT section_id FROM sections WHERE section_code LIKE :prefix)', ['prefix' => $prefix]);
        $db->execute('DELETE FROM sections WHERE section_code LIKE :prefix', ['prefix' => $prefix]);

        $db->execute('DELETE FROM teacher_grade_levels WHERE teacher_id IN
            (SELECT teacher_id FROM teachers WHERE employee_number LIKE :prefix)', ['prefix' => $prefix]);
        $db->execute('DELETE FROM teacher_departments WHERE teacher_id IN
            (SELECT teacher_id FROM teachers WHERE employee_number LIKE :prefix)', ['prefix' => $prefix]);
        $db->execute('DELETE FROM teacher_subjects WHERE teacher_id IN
            (SELECT teacher_id FROM teachers WHERE employee_number LIKE :prefix)', ['prefix' => $prefix]);
        $db->execute('DELETE FROM teachers WHERE employee_number LIKE :prefix', ['prefix' => $prefix]);

        // The sign-in group leaves a user behind, and every trace of that user
        // sits in a table the system deliberately refuses to delete from:
        // login history, security events and the audit trail are all guarded by
        // BEFORE DELETE triggers, exactly as they should be. The triggers come
        // down only for the length of this cleanup, and only rows belonging to
        // the TEST-CONC- account are touched — the same bargain the attendance
        // trigger above is already under.
        $lockUsers = $db->select(
            'SELECT user_id FROM users WHERE username LIKE :prefix',
            ['prefix' => $prefix]
        );

        if ($lockUsers !== []) {
            $db->pdo()->exec('DROP TRIGGER IF EXISTS trg_login_history_no_delete');
            $db->pdo()->exec('DROP TRIGGER IF EXISTS trg_security_no_delete');
            $db->pdo()->exec('DROP TRIGGER IF EXISTS trg_audit_no_delete');

            foreach ($lockUsers as $row) {
                $userId = (int) $row['user_id'];

                $db->execute('DELETE FROM login_history WHERE user_id = :id', ['id' => $userId]);
                $db->execute('DELETE FROM security_logs WHERE user_id = :id', ['id' => $userId]);
                $db->execute('DELETE FROM audit_logs WHERE user_id = :id', ['id' => $userId]);
                $db->execute('DELETE FROM user_sessions WHERE user_id = :id', ['id' => $userId]);
                $db->execute('DELETE FROM users WHERE user_id = :id', ['id' => $userId]);
            }

            $db->pdo()->exec(
                "CREATE TRIGGER trg_login_history_no_delete
                 BEFORE DELETE ON login_history
                 BEGIN
                     SELECT RAISE(ABORT, 'Login history is permanent and cannot be deleted.');
                 END"
            );

            $db->pdo()->exec(
                "CREATE TRIGGER trg_security_no_delete
                 BEFORE DELETE ON security_logs
                 BEGIN
                     SELECT RAISE(ABORT, 'Security logs are immutable and cannot be deleted.');
                 END"
            );

            $db->pdo()->exec(
                "CREATE TRIGGER trg_audit_no_delete
                 BEFORE DELETE ON audit_logs
                 BEGIN
                     SELECT RAISE(ABORT, 'Audit logs are immutable and cannot be deleted.');
                 END"
            );
        }

        $db->execute('DELETE FROM login_attempts WHERE identifier LIKE :prefix', ['prefix' => $prefix]);

        $db->execute('DELETE FROM subject_grade_levels WHERE subject_id IN
            (SELECT subject_id FROM subjects WHERE subject_code LIKE :prefix)', ['prefix' => $prefix]);
        $db->execute('DELETE FROM subjects WHERE subject_code LIKE :prefix', ['prefix' => $prefix]);
        $db->execute('DELETE FROM departments WHERE department_code LIKE :prefix', ['prefix' => $prefix]);

        // Restore the protection trigger.
        $db->pdo()->exec(
            "CREATE TRIGGER trg_attendance_no_delete
             BEFORE DELETE ON attendance_records
             BEGIN
                 SELECT RAISE(ABORT, 'Attendance records are permanent and cannot be deleted. Use an administrator correction instead.');
             END"
        );

        $db->pdo()->exec('PRAGMA foreign_keys = ON');
    }
}
