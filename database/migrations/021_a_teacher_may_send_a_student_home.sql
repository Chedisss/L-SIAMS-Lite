-- ===========================================================================
-- L-SIAMS · 021 · A teacher may release a student from the room
-- ===========================================================================
-- A student is sick. A parent is at the gate. Something has happened at home.
-- The student leaves, and until now the system had no way to say so.
--
-- The card reader could not help. Tapping out before the tap-out window opens
-- is refused until the minimum dwell has elapsed, which is exactly right for a
-- student trying to tap in and walk out — and exactly wrong for a child who
-- has been unwell for ten minutes. The class then ended with that student
-- recorded as present for the whole period, or auto-stamped at the bell for a
-- room they had left an hour earlier.
--
-- So the teacher releases them: one button on their own session roster, and a
-- reason the system insists on. The record becomes a real departure at the
-- real time, marked Left Early, which is what actually happened.
--
-- Three columns:
--
--   early_release_reason  why, from a fixed list, so the reason is countable.
--                         A free-text-only field produces "sick", "Sick",
--                         "feeling unwell", "unwell" and "SICK" in one term
--                         and answers no question anybody asks of it.
--   early_release_note    the teacher's own words, for what the list cannot
--                         say. Required when the reason is 'other', because
--                         'other' with no note records nothing at all.
--   early_released_by     the account that authorised it. RESTRICT, so that
--                         account cannot be deleted out from under the record
--                         — the same rule the session's own opened_by_user_id
--                         follows, and for the same reason.
--
-- NULL in all three is the ordinary case: the student tapped out, or is still
-- in the room, or never arrived. A release is never inferred from the status
-- alone, because 'left_early' is also what a genuine early tap-out produces
-- and the two are not the same event.
--
-- auto_generated_time_out stays 0 on a release. That flag means the system
-- stamped a departure nobody witnessed; here a named person recorded one they
-- did, and every screen that reads the flag would otherwise show the robot
-- icon over a decision a teacher made deliberately.
-- ===========================================================================


-- The three columns, the index and fk_att_released_by arrive in one rebuild:
-- SQLite cannot add a named foreign key to an existing table.
-- The table is rebuilt: a new one in the final shape, the rows copied across,
-- the old one dropped and the new one renamed into its place. Indexes and
-- triggers go with the old table, so they are recreated after.
CREATE TABLE attendance_records__new (
    attendance_id                INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id                   INTEGER NOT NULL,
    student_id                   INTEGER NOT NULL,
    section_id                   INTEGER NOT NULL,
    grade_level_id               INTEGER NOT NULL,
    subject_id                   INTEGER NOT NULL,
    teacher_id                   INTEGER NOT NULL,
    classroom_id                 INTEGER NOT NULL,
    rfid_uid                     TEXT COLLATE NOCASE,
    time_in                      TEXT,
    time_in_device_id            TEXT COLLATE NOCASE,
    time_in_ip                   TEXT COLLATE NOCASE,
    time_in_mac                  TEXT COLLATE NOCASE,
    time_out                     TEXT,
    time_out_device_id           TEXT COLLATE NOCASE,
    time_out_ip                  TEXT COLLATE NOCASE,
    time_out_mac                 TEXT COLLATE NOCASE,
    auto_generated_time_out      INTEGER NOT NULL DEFAULT 0,
    duration_minutes             INTEGER,
    arrival_status               TEXT NOT NULL COLLATE NOCASE CHECK (arrival_status IN ('present', 'late', 'absent', 'excused', 'official_business')),
    departure_status             TEXT NOT NULL DEFAULT 'pending' COLLATE NOCASE CHECK (departure_status IN ('pending', 'timed_out', 'left_early', 'no_time_out', 'auto_closed')),
    early_release_reason         TEXT COLLATE NOCASE CHECK (early_release_reason IN ('sickness', 'headache', 'injury', 'emergency', 'called_away', 'other')),
    early_release_note           TEXT COLLATE NOCASE,
    early_released_by            INTEGER,
    final_status                 TEXT NOT NULL COLLATE NOCASE CHECK (final_status IN ('Present', 'Late', 'Absent', 'Excused', 'Official Business', 'Incomplete', 'Left Early')),
    request_id                   TEXT COLLATE NOCASE,
    carried_from_session_id      INTEGER,
    synced_offline               INTEGER NOT NULL DEFAULT 0,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_att_carried_from FOREIGN KEY (carried_from_session_id) REFERENCES attendance_sessions (session_id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_att_classroom FOREIGN KEY (classroom_id) REFERENCES classrooms (classroom_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_att_grade FOREIGN KEY (grade_level_id) REFERENCES grade_levels (grade_level_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_att_released_by FOREIGN KEY (early_released_by) REFERENCES users (user_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_att_section FOREIGN KEY (section_id) REFERENCES sections (section_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_att_session FOREIGN KEY (session_id) REFERENCES attendance_sessions (session_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_att_student FOREIGN KEY (student_id) REFERENCES students (student_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_att_subject FOREIGN KEY (subject_id) REFERENCES subjects (subject_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_att_teacher FOREIGN KEY (teacher_id) REFERENCES teachers (teacher_id) ON DELETE RESTRICT ON UPDATE CASCADE
);
INSERT INTO attendance_records__new (attendance_id, session_id, student_id, section_id, grade_level_id, subject_id, teacher_id, classroom_id, rfid_uid, time_in, time_in_device_id, time_in_ip, time_in_mac, time_out, time_out_device_id, time_out_ip, time_out_mac, auto_generated_time_out, duration_minutes, arrival_status, departure_status, final_status, request_id, carried_from_session_id, synced_offline, created_at, updated_at)
    SELECT attendance_id, session_id, student_id, section_id, grade_level_id, subject_id, teacher_id, classroom_id, rfid_uid, time_in, time_in_device_id, time_in_ip, time_in_mac, time_out, time_out_device_id, time_out_ip, time_out_mac, auto_generated_time_out, duration_minutes, arrival_status, departure_status, final_status, request_id, carried_from_session_id, synced_offline, created_at, updated_at FROM attendance_records;
DROP TABLE attendance_records;
ALTER TABLE attendance_records__new RENAME TO attendance_records;
CREATE INDEX fk_att_classroom ON attendance_records (classroom_id);
CREATE INDEX fk_att_released_by ON attendance_records (early_released_by);
CREATE INDEX idx_att_carried_from ON attendance_records (carried_from_session_id);
CREATE INDEX idx_att_early_release ON attendance_records (early_release_reason, time_out);
CREATE INDEX idx_att_final_status ON attendance_records (final_status, time_in);
CREATE INDEX idx_att_grade_date ON attendance_records (grade_level_id, time_in);
CREATE INDEX idx_att_section_date ON attendance_records (section_id, time_in);
CREATE INDEX idx_att_session ON attendance_records (session_id);
CREATE INDEX idx_att_student_date ON attendance_records (student_id, time_in);
CREATE INDEX idx_att_subject_date ON attendance_records (subject_id, time_in);
CREATE INDEX idx_att_teacher_date ON attendance_records (teacher_id, time_in);
CREATE UNIQUE INDEX uq_attendance_request_id ON attendance_records (request_id);
CREATE UNIQUE INDEX uq_attendance_session_student ON attendance_records (session_id, student_id);

CREATE TRIGGER trg_attendance_records_updated_at
AFTER UPDATE ON attendance_records
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.attendance_id IS NOT OLD.attendance_id
    OR NEW.session_id IS NOT OLD.session_id
    OR NEW.student_id IS NOT OLD.student_id
    OR NEW.section_id IS NOT OLD.section_id
    OR NEW.grade_level_id IS NOT OLD.grade_level_id
    OR NEW.subject_id IS NOT OLD.subject_id
    OR NEW.teacher_id IS NOT OLD.teacher_id
    OR NEW.classroom_id IS NOT OLD.classroom_id
    OR NEW.rfid_uid IS NOT OLD.rfid_uid
    OR NEW.time_in IS NOT OLD.time_in
    OR NEW.time_in_device_id IS NOT OLD.time_in_device_id
    OR NEW.time_in_ip IS NOT OLD.time_in_ip
    OR NEW.time_in_mac IS NOT OLD.time_in_mac
    OR NEW.time_out IS NOT OLD.time_out
    OR NEW.time_out_device_id IS NOT OLD.time_out_device_id
    OR NEW.time_out_ip IS NOT OLD.time_out_ip
    OR NEW.time_out_mac IS NOT OLD.time_out_mac
    OR NEW.auto_generated_time_out IS NOT OLD.auto_generated_time_out
    OR NEW.duration_minutes IS NOT OLD.duration_minutes
    OR NEW.arrival_status IS NOT OLD.arrival_status
    OR NEW.departure_status IS NOT OLD.departure_status
    OR NEW.early_release_reason IS NOT OLD.early_release_reason
    OR NEW.early_release_note IS NOT OLD.early_release_note
    OR NEW.early_released_by IS NOT OLD.early_released_by
    OR NEW.final_status IS NOT OLD.final_status
    OR NEW.request_id IS NOT OLD.request_id
    OR NEW.carried_from_session_id IS NOT OLD.carried_from_session_id
    OR NEW.synced_offline IS NOT OLD.synced_offline
    OR NEW.created_at IS NOT OLD.created_at
)
BEGIN
    UPDATE attendance_records SET updated_at = now() WHERE attendance_id = NEW.attendance_id;
END;
-- Views that read attendance_records are untouched: the runner renames with legacy_alter_table,
-- which leaves them pointing at the name, not the dropped table.

-- The triggers on attendance_records, recreated as they were.
CREATE TRIGGER trg_attendance_no_delete
BEFORE DELETE ON attendance_records
BEGIN
    SELECT RAISE(ABORT, 'Attendance records are permanent and cannot be deleted. Use an administrator correction instead.');
END;

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

CREATE TRIGGER trg_attendance_grade_consistency
BEFORE INSERT ON attendance_records
WHEN (SELECT grade_level_id FROM sections WHERE section_id = NEW.section_id) IS NOT NEW.grade_level_id
BEGIN
    SELECT RAISE(ABORT, 'Attendance grade level does not match the recorded section.');
END;

-- ---------------------------------------------------------------------------
-- A release must carry a reason
-- ---------------------------------------------------------------------------
-- The service validates this before it writes, and the form will not submit
-- without it. The trigger is there for the third path — a console command, a
-- future import, a hand-typed UPDATE during a support call — because "every
-- release has a reason" is a property of the data, not a property of one
-- code path that happens to be careful today. Same argument as
-- trg_modification_requires_reason, which is why it reads the same way.
-- ---------------------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_release_requires_reason;


CREATE TRIGGER trg_release_requires_reason
BEFORE UPDATE ON attendance_records
BEGIN
    SELECT RAISE(ABORT, 'An early release requires a reason.')
     WHERE NEW.early_released_by IS NOT NULL AND NEW.early_release_reason IS NULL;

    SELECT RAISE(ABORT, 'An early release recorded as Other requires a note saying what happened.')
     WHERE NEW.early_release_reason = 'other'
       AND (NEW.early_release_note IS NULL OR TRIM(NEW.early_release_note) = '');
END;;


-- ---------------------------------------------------------------------------
-- v_attendance_detail
-- ---------------------------------------------------------------------------
-- Reports and exports read this view. A departure the teacher authorised and
-- one the student tapped are different facts, and a register that cannot tell
-- them apart cannot answer "how many students went home sick this month" —
-- which is the first question anybody will ask of this feature.
-- ---------------------------------------------------------------------------

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
  ar.carried_from_session_id,
  prev.session_code AS carried_from_code,
  prevsub.subject_code AS carried_from_subject,
  ar.early_release_reason,
  ar.early_release_note,
  ar.early_released_by,
  ru.full_name AS early_released_by_name,
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
JOIN classrooms c    ON c.classroom_id   = ar.classroom_id
LEFT JOIN attendance_sessions prev ON prev.session_id = ar.carried_from_session_id
LEFT JOIN subjects prevsub         ON prevsub.subject_id = prev.subject_id
LEFT JOIN users ru                 ON ru.user_id = ar.early_released_by;

