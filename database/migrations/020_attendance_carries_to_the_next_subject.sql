-- ===========================================================================
-- L-SIAMS · 020 · Attendance carries to the next subject
-- ===========================================================================
-- A section sits in one room for most of the day. The bell rings, one teacher
-- leaves, the next walks in, and the same forty students are in the same
-- chairs. Making every one of them tap again for every period is forty taps of
-- queueing per subject, six or seven times a day, for a fact the system
-- already knows: they were here five minutes ago and they have not moved.
--
-- So a session that follows another one for the same section carries the
-- previous register forward. A student who was Present or Late in the period
-- that just ended starts the new period Present, without tapping.
--
-- What does NOT carry is anyone who was not in the room at the end:
--
--   Absent      never arrived                    → may still tap in
--   Left Early  tapped out before the bell       → may still tap in
--   Excused     excused from that class          → may still tap in
--   Incomplete  arrived, no tap-out on record    → may still tap in
--
-- That is the second half of the rule and the more important one. Missing the
-- first period must not condemn a student to being marked absent all day, and
-- leaving early must not either — they get the same chance to tap in for the
-- next subject as anyone else.
--
-- Two columns, so a carried row is never mistaken for a tap:
--
--   attendance_records.carried_from_session_id
--       the session this presence was inherited from. NULL means the student
--       tapped, which is what every existing row did. The time_in_device_id,
--       time_in_ip and time_in_mac of a carried row are NULL for the same
--       reason — no card was presented to any reader, and recording one would
--       be a lie that reports and audits would repeat.
--
--   attendance_sessions.carried_in_count
--       how many of this session's records arrived by carry rather than by
--       tap. A teacher looking at a full register can see at a glance how much
--       of it was actually scanned in front of them.
--
-- ON DELETE SET NULL, not CASCADE: attendance is never physically deleted, and
-- if a session row ever did go, the student's presence in the NEXT period is
-- still true — it would just no longer know where it came from.
-- ===========================================================================


-- SQLite cannot add a named foreign key to an existing table, so
-- carried_from_session_id, its index and fk_att_carried_from arrive in one
-- rebuild.
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
    final_status                 TEXT NOT NULL COLLATE NOCASE CHECK (final_status IN ('Present', 'Late', 'Absent', 'Excused', 'Official Business', 'Incomplete', 'Left Early')),
    request_id                   TEXT COLLATE NOCASE,
    carried_from_session_id      INTEGER,
    synced_offline               INTEGER NOT NULL DEFAULT 0,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_att_carried_from FOREIGN KEY (carried_from_session_id) REFERENCES attendance_sessions (session_id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_att_classroom FOREIGN KEY (classroom_id) REFERENCES classrooms (classroom_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_att_grade FOREIGN KEY (grade_level_id) REFERENCES grade_levels (grade_level_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_att_section FOREIGN KEY (section_id) REFERENCES sections (section_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_att_session FOREIGN KEY (session_id) REFERENCES attendance_sessions (session_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_att_student FOREIGN KEY (student_id) REFERENCES students (student_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_att_subject FOREIGN KEY (subject_id) REFERENCES subjects (subject_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_att_teacher FOREIGN KEY (teacher_id) REFERENCES teachers (teacher_id) ON DELETE RESTRICT ON UPDATE CASCADE
);
INSERT INTO attendance_records__new (attendance_id, session_id, student_id, section_id, grade_level_id, subject_id, teacher_id, classroom_id, rfid_uid, time_in, time_in_device_id, time_in_ip, time_in_mac, time_out, time_out_device_id, time_out_ip, time_out_mac, auto_generated_time_out, duration_minutes, arrival_status, departure_status, final_status, request_id, synced_offline, created_at, updated_at)
    SELECT attendance_id, session_id, student_id, section_id, grade_level_id, subject_id, teacher_id, classroom_id, rfid_uid, time_in, time_in_device_id, time_in_ip, time_in_mac, time_out, time_out_device_id, time_out_ip, time_out_mac, auto_generated_time_out, duration_minutes, arrival_status, departure_status, final_status, request_id, synced_offline, created_at, updated_at FROM attendance_records;
DROP TABLE attendance_records;
ALTER TABLE attendance_records__new RENAME TO attendance_records;
CREATE INDEX fk_att_classroom ON attendance_records (classroom_id);
CREATE INDEX idx_att_carried_from ON attendance_records (carried_from_session_id);
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

ALTER TABLE attendance_sessions ADD COLUMN carried_in_count INTEGER NOT NULL DEFAULT 0;  -- Records that arrived by carry-over from the previous period rather than by tap

-- ---------------------------------------------------------------------------
-- v_attendance_detail
-- ---------------------------------------------------------------------------
-- Every report, export and attendance search reads this view. If the carry
-- does not reach it, a carried record is indistinguishable from a scanned one
-- everywhere anybody actually looks — which is precisely the confusion the
-- column exists to prevent. Re-declared in full below because CREATE OR
-- REPLACE VIEW replaces the whole definition; the only additions are the two
-- carry columns and the LEFT JOIN that names the period they came from.
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
LEFT JOIN subjects prevsub         ON prevsub.subject_id = prev.subject_id;

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
-- Carrying is on by default because it is what the school asked for, but it is
-- a policy, not a law, and a school that wants every period scanned separately
-- must be able to say so without editing code.
--
-- The gap limit is what keeps "the next period" meaning the next period. Two
-- classes an hour apart are not a handover — the students went somewhere in
-- between — so beyond the limit the new register starts empty and everyone
-- taps.
-- ---------------------------------------------------------------------------

INSERT INTO settings
    (setting_key, setting_value, value_type, group_name, label, description,
     is_sensitive, min_value, max_value)
VALUES
    ('attendance.carry_over_enabled', '1', 'bool', 'attendance',
     'Carry attendance to the next subject',
     'A student who was Present or Late in the previous period starts the next one Present without tapping again. Absent, Left Early, Excused and Incomplete never carry — those students may still tap in.',
     0, NULL, NULL),
    ('attendance.carry_over_max_gap_minutes', '30', 'int', 'attendance',
     'Carry-over gap limit (minutes)',
     'The longest break between one period ending and the next beginning that still counts as a handover. Beyond this, the new register starts empty.',
     0, '0', '240')
ON CONFLICT DO NOTHING;

