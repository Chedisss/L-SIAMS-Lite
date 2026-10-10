-- ===========================================================================
-- L-SIAMS · 017 · Open a session when the finger cannot be read
-- ===========================================================================
-- A fingerprint is a good primary control and a bad only control. Sweat, a
-- cut, a burn, a plaster, a sensor that has failed overnight — any one of them
-- leaves a teacher standing in front of a full class with no way to open the
-- register, and a class whose attendance is never recorded at all.
--
-- The failover is the teacher's own account password, typed at their own
-- dashboard. It proves the same thing the finger proves — that this teacher is
-- here — through a credential the school already issued and already trusts for
-- everything else that account can do.
--
-- What it does NOT relax is anything else. The class must be scheduled now, in
-- this room, with this teacher assigned to it, and the room's terminal must be
-- registered — exactly the checks the fingerprint path makes. Only the proof
-- of identity changes.
--
-- Two columns, so that change is never invisible:
--
--   opened_method      how the teacher proved they were there. Existing rows
--                      are all fingerprint openings, which is why the default
--                      is 'fingerprint' — backfilling them as anything else
--                      would rewrite history that did happen at a reader.
--   opened_by_user_id  the account that authorised the override, NULL for a
--                      fingerprint opening. teacher_id already says whose
--                      class it is; this says who typed the password, and
--                      RESTRICT keeps that account from being deleted out
--                      from under the record.
--
-- Anyone auditing attendance can now ask "which sessions were opened without a
-- scan" in one query instead of inferring it from a NULL fingerprint_log_id,
-- which was also NULL for other reasons.
-- ===========================================================================


-- SQLite cannot add a named foreign key to an existing table, so the two new
-- columns, their index and fk_session_opened_by arrive in one rebuild.
-- The table is rebuilt: a new one in the final shape, the rows copied across,
-- the old one dropped and the new one renamed into its place. Indexes and
-- triggers go with the old table, so they are recreated after.
CREATE TABLE attendance_sessions__new (
    session_id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    session_code                 TEXT NOT NULL COLLATE NOCASE,
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
    expires_at                   TEXT NOT NULL,
    status                       TEXT NOT NULL DEFAULT 'open' COLLATE NOCASE CHECK (status IN ('open', 'closed', 'aborted')),
    closed_by_type               TEXT COLLATE NOCASE CHECK (closed_by_type IN ('teacher', 'system', 'administrator')),
    closed_by                    INTEGER,
    fingerprint_log_id           INTEGER,
    opened_method                TEXT NOT NULL DEFAULT 'fingerprint' COLLATE NOCASE CHECK (opened_method IN ('fingerprint', 'password')),
    opened_by_user_id            INTEGER,
    api_key_id                   INTEGER,
    open_ip                      TEXT COLLATE NOCASE,
    open_mac                     TEXT COLLATE NOCASE,
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
    active_flag                  INTEGER GENERATED ALWAYS AS (CASE WHEN status = 'open' THEN 1 ELSE NULL END) STORED,
    CONSTRAINT fk_session_opened_by FOREIGN KEY (opened_by_user_id) REFERENCES users (user_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_sess_apikey FOREIGN KEY (api_key_id) REFERENCES api_keys (api_key_id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_sess_classroom FOREIGN KEY (classroom_id) REFERENCES classrooms (classroom_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_sess_closer FOREIGN KEY (closed_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_sess_device FOREIGN KEY (device_row_id) REFERENCES devices (id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_sess_fingerprint FOREIGN KEY (fingerprint_log_id) REFERENCES fingerprint_logs (log_id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_sess_schedule FOREIGN KEY (schedule_id) REFERENCES schedules (schedule_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_sess_section FOREIGN KEY (section_id) REFERENCES sections (section_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_sess_subject FOREIGN KEY (subject_id) REFERENCES subjects (subject_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_sess_teacher FOREIGN KEY (teacher_id) REFERENCES teachers (teacher_id) ON DELETE RESTRICT ON UPDATE CASCADE
);
INSERT INTO attendance_sessions__new (session_id, session_code, schedule_id, teacher_id, device_row_id, classroom_id, section_id, subject_id, session_date, scheduled_start, scheduled_end, opened_at, closed_at, expires_at, status, closed_by_type, closed_by, fingerprint_log_id, api_key_id, open_ip, open_mac, roster_count, present_count, late_count, absent_count, incomplete_count, left_early_count, timed_out_count, rejected_tap_count, average_dwell_minutes, attendance_percentage, created_at, updated_at)
    SELECT session_id, session_code, schedule_id, teacher_id, device_row_id, classroom_id, section_id, subject_id, session_date, scheduled_start, scheduled_end, opened_at, closed_at, expires_at, status, closed_by_type, closed_by, fingerprint_log_id, api_key_id, open_ip, open_mac, roster_count, present_count, late_count, absent_count, incomplete_count, left_early_count, timed_out_count, rejected_tap_count, average_dwell_minutes, attendance_percentage, created_at, updated_at FROM attendance_sessions;
DROP TABLE attendance_sessions;
ALTER TABLE attendance_sessions__new RENAME TO attendance_sessions;
CREATE INDEX fk_session_opened_by ON attendance_sessions (opened_by_user_id);
CREATE INDEX fk_sess_apikey ON attendance_sessions (api_key_id);
CREATE INDEX fk_sess_closer ON attendance_sessions (closed_by);
CREATE INDEX fk_sess_fingerprint ON attendance_sessions (fingerprint_log_id);
CREATE INDEX fk_sess_subject ON attendance_sessions (subject_id);
CREATE INDEX idx_session_device ON attendance_sessions (device_row_id, status);
CREATE INDEX idx_session_opened_method ON attendance_sessions (opened_method, session_date);
CREATE INDEX idx_session_schedule_date ON attendance_sessions (schedule_id, session_date);
CREATE INDEX idx_session_section ON attendance_sessions (section_id, session_date);
CREATE INDEX idx_session_status ON attendance_sessions (status, expires_at);
CREATE INDEX idx_session_teacher ON attendance_sessions (teacher_id, session_date);
CREATE UNIQUE INDEX uq_one_open_session_per_classroom ON attendance_sessions (classroom_id, active_flag);
CREATE UNIQUE INDEX uq_one_open_session_per_device ON attendance_sessions (device_row_id, active_flag);
CREATE UNIQUE INDEX uq_session_code ON attendance_sessions (session_code);
CREATE UNIQUE INDEX uq_session_schedule_day ON attendance_sessions (schedule_id, session_date);

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
    OR NEW.opened_method IS NOT OLD.opened_method
    OR NEW.opened_by_user_id IS NOT OLD.opened_by_user_id
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
-- Views that read attendance_sessions are untouched: the runner renames with legacy_alter_table,
-- which leaves them pointing at the name, not the dropped table.

