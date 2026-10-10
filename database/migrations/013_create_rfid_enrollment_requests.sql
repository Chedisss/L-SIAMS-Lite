-- ===========================================================================
-- L-SIAMS · 013 · RFID card enrolment requests
-- ===========================================================================
-- Issuing a card meant typing its UID, or tapping it at a terminal and fishing
-- it out of the unknown-card log afterwards. The second only works while an
-- attendance session is open, because a tap is refused for having no session
-- long before anything looks at the card — so the practical way to issue two
-- hundred cards on a registration day was to type two hundred UIDs.
--
-- This is the same hand-off the fingerprint enrolment uses: the browser opens a
-- request against a terminal, the terminal picks it up on its next poll, waits
-- for a card with the reader to itself, and reports the UID back. No session,
-- no teacher, no typing.
--
-- The captured UID is held here rather than written straight to rfid_cards: the
-- administrator still has to confirm which student it belongs to, and a card
-- read is not an authorisation to issue one.
-- ===========================================================================


CREATE TABLE IF NOT EXISTS rfid_enrollment_requests (
    request_id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    student_id                   INTEGER,  -- NULL while capturing before the student is chosen
    subject_label                TEXT COLLATE NOCASE,  -- Name shown on the terminal display while it waits
    device_row_id                INTEGER NOT NULL,
    -- Filled in by the terminal when the card is presented. Nullable for the
    -- whole of the pending and waiting stages, which is most of a request's life.
    card_uid                     TEXT COLLATE NOCASE,
    status                       TEXT NOT NULL DEFAULT 'pending' COLLATE NOCASE CHECK (status IN ('pending', 'waiting', 'captured', 'assigned', 'failed', 'cancelled', 'expired')),
    -- Named by the firmware and rendered verbatim by the browser, so the wording
    -- of a capture step lives in one place rather than in both.
    stage                        TEXT NOT NULL DEFAULT 'waiting_for_device' COLLATE NOCASE,
    message                      TEXT COLLATE NOCASE,
    requested_by                 INTEGER,
    claimed_at                   TEXT,  -- When the terminal picked the request up
    captured_at                  TEXT,  -- When a card was actually read
    assigned_at                  TEXT,  -- When the UID was issued to a student
    -- A request nobody finishes must not hold the terminal open forever: an
    -- administrator who walks away would otherwise stop anyone else enrolling
    -- on that reader.
    expires_at                   TEXT NOT NULL,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_rer_student FOREIGN KEY (student_id) REFERENCES students (student_id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_rer_device FOREIGN KEY (device_row_id) REFERENCES devices (id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_rer_user FOREIGN KEY (requested_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE INDEX idx_rer_device_status ON rfid_enrollment_requests (device_row_id, status);
CREATE INDEX idx_rer_student ON rfid_enrollment_requests (student_id, created_at);
CREATE INDEX idx_rer_open ON rfid_enrollment_requests (status, expires_at);
CREATE INDEX idx_rer_uid ON rfid_enrollment_requests (card_uid);
CREATE INDEX fk_rer_user ON rfid_enrollment_requests (requested_by);

CREATE TRIGGER trg_rfid_enrollment_requests_updated_at
AFTER UPDATE ON rfid_enrollment_requests
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.request_id IS NOT OLD.request_id
    OR NEW.student_id IS NOT OLD.student_id
    OR NEW.subject_label IS NOT OLD.subject_label
    OR NEW.device_row_id IS NOT OLD.device_row_id
    OR NEW.card_uid IS NOT OLD.card_uid
    OR NEW.status IS NOT OLD.status
    OR NEW.stage IS NOT OLD.stage
    OR NEW.message IS NOT OLD.message
    OR NEW.requested_by IS NOT OLD.requested_by
    OR NEW.claimed_at IS NOT OLD.claimed_at
    OR NEW.captured_at IS NOT OLD.captured_at
    OR NEW.assigned_at IS NOT OLD.assigned_at
    OR NEW.expires_at IS NOT OLD.expires_at
    OR NEW.created_at IS NOT OLD.created_at
)
BEGIN
    UPDATE rfid_enrollment_requests SET updated_at = now() WHERE request_id = NEW.request_id;
END;

