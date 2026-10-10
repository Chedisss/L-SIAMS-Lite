-- ===========================================================================
-- L-SIAMS · 007 · Triggers and views
-- ===========================================================================
-- The triggers here enforce two things the application must not be trusted to
-- get right on its own:
--   1. sections.enrolled_count is never a stale copy.
--   2. Attendance, audit and security history cannot be deleted or rewritten,
--      even by a direct SQL session with the application's credentials.
--
-- SQLite triggers have no IF or local variables, so each MariaDB IF becomes the
-- trigger's WHEN clause or a WHERE on the statement it guarded, and
-- SIGNAL SQLSTATE '45000' becomes RAISE(ABORT, ...): the one statement is
-- undone, the transaction around it stays open, and the message text is
-- unchanged because the application matches on some of it.
-- ===========================================================================

-- ------------------------------------------- section enrolment counters ----
DROP TRIGGER IF EXISTS trg_students_after_insert;
CREATE TRIGGER trg_students_after_insert
AFTER INSERT ON students
WHEN NEW.deleted_at IS NULL AND NEW.status = 'active'
BEGIN
    UPDATE sections
       SET enrolled_count = enrolled_count + 1
     WHERE section_id = NEW.section_id;
END;

-- was_counted / is_counted from the MariaDB version, written out in each WHERE.
DROP TRIGGER IF EXISTS trg_students_after_update;
CREATE TRIGGER trg_students_after_update
AFTER UPDATE ON students
BEGIN
    UPDATE sections
       SET enrolled_count = MAX(enrolled_count - 1, 0)
     WHERE section_id = OLD.section_id
       AND (OLD.deleted_at IS NULL AND OLD.status = 'active')
       AND (NOT (NEW.deleted_at IS NULL AND NEW.status = 'active') OR OLD.section_id <> NEW.section_id);

    UPDATE sections
       SET enrolled_count = enrolled_count + 1
     WHERE section_id = NEW.section_id
       AND (NEW.deleted_at IS NULL AND NEW.status = 'active')
       AND (NOT (OLD.deleted_at IS NULL AND OLD.status = 'active') OR OLD.section_id <> NEW.section_id);
END;

-- Capacity is a hard limit, not advice. Rejecting here means an enrolment can
-- never exceed capacity through any code path, including a direct import.
-- (No FOR UPDATE: the writer holds the only write lock on the whole file.)
DROP TRIGGER IF EXISTS trg_students_before_insert;
CREATE TRIGGER trg_students_before_insert
BEFORE INSERT ON students
WHEN NEW.deleted_at IS NULL AND NEW.status = 'active'
 AND (SELECT enrolled_count >= capacity FROM sections WHERE section_id = NEW.section_id)
BEGIN
    SELECT RAISE(ABORT, 'SECTION_CAPACITY_EXCEEDED');
END;

-- ---------------------------------------- immutable historical records ----
DROP TRIGGER IF EXISTS trg_attendance_no_delete;
CREATE TRIGGER trg_attendance_no_delete
BEFORE DELETE ON attendance_records
BEGIN
    SELECT RAISE(ABORT, 'Attendance records are permanent and cannot be deleted. Use an administrator correction instead.');
END;

-- An attendance row cannot be deleted, but it must still be updatable: a
-- time-out writes onto the existing row, session close stamps automatic
-- time-outs, and an administrator correction may amend the times and statuses
-- (recording every change in attendance_modifications with a reason).
--
-- What must never change is *whose* record it is and *what* it is a record of.
-- Re-pointing a row at a different student, session, section, subject, teacher
-- or classroom would silently rewrite history while leaving the correction
-- trail describing something else entirely — the one edit no legitimate code
-- path performs, and exactly what a compromised one would attempt.
--
-- IS NOT is SQLite's NULL-safe inequality, MariaDB's NOT (a <=> b).
DROP TRIGGER IF EXISTS trg_attendance_immutable_identity;
CREATE TRIGGER trg_attendance_immutable_identity
BEFORE UPDATE ON attendance_records
WHEN NEW.attendance_id  IS NOT OLD.attendance_id
  OR NEW.session_id     IS NOT OLD.session_id
  OR NEW.student_id     IS NOT OLD.student_id
  OR NEW.section_id     IS NOT OLD.section_id
  OR NEW.grade_level_id IS NOT OLD.grade_level_id
  OR NEW.subject_id     IS NOT OLD.subject_id
  OR NEW.teacher_id     IS NOT OLD.teacher_id
  OR NEW.classroom_id   IS NOT OLD.classroom_id
  OR NEW.created_at     IS NOT OLD.created_at
  OR NEW.rfid_uid       IS NOT OLD.rfid_uid
  OR NEW.request_id     IS NOT OLD.request_id
BEGIN
    SELECT RAISE(ABORT, 'An attendance record cannot be re-attributed. Its student, session, section, grade level, subject, teacher, classroom, card, request id and creation time are permanent.');
END;

DROP TRIGGER IF EXISTS trg_audit_no_delete;
CREATE TRIGGER trg_audit_no_delete
BEFORE DELETE ON audit_logs
BEGIN
    SELECT RAISE(ABORT, 'Audit logs are immutable and cannot be deleted.');
END;

DROP TRIGGER IF EXISTS trg_audit_no_update;
CREATE TRIGGER trg_audit_no_update
BEFORE UPDATE ON audit_logs
BEGIN
    SELECT RAISE(ABORT, 'Audit logs are immutable and cannot be modified.');
END;

DROP TRIGGER IF EXISTS trg_security_no_delete;
CREATE TRIGGER trg_security_no_delete
BEFORE DELETE ON security_logs
BEGIN
    SELECT RAISE(ABORT, 'Security logs are immutable and cannot be deleted.');
END;

DROP TRIGGER IF EXISTS trg_login_history_no_delete;
CREATE TRIGGER trg_login_history_no_delete
BEFORE DELETE ON login_history
BEGIN
    SELECT RAISE(ABORT, 'Login history is permanent and cannot be deleted.');
END;

-- Every attendance correction must carry a reason. The column is NOT NULL, but
-- an empty string would satisfy that; this closes the gap.
DROP TRIGGER IF EXISTS trg_modification_requires_reason;
CREATE TRIGGER trg_modification_requires_reason
BEFORE INSERT ON attendance_modifications
WHEN NEW.reason IS NULL OR TRIM(NEW.reason) = ''
BEGIN
    SELECT RAISE(ABORT, 'An attendance modification requires a reason.');
END;

-- A student's grade level is derived from their section (Part 13.5). This
-- guards the denormalised copy on attendance_records against ever disagreeing
-- with the section it was written alongside. A section that does not exist
-- gives NULL, which IS NOT any grade, so it is refused too.
DROP TRIGGER IF EXISTS trg_attendance_grade_consistency;
CREATE TRIGGER trg_attendance_grade_consistency
BEFORE INSERT ON attendance_records
WHEN (SELECT grade_level_id FROM sections WHERE section_id = NEW.section_id) IS NOT NEW.grade_level_id
BEGIN
    SELECT RAISE(ABORT, 'Attendance grade level does not match the recorded section.');
END;

-- ===========================================================================
-- Views
-- ===========================================================================
-- SQLite has no CREATE OR REPLACE VIEW; dropping first is the same thing.
-- NOW() and CURDATE() are supplied by the application (app/Core/Database.php)
-- in APP_TIMEZONE, as MariaDB's were through the session time zone.

-- Flattened attendance for the admin table, live feed and every report. Keeping
-- the joins in one place means the ~12 call sites cannot drift apart.
DROP VIEW IF EXISTS v_attendance_detail;
CREATE VIEW v_attendance_detail AS
SELECT
  ar.attendance_id,
  ar.session_id,
  ases.session_code,
  ar.student_id,
  s.student_number,
  s.last_name || ', ' || s.first_name
    || COALESCE(' ' || substr(s.middle_name, 1, 1) || '.', '') AS student_name,
  s.photo_path AS student_photo,
  ar.section_id,
  sec.section_code,
  sec.section_name,
  ar.grade_level_id,
  gl.grade_level_code,
  gl.grade_level_name,
  gl.numeric_level,
  ar.subject_id,
  sub.subject_code,
  sub.subject_name,
  sub.department_id,
  d.department_code,
  ar.teacher_id,
  t.last_name || ', ' || t.first_name AS teacher_name,
  ar.classroom_id,
  c.room_number,
  ar.rfid_uid,
  ar.time_in,
  ar.time_out,
  ar.duration_minutes,
  ar.time_in_device_id,
  ar.time_out_device_id,
  ar.auto_generated_time_out,
  ar.arrival_status,
  ar.departure_status,
  ar.final_status,
  ar.synced_offline,
  date(COALESCE(ar.time_in, ases.session_date)) AS attendance_date,
  ar.created_at
FROM attendance_records ar
JOIN attendance_sessions ases ON ases.session_id = ar.session_id
JOIN students s      ON s.student_id     = ar.student_id
JOIN sections sec    ON sec.section_id   = ar.section_id
JOIN grade_levels gl ON gl.grade_level_id = ar.grade_level_id
JOIN subjects sub    ON sub.subject_id   = ar.subject_id
JOIN departments d   ON d.department_id  = sub.department_id
JOIN teachers t      ON t.teacher_id     = ar.teacher_id
JOIN classrooms c    ON c.classroom_id   = ar.classroom_id;

-- Device fleet health, with online/offline derived from the heartbeat timeout
-- rather than a status column that could go stale between sweeps.
-- strftime('%s') turns both local times into seconds the same way, so their
-- difference is the elapsed time, as TIMESTAMPDIFF(SECOND, ...) gave it.
DROP VIEW IF EXISTS v_device_status;
CREATE VIEW v_device_status AS
SELECT
  dev.id AS device_row_id,
  dev.device_id,
  dev.device_name,
  dev.mac_address,
  dev.ip_address,
  dev.firmware_version,
  dev.device_role,
  dev.classroom_id,
  c.room_number,
  c.building,
  dev.wifi_signal,
  dev.queue_depth,
  dev.uptime_seconds,
  dev.battery_percent,
  dev.status AS configured_status,
  dev.claim_status,
  dev.last_heartbeat_at,
  CAST(strftime('%s', now()) AS INTEGER) - CAST(strftime('%s', dev.last_heartbeat_at) AS INTEGER) AS seconds_since_heartbeat,
  CASE
    WHEN dev.status IN ('disabled','decommissioned','suspended') THEN 'disabled'
    WHEN dev.claim_status <> 'claimed' THEN 'pending'
    WHEN dev.last_heartbeat_at IS NULL THEN 'offline'
    WHEN CAST(strftime('%s', now()) AS INTEGER) - CAST(strftime('%s', dev.last_heartbeat_at) AS INTEGER) <= 45 THEN 'online'
    WHEN CAST(strftime('%s', now()) AS INTEGER) - CAST(strftime('%s', dev.last_heartbeat_at) AS INTEGER) <= 90 THEN 'warning'
    ELSE 'offline'
  END AS health,
  -- Configuration the device detail page edits in place, so that screen needs
  -- one read rather than a second query against `devices`.
  dev.ip_allowlist,
  dev.heartbeat_interval_sec,
  dev.sync_interval_sec,
  dev.offline_queue_limit,
  dev.location_note,
  ak.key_id,
  ak.secret_last_four,
  ak.status AS key_status,
  ak.created_at AS key_created_at,
  CAST(julianday(date(now())) - julianday(date(ak.created_at)) AS INTEGER) AS key_age_days,
  ak.last_used_at AS key_last_used_at,
  ak.use_count AS key_use_count,
  sess.session_id AS active_session_id,
  sess.session_code AS active_session_code
FROM devices dev
LEFT JOIN classrooms c ON c.classroom_id = dev.classroom_id
LEFT JOIN api_keys ak  ON ak.device_row_id = dev.id AND ak.status IN ('active','rotating')
LEFT JOIN attendance_sessions sess ON sess.device_row_id = dev.id AND sess.status = 'open'
WHERE dev.deleted_at IS NULL;

-- Everything the Part 14 validators and the cascading dropdowns need about a
-- teacher, in one row.
-- group_concat() takes its rows in the order the inner query hands them over;
-- that is how the codes stay sorted by grade without GROUP_CONCAT's ORDER BY.
DROP VIEW IF EXISTS v_teacher_constraints;
CREATE VIEW v_teacher_constraints AS
SELECT
  t.teacher_id,
  t.employee_number,
  t.last_name || ', ' || t.first_name AS teacher_name,
  t.department_id,
  d.department_code,
  d.department_name,
  t.fingerprint_status,
  t.status,
  (SELECT COUNT(*) FROM teacher_grade_levels tgl WHERE tgl.teacher_id = t.teacher_id) AS grade_level_count,
  (SELECT group_concat(ordered.grade_level_code, ',')
     FROM (SELECT gl.grade_level_code
             FROM teacher_grade_levels tgl
             JOIN grade_levels gl ON gl.grade_level_id = tgl.grade_level_id
            WHERE tgl.teacher_id = t.teacher_id
            ORDER BY gl.numeric_level) AS ordered) AS grade_level_codes,
  (SELECT COUNT(*) FROM subjects s
    WHERE s.department_id = t.department_id AND s.status = 'active' AND s.deleted_at IS NULL) AS assignable_subject_count,
  (SELECT COUNT(*) FROM sections sec
     JOIN teacher_grade_levels tgl2 ON tgl2.grade_level_id = sec.grade_level_id AND tgl2.teacher_id = t.teacher_id
    WHERE sec.status = 'active' AND sec.deleted_at IS NULL) AS assignable_section_count,
  (SELECT COUNT(*) FROM schedules sch
    WHERE sch.teacher_id = t.teacher_id AND sch.status = 'active' AND sch.deleted_at IS NULL) AS active_schedule_count
FROM teachers t
JOIN departments d ON d.department_id = t.department_id
WHERE t.deleted_at IS NULL;

-- Section rollup used by the Sections page, adviser reports and the
-- section-comparison chart.
-- SQLite divides integers as integers (7 / 2 = 3), so the percentages multiply
-- by 100.0 first to get MariaDB's decimal result.
DROP VIEW IF EXISTS v_section_summary;
CREATE VIEW v_section_summary AS
SELECT
  sec.section_id,
  sec.section_code,
  sec.section_name,
  sec.grade_level_id,
  gl.grade_level_code,
  gl.numeric_level,
  sec.strand,
  sec.capacity,
  sec.enrolled_count,
  ROUND(sec.enrolled_count * 100.0 / NULLIF(sec.capacity, 0), 1) AS capacity_percent,
  sec.adviser_id,
  t.last_name || ', ' || t.first_name AS adviser_name,
  sec.status,
  (SELECT COUNT(*) FROM students st
    WHERE st.section_id = sec.section_id AND st.deleted_at IS NULL AND st.status = 'active') AS active_students,
  (SELECT COUNT(*) FROM students st
     JOIN rfid_cards rc ON rc.student_id = st.student_id AND rc.status = 'active'
    WHERE st.section_id = sec.section_id AND st.deleted_at IS NULL AND st.status = 'active') AS students_with_cards,
  (SELECT ROUND(
            SUM(CASE WHEN ar.final_status IN ('Present','Late') THEN 1 ELSE 0 END) * 100.0
            / NULLIF(COUNT(*), 0), 2)
     FROM attendance_records ar
    WHERE ar.section_id = sec.section_id
      AND ar.time_in >= date(curdate(), '-30 days')) AS attendance_percentage_30d
FROM sections sec
JOIN grade_levels gl ON gl.grade_level_id = sec.grade_level_id
LEFT JOIN teachers t ON t.teacher_id = sec.adviser_id
WHERE sec.deleted_at IS NULL;
