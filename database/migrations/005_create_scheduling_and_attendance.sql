-- ===========================================================================
-- L-SIAMS · 005 · Schedules, attendance sessions and attendance records
-- ===========================================================================
-- This migration carries the correctness guarantees of the whole system.
-- Application logic alone is never sufficient (Part 17.2): duplicates, double
-- sessions and replayed requests are made structurally impossible here, by
-- unique keys, so that a race between two devices cannot produce a second row
-- no matter what the PHP layer does.
-- ===========================================================================


-- ------------------------------------------------------------ schedules ----
CREATE TABLE IF NOT EXISTS schedules (
    schedule_id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    teacher_id                   INTEGER NOT NULL,
    subject_id                   INTEGER NOT NULL,
    section_id                   INTEGER NOT NULL,
    classroom_id                 INTEGER NOT NULL,
    school_year_id               INTEGER NOT NULL,
    day_of_week                  TEXT NOT NULL COLLATE NOCASE CHECK (day_of_week IN ('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')),
    start_time                   TEXT NOT NULL CHECK (start_time IS NULL OR time(start_time) IS NOT NULL),
    end_time                     TEXT NOT NULL CHECK (end_time IS NULL OR time(end_time) IS NOT NULL),
    -- Part 16.3 — four windows, not two. Minutes relative to start/end.
    time_in_window_open          INTEGER NOT NULL DEFAULT 10,
    late_threshold_minutes       INTEGER NOT NULL DEFAULT 15,
    time_in_window_close         INTEGER NOT NULL DEFAULT 30,
    time_out_window_open         INTEGER NOT NULL DEFAULT 10,
    time_out_window_close        INTEGER NOT NULL DEFAULT 15,
    minimum_dwell_minutes        INTEGER NOT NULL DEFAULT 20,
    status                       TEXT NOT NULL DEFAULT 'active' COLLATE NOCASE CHECK (status IN ('active', 'inactive', 'archived')),
    created_by                   INTEGER,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    deleted_at                   TEXT,
    CONSTRAINT fk_sched_teacher FOREIGN KEY (teacher_id) REFERENCES teachers (teacher_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_sched_subject FOREIGN KEY (subject_id) REFERENCES subjects (subject_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_sched_section FOREIGN KEY (section_id) REFERENCES sections (section_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_sched_classroom FOREIGN KEY (classroom_id) REFERENCES classrooms (classroom_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_sched_year FOREIGN KEY (school_year_id) REFERENCES school_years (school_year_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_sched_creator FOREIGN KEY (created_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE,
    -- Window sanity is asserted by the database as well as the form, because a
    -- schedule with overlapping in/out windows makes tap intent undecidable.
    CONSTRAINT chk_sched_times CHECK (time(end_time) > time(start_time)),
    CONSTRAINT chk_sched_late CHECK (late_threshold_minutes < time_in_window_close),
    -- The lesson's length in minutes, as TIMESTAMPDIFF(MINUTE, ...) gave it.
    CONSTRAINT chk_sched_windows CHECK (
        (CAST(strftime('%s', end_time) AS INTEGER) - CAST(strftime('%s', start_time) AS INTEGER)) / 60
            - time_out_window_open > time_in_window_close
    )
);
CREATE INDEX idx_sched_teacher_day ON schedules (teacher_id, day_of_week, start_time);
CREATE INDEX idx_sched_classroom_day ON schedules (classroom_id, day_of_week, start_time);
CREATE INDEX idx_sched_section_day ON schedules (section_id, day_of_week, start_time);
CREATE INDEX idx_sched_subject ON schedules (subject_id);
CREATE INDEX idx_sched_status ON schedules (status, deleted_at);
CREATE INDEX fk_sched_year ON schedules (school_year_id);
CREATE INDEX fk_sched_creator ON schedules (created_by);

CREATE TRIGGER trg_schedules_updated_at
AFTER UPDATE ON schedules
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.schedule_id IS NOT OLD.schedule_id
    OR NEW.teacher_id IS NOT OLD.teacher_id
    OR NEW.subject_id IS NOT OLD.subject_id
    OR NEW.section_id IS NOT OLD.section_id
    OR NEW.classroom_id IS NOT OLD.classroom_id
    OR NEW.school_year_id IS NOT OLD.school_year_id
    OR NEW.day_of_week IS NOT OLD.day_of_week
    OR NEW.start_time IS NOT OLD.start_time
    OR NEW.end_time IS NOT OLD.end_time
    OR NEW.time_in_window_open IS NOT OLD.time_in_window_open
    OR NEW.late_threshold_minutes IS NOT OLD.late_threshold_minutes
    OR NEW.time_in_window_close IS NOT OLD.time_in_window_close
    OR NEW.time_out_window_open IS NOT OLD.time_out_window_open
    OR NEW.time_out_window_close IS NOT OLD.time_out_window_close
    OR NEW.minimum_dwell_minutes IS NOT OLD.minimum_dwell_minutes
    OR NEW.status IS NOT OLD.status
    OR NEW.created_by IS NOT OLD.created_by
    OR NEW.created_at IS NOT OLD.created_at
    OR NEW.deleted_at IS NOT OLD.deleted_at
)
BEGIN
    UPDATE schedules SET updated_at = now() WHERE schedule_id = NEW.schedule_id;
END;

-- Times of day are stored as text and compared as text, so they must all be
-- written HH:MM:SS. MariaDB's TIME column normalised 08:00 to 08:00:00 on its
-- own; these two triggers do the same for a form that leaves the seconds off.
CREATE TRIGGER trg_schedules_normalise_times_insert
AFTER INSERT ON schedules
WHEN NEW.start_time IS NOT time(NEW.start_time) OR NEW.end_time IS NOT time(NEW.end_time)
BEGIN
    UPDATE schedules SET start_time = time(start_time), end_time = time(end_time)
     WHERE schedule_id = NEW.schedule_id;
END;

CREATE TRIGGER trg_schedules_normalise_times_update
AFTER UPDATE OF start_time, end_time ON schedules
WHEN NEW.start_time IS NOT time(NEW.start_time) OR NEW.end_time IS NOT time(NEW.end_time)
BEGIN
    UPDATE schedules SET start_time = time(start_time), end_time = time(end_time)
     WHERE schedule_id = NEW.schedule_id;
END;

-- -------------------------------------------------- attendance sessions ----
CREATE TABLE IF NOT EXISTS attendance_sessions (
    session_id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    session_code                 TEXT NOT NULL COLLATE NOCASE,  -- Public handle: ATT-2026-000203
    schedule_id                  INTEGER NOT NULL,
    teacher_id                   INTEGER NOT NULL,
    device_row_id                INTEGER NOT NULL,
    classroom_id                 INTEGER NOT NULL,
    section_id                   INTEGER NOT NULL,
    subject_id                   INTEGER NOT NULL,
    session_date                 TEXT NOT NULL,
    scheduled_start              TEXT NOT NULL,
    scheduled_end                TEXT NOT NULL,
    opened_at                    TEXT NOT NULL,
    closed_at                    TEXT,
    expires_at                   TEXT NOT NULL,  -- scheduled_end + time_out_window_close
    status                       TEXT NOT NULL DEFAULT 'open' COLLATE NOCASE CHECK (status IN ('open', 'closed', 'aborted')),
    closed_by_type               TEXT COLLATE NOCASE CHECK (closed_by_type IN ('teacher', 'system', 'administrator')),
    closed_by                    INTEGER,
    -- Provenance of the fingerprint that authorised this session.
    fingerprint_log_id           INTEGER,
    api_key_id                   INTEGER,
    open_ip                      TEXT COLLATE NOCASE,
    open_mac                     TEXT COLLATE NOCASE,
    -- Rollups computed once at close, inside the same transaction.
    roster_count                 INTEGER NOT NULL DEFAULT 0,
    present_count                INTEGER NOT NULL DEFAULT 0,
    late_count                   INTEGER NOT NULL DEFAULT 0,
    absent_count                 INTEGER NOT NULL DEFAULT 0,
    incomplete_count             INTEGER NOT NULL DEFAULT 0,
    left_early_count             INTEGER NOT NULL DEFAULT 0,
    timed_out_count              INTEGER NOT NULL DEFAULT 0,
    rejected_tap_count           INTEGER NOT NULL DEFAULT 0,
    average_dwell_minutes        INTEGER,
    attendance_percentage        NUMERIC,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    -- 1 while the session is open, NULL otherwise: see the unique keys below.
    active_flag                  INTEGER GENERATED ALWAYS AS (CASE WHEN status = 'open' THEN 1 ELSE NULL END) STORED,
    CONSTRAINT fk_sess_schedule FOREIGN KEY (schedule_id) REFERENCES schedules (schedule_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_sess_teacher FOREIGN KEY (teacher_id) REFERENCES teachers (teacher_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_sess_device FOREIGN KEY (device_row_id) REFERENCES devices (id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_sess_classroom FOREIGN KEY (classroom_id) REFERENCES classrooms (classroom_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_sess_section FOREIGN KEY (section_id) REFERENCES sections (section_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_sess_subject FOREIGN KEY (subject_id) REFERENCES subjects (subject_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_sess_closer FOREIGN KEY (closed_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_sess_apikey FOREIGN KEY (api_key_id) REFERENCES api_keys (api_key_id) ON DELETE SET NULL ON UPDATE CASCADE,
    -- fingerprint_logs is created further down; SQLite resolves a foreign key
    -- when it is used, so it is declared here rather than added afterwards.
    CONSTRAINT fk_sess_fingerprint FOREIGN KEY (fingerprint_log_id) REFERENCES fingerprint_logs (log_id) ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE UNIQUE INDEX uq_session_code ON attendance_sessions (session_code);
CREATE INDEX idx_session_schedule_date ON attendance_sessions (schedule_id, session_date);
CREATE INDEX idx_session_teacher ON attendance_sessions (teacher_id, session_date);
CREATE INDEX idx_session_section ON attendance_sessions (section_id, session_date);
CREATE INDEX idx_session_device ON attendance_sessions (device_row_id, status);
CREATE INDEX idx_session_status ON attendance_sessions (status, expires_at);
CREATE INDEX fk_sess_subject ON attendance_sessions (subject_id);
CREATE INDEX fk_sess_closer ON attendance_sessions (closed_by);
CREATE INDEX fk_sess_apikey ON attendance_sessions (api_key_id);
CREATE INDEX fk_sess_fingerprint ON attendance_sessions (fingerprint_log_id);

CREATE TRIGGER trg_attendance_sessions_updated_at
AFTER UPDATE ON attendance_sessions
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.session_id IS NOT OLD.session_id
    OR NEW.session_code IS NOT OLD.session_code
    OR NEW.schedule_id IS NOT OLD.schedule_id
    OR NEW.teacher_id IS NOT OLD.teacher_id
    OR NEW.device_row_id IS NOT OLD.device_row_id
    OR NEW.classroom_id IS NOT OLD.classroom_id
    OR NEW.section_id IS NOT OLD.section_id
    OR NEW.subject_id IS NOT OLD.subject_id
    OR NEW.session_date IS NOT OLD.session_date
    OR NEW.scheduled_start IS NOT OLD.scheduled_start
    OR NEW.scheduled_end IS NOT OLD.scheduled_end
    OR NEW.opened_at IS NOT OLD.opened_at
    OR NEW.closed_at IS NOT OLD.closed_at
    OR NEW.expires_at IS NOT OLD.expires_at
    OR NEW.status IS NOT OLD.status
    OR NEW.closed_by_type IS NOT OLD.closed_by_type
    OR NEW.closed_by IS NOT OLD.closed_by
    OR NEW.fingerprint_log_id IS NOT OLD.fingerprint_log_id
    OR NEW.api_key_id IS NOT OLD.api_key_id
    OR NEW.open_ip IS NOT OLD.open_ip
    OR NEW.open_mac IS NOT OLD.open_mac
    OR NEW.roster_count IS NOT OLD.roster_count
    OR NEW.present_count IS NOT OLD.present_count
    OR NEW.late_count IS NOT OLD.late_count
    OR NEW.absent_count IS NOT OLD.absent_count
    OR NEW.incomplete_count IS NOT OLD.incomplete_count
    OR NEW.left_early_count IS NOT OLD.left_early_count
    OR NEW.timed_out_count IS NOT OLD.timed_out_count
    OR NEW.rejected_tap_count IS NOT OLD.rejected_tap_count
    OR NEW.average_dwell_minutes IS NOT OLD.average_dwell_minutes
    OR NEW.attendance_percentage IS NOT OLD.attendance_percentage
    OR NEW.created_at IS NOT OLD.created_at
)
BEGIN
    UPDATE attendance_sessions SET updated_at = now() WHERE session_id = NEW.session_id;
END;

-- Part 17.2: "one open session per classroom" and "per device", enforced by the
-- database rather than by an application check that could lose a race.
-- active_flag is 1 only while status='open' and NULL otherwise; NULL values do
-- not collide in a unique index, so any number of closed sessions may coexist.
-- The column is declared on attendance_sessions above: SQLite cannot add a
-- stored generated column afterwards.
CREATE UNIQUE INDEX IF NOT EXISTS uq_one_open_session_per_classroom ON attendance_sessions (classroom_id, active_flag);
CREATE UNIQUE INDEX IF NOT EXISTS uq_one_open_session_per_device ON attendance_sessions (device_row_id, active_flag);
CREATE UNIQUE INDEX IF NOT EXISTS uq_session_schedule_day ON attendance_sessions (schedule_id, session_date);

-- --------------------------------------------------- attendance records ----
CREATE TABLE IF NOT EXISTS attendance_records (
    attendance_id                INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id                   INTEGER NOT NULL,
    student_id                   INTEGER NOT NULL,
    -- Deliberate, controlled denormalisation (Part 15.4). These are copied at
    -- write time and never rewritten: a student who transfers section in January
    -- must not have their October attendance retroactively reattributed. Reports
    -- must reflect where the student actually was.
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
    -- Three separate fields, never collapsed into one column (Part 16.6).
    arrival_status               TEXT NOT NULL COLLATE NOCASE CHECK (arrival_status IN ('present', 'late', 'absent', 'excused', 'official_business')),
    departure_status             TEXT NOT NULL DEFAULT 'pending' COLLATE NOCASE CHECK (departure_status IN ('pending', 'timed_out', 'left_early', 'no_time_out', 'auto_closed')),
    final_status                 TEXT NOT NULL COLLATE NOCASE CHECK (final_status IN ('Present', 'Late', 'Absent', 'Excused', 'Official Business', 'Incomplete', 'Left Early')),
    request_id                   TEXT COLLATE NOCASE,  -- Idempotency handle from the device
    synced_offline               INTEGER NOT NULL DEFAULT 0,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_att_session FOREIGN KEY (session_id) REFERENCES attendance_sessions (session_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_att_student FOREIGN KEY (student_id) REFERENCES students (student_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_att_section FOREIGN KEY (section_id) REFERENCES sections (section_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_att_grade FOREIGN KEY (grade_level_id) REFERENCES grade_levels (grade_level_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_att_subject FOREIGN KEY (subject_id) REFERENCES subjects (subject_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_att_teacher FOREIGN KEY (teacher_id) REFERENCES teachers (teacher_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_att_classroom FOREIGN KEY (classroom_id) REFERENCES classrooms (classroom_id) ON DELETE RESTRICT ON UPDATE CASCADE
);
-- The single most important constraint in the schema: duplicates are
-- structurally impossible, so 50 concurrent taps of one card can only ever
-- yield one row. The application translates error 1062 on this key into
-- DUPLICATE_TIME_IN rather than a 500.
CREATE UNIQUE INDEX uq_attendance_session_student ON attendance_records (session_id, student_id);
CREATE UNIQUE INDEX uq_attendance_request_id ON attendance_records (request_id);
CREATE INDEX idx_att_student_date ON attendance_records (student_id, time_in);
CREATE INDEX idx_att_section_date ON attendance_records (section_id, time_in);
CREATE INDEX idx_att_session ON attendance_records (session_id);
CREATE INDEX idx_att_final_status ON attendance_records (final_status, time_in);
CREATE INDEX idx_att_teacher_date ON attendance_records (teacher_id, time_in);
CREATE INDEX idx_att_subject_date ON attendance_records (subject_id, time_in);
CREATE INDEX idx_att_grade_date ON attendance_records (grade_level_id, time_in);
CREATE INDEX fk_att_classroom ON attendance_records (classroom_id);

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
    OR NEW.synced_offline IS NOT OLD.synced_offline
    OR NEW.created_at IS NOT OLD.created_at
)
BEGIN
    UPDATE attendance_records SET updated_at = now() WHERE attendance_id = NEW.attendance_id;
END;

-- ---------------------------------------------- attendance corrections ----
-- Part 3: teachers cannot modify attendance. Only administrators, always with
-- a reason, and the original value is preserved here permanently.
CREATE TABLE IF NOT EXISTS attendance_modifications (
    modification_id              INTEGER PRIMARY KEY AUTOINCREMENT,
    attendance_id                INTEGER NOT NULL,
    administrator_id             INTEGER NOT NULL,
    field_changed                TEXT NOT NULL COLLATE NOCASE CHECK (field_changed IN ('arrival_status', 'departure_status', 'final_status', 'time_in', 'time_out')),
    old_value                    TEXT COLLATE NOCASE,
    new_value                    TEXT COLLATE NOCASE,
    reason                       TEXT NOT NULL COLLATE NOCASE,
    ip_address                   TEXT COLLATE NOCASE,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_mod_attendance FOREIGN KEY (attendance_id) REFERENCES attendance_records (attendance_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_mod_admin FOREIGN KEY (administrator_id) REFERENCES users (user_id) ON DELETE RESTRICT ON UPDATE CASCADE
);
CREATE INDEX idx_mod_attendance ON attendance_modifications (attendance_id, created_at);
CREATE INDEX idx_mod_admin ON attendance_modifications (administrator_id, created_at);

-- Reference table for the status vocabulary, so reports and dropdowns share
-- one source of truth with the ENUMs above.
CREATE TABLE IF NOT EXISTS attendance_status (
    status_key                   TEXT PRIMARY KEY NOT NULL COLLATE NOCASE,
    label                        TEXT NOT NULL COLLATE NOCASE,
    category                     TEXT NOT NULL COLLATE NOCASE CHECK (category IN ('arrival', 'departure', 'final')),
    badge_class                  TEXT NOT NULL DEFAULT 'badge-neutral' COLLATE NOCASE,
    counts_as_present            INTEGER NOT NULL DEFAULT 0,
    sort_order                   INTEGER NOT NULL DEFAULT 0
);

-- ------------------------------------------------------------ RFID logs ----
-- Every scan, accepted or not. This is where SECTION_MISMATCH, unknown cards
-- and duplicate taps are recorded — attendance_records only ever holds
-- successful attendance.
CREATE TABLE IF NOT EXISTS rfid_logs (
    log_id                       INTEGER PRIMARY KEY AUTOINCREMENT,
    card_uid                     TEXT NOT NULL COLLATE NOCASE,
    student_id                   INTEGER,
    device_row_id                INTEGER,
    session_id                   INTEGER,
    intent                       TEXT NOT NULL DEFAULT 'unknown' COLLATE NOCASE CHECK (intent IN ('time_in', 'time_out', 'unknown')),
    result                       TEXT NOT NULL COLLATE NOCASE CHECK (result IN ('accepted', 'duplicate_time_in', 'duplicate_time_out', 'already_complete', 'unknown_card', 'card_disabled', 'student_inactive', 'section_mismatch', 'not_enrolled_in_subject', 'session_not_open', 'session_closed', 'time_in_not_yet_open', 'time_in_closed', 'time_out_closed', 'minimum_dwell_not_met', 'device_classroom_mismatch', 'rejected')),
    -- Both sides of a mismatch are stored so an administrator can see the real
    -- cause at a glance from the live feed.
    student_section_id           INTEGER,
    session_section_id           INTEGER,
    message                      TEXT COLLATE NOCASE,
    ip_address                   TEXT COLLATE NOCASE,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_rfidlog_student FOREIGN KEY (student_id) REFERENCES students (student_id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_rfidlog_device FOREIGN KEY (device_row_id) REFERENCES devices (id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_rfidlog_session FOREIGN KEY (session_id) REFERENCES attendance_sessions (session_id) ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE INDEX idx_rfidlog_uid ON rfid_logs (card_uid, created_at);
CREATE INDEX idx_rfidlog_student ON rfid_logs (student_id, created_at);
CREATE INDEX idx_rfidlog_session ON rfid_logs (session_id, created_at);
CREATE INDEX idx_rfidlog_result ON rfid_logs (result, created_at);
CREATE INDEX idx_rfidlog_device ON rfid_logs (device_row_id, created_at);

-- Unknown cards are held separately so an administrator can triage them
-- (assign / ignore / blacklist) without wading through the full scan log.
CREATE TABLE IF NOT EXISTS unknown_rfid_logs (
    unknown_id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    card_uid                     TEXT NOT NULL COLLATE NOCASE,
    device_row_id                INTEGER,
    session_id                   INTEGER,
    seen_count                   INTEGER NOT NULL DEFAULT 1,
    first_seen_at                TEXT NOT NULL,
    last_seen_at                 TEXT NOT NULL,
    resolution                   TEXT NOT NULL DEFAULT 'pending' COLLATE NOCASE CHECK (resolution IN ('pending', 'assigned', 'ignored', 'blacklisted')),
    resolved_by                  INTEGER,
    resolved_at                  TEXT,
    notes                        TEXT COLLATE NOCASE,
    CONSTRAINT fk_unknown_device FOREIGN KEY (device_row_id) REFERENCES devices (id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_unknown_user FOREIGN KEY (resolved_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE UNIQUE INDEX uq_unknown_uid ON unknown_rfid_logs (card_uid);
CREATE INDEX idx_unknown_resolution ON unknown_rfid_logs (resolution, last_seen_at);
CREATE INDEX fk_unknown_device ON unknown_rfid_logs (device_row_id);
CREATE INDEX fk_unknown_user ON unknown_rfid_logs (resolved_by);

-- --------------------------------------------------------- fingerprints ----
CREATE TABLE IF NOT EXISTS fingerprint_templates (
    fingerprint_id               INTEGER PRIMARY KEY AUTOINCREMENT,
    teacher_id                   INTEGER NOT NULL,
    -- The sensor stores the template in its own flash and the server keeps the
    -- slot number. This was once the whole story; migration 018 adds the
    -- encrypted template alongside it, so one enrolment can reach every terminal
    -- a teacher teaches at. Read 018 for what that costs.
    sensor_template_id           INTEGER NOT NULL,
    enrolled_device_row_id       INTEGER,
    quality_score                INTEGER,
    sample_count                 INTEGER NOT NULL DEFAULT 0,
    enrollment_date              TEXT NOT NULL,
    enrolled_by                  INTEGER,
    last_verified_at             TEXT,
    verification_count           INTEGER NOT NULL DEFAULT 0,
    failure_count                INTEGER NOT NULL DEFAULT 0,
    status                       TEXT NOT NULL DEFAULT 'active' COLLATE NOCASE CHECK (status IN ('active', 'disabled', 'pending')),
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_fp_teacher FOREIGN KEY (teacher_id) REFERENCES teachers (teacher_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_fp_device FOREIGN KEY (enrolled_device_row_id) REFERENCES devices (id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_fp_enroller FOREIGN KEY (enrolled_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
);
-- One fingerprint per teacher (Part 5), and one sensor slot per device.
CREATE UNIQUE INDEX uq_fingerprint_teacher ON fingerprint_templates (teacher_id);
CREATE UNIQUE INDEX uq_fingerprint_slot ON fingerprint_templates (enrolled_device_row_id, sensor_template_id);
CREATE INDEX idx_fingerprint_status ON fingerprint_templates (status);
CREATE INDEX fk_fp_enroller ON fingerprint_templates (enrolled_by);

CREATE TRIGGER trg_fingerprint_templates_updated_at
AFTER UPDATE ON fingerprint_templates
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.fingerprint_id IS NOT OLD.fingerprint_id
    OR NEW.teacher_id IS NOT OLD.teacher_id
    OR NEW.sensor_template_id IS NOT OLD.sensor_template_id
    OR NEW.enrolled_device_row_id IS NOT OLD.enrolled_device_row_id
    OR NEW.quality_score IS NOT OLD.quality_score
    OR NEW.sample_count IS NOT OLD.sample_count
    OR NEW.enrollment_date IS NOT OLD.enrollment_date
    OR NEW.enrolled_by IS NOT OLD.enrolled_by
    OR NEW.last_verified_at IS NOT OLD.last_verified_at
    OR NEW.verification_count IS NOT OLD.verification_count
    OR NEW.failure_count IS NOT OLD.failure_count
    OR NEW.status IS NOT OLD.status
    OR NEW.created_at IS NOT OLD.created_at
)
BEGIN
    UPDATE fingerprint_templates SET updated_at = now() WHERE fingerprint_id = NEW.fingerprint_id;
END;

CREATE TABLE IF NOT EXISTS fingerprint_logs (
    log_id                       INTEGER PRIMARY KEY AUTOINCREMENT,
    teacher_id                   INTEGER,  -- NULL when the presented template matched nobody
    device_row_id                INTEGER,
    sensor_template_id           INTEGER,
    result                       TEXT NOT NULL COLLATE NOCASE CHECK (result IN ('verified', 'failed', 'unknown', 'not_assigned', 'no_schedule', 'locked', 'session_exists', 'teacher_inactive', 'enrolled', 'deleted')),
    confidence                   INTEGER,
    message                      TEXT COLLATE NOCASE,
    ip_address                   TEXT COLLATE NOCASE,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_fplog_teacher FOREIGN KEY (teacher_id) REFERENCES teachers (teacher_id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_fplog_device FOREIGN KEY (device_row_id) REFERENCES devices (id) ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE INDEX idx_fplog_teacher ON fingerprint_logs (teacher_id, created_at);
CREATE INDEX idx_fplog_device ON fingerprint_logs (device_row_id, created_at);
CREATE INDEX idx_fplog_result ON fingerprint_logs (result, created_at);

-- (fk_sess_fingerprint is declared on attendance_sessions above.)

