-- ===========================================================================
-- L-SIAMS · 003 · Students, RFID cards and card history
-- ===========================================================================
-- Part 13.5: a student's grade level is DERIVED from their section. There is no
-- students.grade_level_id column, which structurally eliminates the possibility
-- of a Grade 10 student holding a Grade 12 grade-level record.
-- ===========================================================================


CREATE TABLE IF NOT EXISTS students (
    student_id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    student_number               TEXT NOT NULL COLLATE NOCASE,
    -- Required: "a student without a section cannot be issued an RFID card and
    -- cannot be marked present" (Part 13.4).
    section_id                   INTEGER NOT NULL,
    first_name                   TEXT NOT NULL COLLATE NOCASE,
    middle_name                  TEXT COLLATE NOCASE,
    last_name                    TEXT NOT NULL COLLATE NOCASE,
    suffix                       TEXT COLLATE NOCASE,
    gender                       TEXT NOT NULL DEFAULT 'Prefer not to say' COLLATE NOCASE CHECK (gender IN ('Male', 'Female', 'Other', 'Prefer not to say')),
    birthdate                    TEXT,
    email                        TEXT COLLATE NOCASE,
    address                      TEXT COLLATE NOCASE,
    guardian_name                TEXT NOT NULL COLLATE NOCASE,
    guardian_contact             TEXT NOT NULL COLLATE NOCASE,
    guardian_email               TEXT COLLATE NOCASE,
    photo_path                   TEXT COLLATE NOCASE,
    status                       TEXT NOT NULL DEFAULT 'active' COLLATE NOCASE CHECK (status IN ('active', 'inactive', 'transferred', 'graduated', 'archived')),
    enrolled_at                  TEXT,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    deleted_at                   TEXT,  -- Archive marker — students are never physically deleted
    CONSTRAINT fk_student_section FOREIGN KEY (section_id) REFERENCES sections (section_id) ON DELETE RESTRICT ON UPDATE CASCADE
);
CREATE UNIQUE INDEX uq_student_number ON students (student_number);
CREATE INDEX idx_student_section ON students (section_id);
CREATE INDEX idx_student_status ON students (status, deleted_at);
CREATE INDEX idx_student_name ON students (last_name, first_name);

CREATE TRIGGER trg_students_updated_at
AFTER UPDATE ON students
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.student_id IS NOT OLD.student_id
    OR NEW.student_number IS NOT OLD.student_number
    OR NEW.section_id IS NOT OLD.section_id
    OR NEW.first_name IS NOT OLD.first_name
    OR NEW.middle_name IS NOT OLD.middle_name
    OR NEW.last_name IS NOT OLD.last_name
    OR NEW.suffix IS NOT OLD.suffix
    OR NEW.gender IS NOT OLD.gender
    OR NEW.birthdate IS NOT OLD.birthdate
    OR NEW.email IS NOT OLD.email
    OR NEW.address IS NOT OLD.address
    OR NEW.guardian_name IS NOT OLD.guardian_name
    OR NEW.guardian_contact IS NOT OLD.guardian_contact
    OR NEW.guardian_email IS NOT OLD.guardian_email
    OR NEW.photo_path IS NOT OLD.photo_path
    OR NEW.status IS NOT OLD.status
    OR NEW.enrolled_at IS NOT OLD.enrolled_at
    OR NEW.created_at IS NOT OLD.created_at
    OR NEW.deleted_at IS NOT OLD.deleted_at
)
BEGIN
    UPDATE students SET updated_at = now() WHERE student_id = NEW.student_id;
END;

-- --------------------------------------------------------- RFID cards ----
CREATE TABLE IF NOT EXISTS rfid_cards (
    rfid_id                      INTEGER PRIMARY KEY AUTOINCREMENT,
    student_id                   INTEGER,  -- NULL for stock cards not yet issued
    card_uid                     TEXT NOT NULL COLLATE NOCASE,  -- Normalised uppercase hex
    issue_date                   TEXT NOT NULL,
    replacement_date             TEXT,
    replaced_rfid_id             INTEGER,  -- Chains replacement history without losing attendance
    status                       TEXT NOT NULL DEFAULT 'active' COLLATE NOCASE CHECK (status IN ('active', 'inactive', 'lost', 'blacklisted', 'replaced')),
    notes                        TEXT COLLATE NOCASE,
    issued_by                    INTEGER,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    -- The student while the card is active, NULL otherwise: see below.
    active_student_id            INTEGER GENERATED ALWAYS AS (CASE WHEN status = 'active' THEN student_id ELSE NULL END) STORED,
    -- ON UPDATE RESTRICT, not CASCADE. student_id is an AUTO_INCREMENT surrogate
    -- key that is never updated, so the cascade would never fire — but MariaDB
    -- refuses to build a generated column over a foreign-key child column that
    -- carries a write-back referential action, and active_student_id below is
    -- exactly that. Trading a no-op cascade for the partial-unique index is the
    -- obvious way round, and it costs nothing.
    CONSTRAINT fk_rfid_student FOREIGN KEY (student_id) REFERENCES students (student_id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_rfid_previous FOREIGN KEY (replaced_rfid_id) REFERENCES rfid_cards (rfid_id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_rfid_issuer FOREIGN KEY (issued_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
);
-- One card UID exists exactly once in the whole system.
CREATE UNIQUE INDEX uq_rfid_uid ON rfid_cards (card_uid);
CREATE INDEX idx_rfid_student ON rfid_cards (student_id, status);
CREATE INDEX idx_rfid_status ON rfid_cards (status);
CREATE INDEX fk_rfid_previous ON rfid_cards (replaced_rfid_id);
CREATE INDEX fk_rfid_issuer ON rfid_cards (issued_by);

CREATE TRIGGER trg_rfid_cards_updated_at
AFTER UPDATE ON rfid_cards
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.rfid_id IS NOT OLD.rfid_id
    OR NEW.student_id IS NOT OLD.student_id
    OR NEW.card_uid IS NOT OLD.card_uid
    OR NEW.issue_date IS NOT OLD.issue_date
    OR NEW.replacement_date IS NOT OLD.replacement_date
    OR NEW.replaced_rfid_id IS NOT OLD.replaced_rfid_id
    OR NEW.status IS NOT OLD.status
    OR NEW.notes IS NOT OLD.notes
    OR NEW.issued_by IS NOT OLD.issued_by
    OR NEW.created_at IS NOT OLD.created_at
)
BEGIN
    UPDATE rfid_cards SET updated_at = now() WHERE rfid_id = NEW.rfid_id;
END;

-- "One active RFID per student" is enforced by a partial-unique trick: the
-- generated column is the student_id only while the card is active, and NULL
-- otherwise; it is declared on rfid_cards above, because SQLite cannot add a
-- stored generated column afterwards. NULLs do not collide in a unique index,
-- so any number of retired cards may coexist while a second active card is
-- impossible.
CREATE UNIQUE INDEX IF NOT EXISTS uq_one_active_card_per_student ON rfid_cards (active_student_id);

-- --------------------------------------------------- section transfers ----
-- Part 13.4: transfers are explicit and audited. Historical attendance keeps
-- the section it was recorded under; nothing is retro-rewritten.
CREATE TABLE IF NOT EXISTS student_section_history (
    history_id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    student_id                   INTEGER NOT NULL,
    from_section_id              INTEGER,  -- NULL on initial enrolment
    to_section_id                INTEGER NOT NULL,
    reason                       TEXT NOT NULL COLLATE NOCASE,
    effective_date               TEXT NOT NULL,
    performed_by                 INTEGER NOT NULL,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_ssh_student FOREIGN KEY (student_id) REFERENCES students (student_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_ssh_from FOREIGN KEY (from_section_id) REFERENCES sections (section_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_ssh_to FOREIGN KEY (to_section_id) REFERENCES sections (section_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_ssh_user FOREIGN KEY (performed_by) REFERENCES users (user_id) ON DELETE RESTRICT ON UPDATE CASCADE
);
CREATE INDEX idx_ssh_student ON student_section_history (student_id, effective_date);
CREATE INDEX idx_ssh_to ON student_section_history (to_section_id);
CREATE INDEX fk_ssh_from ON student_section_history (from_section_id);
CREATE INDEX fk_ssh_user ON student_section_history (performed_by);

-- ------------------------------------------------- subject enrolments ----
-- Validation step 13 ("student is enrolled in the session's subject"). A row
-- per section+subject covers the normal case; per-student rows support the
-- student who legitimately takes one subject with a different section.
CREATE TABLE IF NOT EXISTS student_subject_enrolments (
    enrolment_id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    student_id                   INTEGER NOT NULL,
    subject_id                   INTEGER NOT NULL,
    section_id                   INTEGER NOT NULL,  -- The section this student attends the subject with
    school_year_id               INTEGER NOT NULL,
    status                       TEXT NOT NULL DEFAULT 'enrolled' COLLATE NOCASE CHECK (status IN ('enrolled', 'dropped', 'completed')),
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_enrol_student FOREIGN KEY (student_id) REFERENCES students (student_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_enrol_subject FOREIGN KEY (subject_id) REFERENCES subjects (subject_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_enrol_section FOREIGN KEY (section_id) REFERENCES sections (section_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_enrol_year FOREIGN KEY (school_year_id) REFERENCES school_years (school_year_id) ON DELETE RESTRICT ON UPDATE CASCADE
);
CREATE UNIQUE INDEX uq_enrolment ON student_subject_enrolments (student_id, subject_id, school_year_id);
CREATE INDEX idx_enrol_subject ON student_subject_enrolments (subject_id, status);
CREATE INDEX idx_enrol_section ON student_subject_enrolments (section_id, subject_id);
CREATE INDEX fk_enrol_year ON student_subject_enrolments (school_year_id);

CREATE TRIGGER trg_student_subject_enrolments_updated_at
AFTER UPDATE ON student_subject_enrolments
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.enrolment_id IS NOT OLD.enrolment_id
    OR NEW.student_id IS NOT OLD.student_id
    OR NEW.subject_id IS NOT OLD.subject_id
    OR NEW.section_id IS NOT OLD.section_id
    OR NEW.school_year_id IS NOT OLD.school_year_id
    OR NEW.status IS NOT OLD.status
    OR NEW.created_at IS NOT OLD.created_at
)
BEGIN
    UPDATE student_subject_enrolments SET updated_at = now() WHERE enrolment_id = NEW.enrolment_id;
END;

