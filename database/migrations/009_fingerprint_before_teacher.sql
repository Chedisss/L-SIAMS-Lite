-- ===========================================================================
-- L-SIAMS · 009 · Fingerprint capture before the teacher record exists
-- ===========================================================================
-- Enrolment used to run against a teacher who was already registered. It now
-- runs during registration instead: the finger is captured first and the
-- resulting slot is held until the teacher is saved, at which point the two are
-- bound together. A teacher therefore cannot exist without a fingerprint, which
-- is the point — an unenrolled teacher can open no session, so registering one
-- produced a record that could not yet do anything.
--
-- Two consequences to carry:
--
--   teacher_id becomes nullable, because during the capture there is nobody to
--   point at yet. It is filled in at the moment the teacher row is created.
--
--   A capture that is never bound — the form was abandoned, the browser closed —
--   leaves a template sitting in the sensor's flash occupying a slot that the
--   server would otherwise hand out again. 'abandoned' marks those so the
--   terminal can be told to delete them on its next poll, which is the only way
--   the slot is genuinely free again.
-- ===========================================================================


-- All four changes below are made by one rebuild: SQLite cannot relax NOT NULL
-- or change an enum list in place.
-- The table is rebuilt: a new one in the final shape, the rows copied across,
-- the old one dropped and the new one renamed into its place. Indexes and
-- triggers go with the old table, so they are recreated after.
CREATE TABLE fingerprint_enrollment_requests__new (
    request_id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    teacher_id                   INTEGER,
    subject_label                TEXT COLLATE NOCASE,
    device_row_id                INTEGER NOT NULL,
    sensor_template_id           INTEGER NOT NULL,
    status                       TEXT NOT NULL DEFAULT 'pending' COLLATE NOCASE CHECK (status IN ('pending', 'scanning', 'completed', 'failed', 'cancelled', 'expired', 'abandoned')),
    stage                        TEXT NOT NULL DEFAULT 'waiting_for_device' COLLATE NOCASE,
    message                      TEXT COLLATE NOCASE,
    quality_score                INTEGER,
    sample_count                 INTEGER NOT NULL DEFAULT 0,
    requested_by                 INTEGER,
    claimed_at                   TEXT,
    completed_at                 TEXT,
    bound_at                     TEXT,
    expires_at                   TEXT NOT NULL,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_fer_device FOREIGN KEY (device_row_id) REFERENCES devices (id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_fer_teacher FOREIGN KEY (teacher_id) REFERENCES teachers (teacher_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_fer_user FOREIGN KEY (requested_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
);
INSERT INTO fingerprint_enrollment_requests__new (request_id, teacher_id, device_row_id, sensor_template_id, status, stage, message, quality_score, sample_count, requested_by, claimed_at, completed_at, expires_at, created_at, updated_at)
    SELECT request_id, teacher_id, device_row_id, sensor_template_id, status, stage, message, quality_score, sample_count, requested_by, claimed_at, completed_at, expires_at, created_at, updated_at FROM fingerprint_enrollment_requests;
DROP TABLE fingerprint_enrollment_requests;
ALTER TABLE fingerprint_enrollment_requests__new RENAME TO fingerprint_enrollment_requests;
CREATE INDEX fk_fer_user ON fingerprint_enrollment_requests (requested_by);
CREATE INDEX idx_fer_device_status ON fingerprint_enrollment_requests (device_row_id, status);
CREATE INDEX idx_fer_open ON fingerprint_enrollment_requests (status, expires_at);
CREATE INDEX idx_fer_slot_hold ON fingerprint_enrollment_requests (device_row_id, sensor_template_id, status);
CREATE INDEX idx_fer_teacher ON fingerprint_enrollment_requests (teacher_id, created_at);

CREATE TRIGGER trg_fingerprint_enrollment_requests_updated_at
AFTER UPDATE ON fingerprint_enrollment_requests
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.request_id IS NOT OLD.request_id
    OR NEW.teacher_id IS NOT OLD.teacher_id
    OR NEW.subject_label IS NOT OLD.subject_label
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
    OR NEW.bound_at IS NOT OLD.bound_at
    OR NEW.expires_at IS NOT OLD.expires_at
    OR NEW.created_at IS NOT OLD.created_at
)
BEGIN
    UPDATE fingerprint_enrollment_requests SET updated_at = now() WHERE request_id = NEW.request_id;
END;




-- Answers "which slots on this terminal are spoken for", which is what slot
-- allocation and the terminal's delete list both need.

