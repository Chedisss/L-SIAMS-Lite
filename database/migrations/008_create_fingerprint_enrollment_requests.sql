-- ===========================================================================
-- L-SIAMS · 008 · Fingerprint enrolment requests
-- ===========================================================================
-- The enrolment capture happens on the R307 attached to a terminal, but the
-- decision to enrol is taken in the browser. This table is the hand-off: an
-- administrator opens a request against a terminal, the terminal picks it up on
-- its next poll, runs the sensor's capture cycle, and reports back.
--
-- Still no biometric template reaches this database. The request carries the
-- slot number the template must be written to and nothing else; the template
-- itself lives and dies in the sensor's own flash.
--
-- Rows are kept after they finish. A failed enrolment is a support question
-- ("it would not read her thumb") and the stage it failed at is the answer.
-- ===========================================================================


CREATE TABLE IF NOT EXISTS fingerprint_enrollment_requests (
    request_id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    teacher_id                   INTEGER NOT NULL,
    device_row_id                INTEGER NOT NULL,
    sensor_template_id           INTEGER NOT NULL,  -- Slot the sensor must write to; allocated here, not by the device
    status                       TEXT NOT NULL DEFAULT 'pending' COLLATE NOCASE CHECK (status IN ('pending', 'scanning', 'completed', 'failed', 'cancelled', 'expired')),
    -- Free-form because the sensor's capture cycle is the sensor's business; the
    -- firmware names each step and the browser renders whatever it is told.
    stage                        TEXT NOT NULL DEFAULT 'waiting_for_device' COLLATE NOCASE,
    message                      TEXT COLLATE NOCASE,  -- Human-readable status shown in the enrolment wizard
    quality_score                INTEGER,
    sample_count                 INTEGER NOT NULL DEFAULT 0,
    requested_by                 INTEGER,
    claimed_at                   TEXT,  -- When the terminal picked the request up
    completed_at                 TEXT,
    -- A request nobody acts on must not sit open forever holding a slot: an
    -- administrator who walks away from the screen would otherwise block that
    -- terminal from enrolling anyone else.
    expires_at                   TEXT NOT NULL,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_fer_teacher FOREIGN KEY (teacher_id) REFERENCES teachers (teacher_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_fer_device FOREIGN KEY (device_row_id) REFERENCES devices (id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_fer_user FOREIGN KEY (requested_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE INDEX idx_fer_device_status ON fingerprint_enrollment_requests (device_row_id, status);
CREATE INDEX idx_fer_teacher ON fingerprint_enrollment_requests (teacher_id, created_at);
CREATE INDEX idx_fer_open ON fingerprint_enrollment_requests (status, expires_at);
CREATE INDEX fk_fer_user ON fingerprint_enrollment_requests (requested_by);

CREATE TRIGGER trg_fingerprint_enrollment_requests_updated_at
AFTER UPDATE ON fingerprint_enrollment_requests
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.request_id IS NOT OLD.request_id
    OR NEW.teacher_id IS NOT OLD.teacher_id
    OR NEW.device_row_id IS NOT OLD.device_row_id
    OR NEW.sensor_template_id IS NOT OLD.sensor_template_id
    OR NEW.status IS NOT OLD.status
    OR NEW.stage IS NOT OLD.stage
    OR NEW.message IS NOT OLD.message
    OR NEW.quality_score IS NOT OLD.quality_score
    OR NEW.sample_count IS NOT OLD.sample_count
    OR NEW.requested_by IS NOT OLD.requested_by
    OR NEW.claimed_at IS NOT OLD.claimed_at
    OR NEW.completed_at IS NOT OLD.completed_at
    OR NEW.expires_at IS NOT OLD.expires_at
    OR NEW.created_at IS NOT OLD.created_at
)
BEGIN
    UPDATE fingerprint_enrollment_requests SET updated_at = now() WHERE request_id = NEW.request_id;
END;

-- 'cancelled' completes the set of outcomes the wizard can produce. The enum
-- already carried 'enrolled' and 'deleted' for the administrative actions.
-- SQLite has no MODIFY COLUMN, and an enum is a CHECK constraint on the
-- column, so widening the list means rebuilding the table.
-- The table is rebuilt: a new one in the final shape, the rows copied across,
-- the old one dropped and the new one renamed into its place. Indexes and
-- triggers go with the old table, so they are recreated after.
CREATE TABLE fingerprint_logs__new (
    log_id                       INTEGER PRIMARY KEY AUTOINCREMENT,
    teacher_id                   INTEGER,
    device_row_id                INTEGER,
    sensor_template_id           INTEGER,
    result                       TEXT NOT NULL COLLATE NOCASE CHECK (result IN ('verified', 'failed', 'unknown', 'not_assigned', 'no_schedule', 'locked', 'session_exists', 'teacher_inactive', 'enrolled', 'deleted', 'cancelled')),
    confidence                   INTEGER,
    message                      TEXT COLLATE NOCASE,
    ip_address                   TEXT COLLATE NOCASE,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_fplog_device FOREIGN KEY (device_row_id) REFERENCES devices (id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_fplog_teacher FOREIGN KEY (teacher_id) REFERENCES teachers (teacher_id) ON DELETE SET NULL ON UPDATE CASCADE
);
INSERT INTO fingerprint_logs__new (log_id, teacher_id, device_row_id, sensor_template_id, result, confidence, message, ip_address, created_at)
    SELECT log_id, teacher_id, device_row_id, sensor_template_id, result, confidence, message, ip_address, created_at FROM fingerprint_logs;
DROP TABLE fingerprint_logs;
ALTER TABLE fingerprint_logs__new RENAME TO fingerprint_logs;
CREATE INDEX idx_fplog_device ON fingerprint_logs (device_row_id, created_at);
CREATE INDEX idx_fplog_result ON fingerprint_logs (result, created_at);
CREATE INDEX idx_fplog_teacher ON fingerprint_logs (teacher_id, created_at);

