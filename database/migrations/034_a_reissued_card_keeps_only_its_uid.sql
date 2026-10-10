-- ---------------------------------------------------------------------------
-- 034: a re-issued card carries its UID and nothing else
--
-- Releasing a card back to stock cleared student_id, which was right, and threw
-- away the only record of who had held it, which was not. On the RFID Cards
-- page the row went to "unassigned" with an em dash where the name had been,
-- and there was nowhere left in the interface to find out whose card it had
-- been — the audit log knew, and nothing a person looks at did.
--
-- So the holder is remembered rather than erased. released_student_id is who
-- last carried the card and released_at is when they stopped; both survive the
-- card being issued to somebody else, because "this used to be Ocampo's card"
-- stays true and stays useful.
--
-- The other half of the same fault is in the query rather than the schema and
-- is fixed alongside this: the Taps and Last tap columns counted every tap the
-- physical card had ever made, so a card re-issued after a term showed its new
-- owner fifteen taps they had never made. Those counts are now scoped to the
-- student who actually holds it. The card's full history is still readable, in
-- the tap history view, which is per-UID on purpose — that is the one place the
-- question is "what has this piece of plastic done", not "what has this pupil
-- done".
-- ---------------------------------------------------------------------------

-- The two columns, fk_rfid_released_student and its index arrive in one
-- rebuild: SQLite cannot add a named foreign key to an existing table. The
-- IF NOT EXISTS / IF EXISTS guards are not needed here — a failed migration is
-- rolled back whole, so a retry always starts from the previous state.
-- The table is rebuilt: a new one in the final shape, the rows copied across,
-- the old one dropped and the new one renamed into its place. Indexes and
-- triggers go with the old table, so they are recreated after.
CREATE TABLE rfid_cards__new (
    rfid_id                      INTEGER PRIMARY KEY AUTOINCREMENT,
    student_id                   INTEGER,
    released_student_id          INTEGER,
    released_at                  TEXT,
    card_uid                     TEXT NOT NULL COLLATE NOCASE,
    issue_date                   TEXT NOT NULL,
    replacement_date             TEXT,
    replacement_reason           TEXT COLLATE NOCASE CHECK (replacement_reason IN ('lost', 'damaged', 'stolen', 'not_returned', 'other')),
    replacement_note             TEXT COLLATE NOCASE,
    replaced_rfid_id             INTEGER,
    status                       TEXT NOT NULL DEFAULT 'active' COLLATE NOCASE CHECK (status IN ('active', 'inactive', 'lost', 'blacklisted', 'replaced')),
    notes                        TEXT COLLATE NOCASE,
    issued_by                    INTEGER,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    active_student_id            INTEGER GENERATED ALWAYS AS (CASE WHEN status = 'active' THEN student_id ELSE NULL END) STORED,
    CONSTRAINT fk_rfid_issuer FOREIGN KEY (issued_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_rfid_previous FOREIGN KEY (replaced_rfid_id) REFERENCES rfid_cards (rfid_id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_rfid_released_student FOREIGN KEY (released_student_id) REFERENCES students (student_id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_rfid_student FOREIGN KEY (student_id) REFERENCES students (student_id) ON DELETE RESTRICT ON UPDATE RESTRICT
);
INSERT INTO rfid_cards__new (rfid_id, student_id, card_uid, issue_date, replacement_date, replacement_reason, replacement_note, replaced_rfid_id, status, notes, issued_by, created_at, updated_at)
    SELECT rfid_id, student_id, card_uid, issue_date, replacement_date, replacement_reason, replacement_note, replaced_rfid_id, status, notes, issued_by, created_at, updated_at FROM rfid_cards;
DROP TABLE rfid_cards;
ALTER TABLE rfid_cards__new RENAME TO rfid_cards;
CREATE INDEX fk_rfid_issuer ON rfid_cards (issued_by);
CREATE INDEX fk_rfid_previous ON rfid_cards (replaced_rfid_id);
CREATE INDEX idx_rfid_released ON rfid_cards (released_student_id);
CREATE INDEX idx_rfid_replacement_reason ON rfid_cards (replacement_reason, replacement_date);
CREATE INDEX idx_rfid_status ON rfid_cards (status);
CREATE INDEX idx_rfid_student ON rfid_cards (student_id, status);
CREATE UNIQUE INDEX uq_one_active_card_per_student ON rfid_cards (active_student_id);
CREATE UNIQUE INDEX uq_rfid_uid ON rfid_cards (card_uid);

CREATE TRIGGER trg_rfid_cards_updated_at
AFTER UPDATE ON rfid_cards
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.rfid_id IS NOT OLD.rfid_id
    OR NEW.student_id IS NOT OLD.student_id
    OR NEW.released_student_id IS NOT OLD.released_student_id
    OR NEW.released_at IS NOT OLD.released_at
    OR NEW.card_uid IS NOT OLD.card_uid
    OR NEW.issue_date IS NOT OLD.issue_date
    OR NEW.replacement_date IS NOT OLD.replacement_date
    OR NEW.replacement_reason IS NOT OLD.replacement_reason
    OR NEW.replacement_note IS NOT OLD.replacement_note
    OR NEW.replaced_rfid_id IS NOT OLD.replaced_rfid_id
    OR NEW.status IS NOT OLD.status
    OR NEW.notes IS NOT OLD.notes
    OR NEW.issued_by IS NOT OLD.issued_by
    OR NEW.created_at IS NOT OLD.created_at
)
BEGIN
    UPDATE rfid_cards SET updated_at = now() WHERE rfid_id = NEW.rfid_id;
END;
-- Views that read rfid_cards are untouched: the runner renames with legacy_alter_table,
-- which leaves them pointing at the name, not the dropped table.


-- ------------------------------------------------------ recover what was lost
-- Cards released before this migration had their holder cleared with nothing
-- kept, so those names are already gone from the page. They are not gone from
-- the audit log: RFID_RELEASED records the previous student_id in old_value,
-- precisely so a question like this one can be answered later.
--
-- Recovered from there rather than left blank, because a school that released
-- a drawer of cards yesterday should not have to accept a permanent hole in
-- the register as the price of a fix shipped today.
--
-- Only the most recent release per card is used, and only where the student
-- still exists; a card released twice is described by the last release.
-- SQLite has no UPDATE ... JOIN, so the same three joins become a CTE that
-- names, for each released card, the student its latest RFID_RELEASED audit
-- entry recorded. json_extract() is only reached through json_valid(), as the
-- MariaDB version guarded JSON_EXTRACT() with JSON_VALID().
WITH latest AS (
    SELECT CAST(record_id AS INTEGER) AS rfid_id,
           MAX(audit_id)             AS audit_id
      FROM audit_logs
     WHERE action = 'RFID_RELEASED'
       AND record_type = 'rfid_card'
     GROUP BY record_id
),
released AS (
    SELECT latest.rfid_id, st.student_id, a.created_at
      FROM latest
      JOIN audit_logs a ON a.audit_id = latest.audit_id
      JOIN students st
        ON st.student_id = CAST(CASE WHEN json_valid(a.old_value)
                                     THEN json_extract(a.old_value, '$.student_id') END AS INTEGER)
)
UPDATE rfid_cards
   SET released_student_id = (SELECT r.student_id FROM released r WHERE r.rfid_id = rfid_cards.rfid_id),
       released_at         = (SELECT r.created_at FROM released r WHERE r.rfid_id = rfid_cards.rfid_id)
 WHERE released_student_id IS NULL
   AND rfid_id IN (SELECT rfid_id FROM released);

