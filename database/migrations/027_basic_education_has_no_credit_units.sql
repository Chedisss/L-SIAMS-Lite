-- ---------------------------------------------------------------------------
-- 027: subjects do not carry credit units
--
-- subjects.units was a tertiary idea in a basic-education system. Credit units
-- describe a college course; a school running Grades 1 to 12 measures a
-- subject in minutes on a timetable, and this system already holds that — a
-- schedule has a start and an end, so weekly minutes are derivable and a
-- separate hand-typed number can only disagree with them.
--
-- It was also never used. The column was written by the subject form, shown in
-- one table column, and read by exactly one query that selected it and did
-- nothing with it. No load limit, no constraint, no report, nothing in the
-- timetable. A required field on a form that changes no behaviour is worse
-- than no field: somebody has to decide what to type, and the decision is
-- never consulted.
--
-- Dropped rather than hidden. A dead column outlives everyone who knew it was
-- dead, and the next person to read the schema has to work out for themselves
-- that nothing depends on it.
--
-- Nothing is lost that matters: the column held a default of 1.00 for every
-- row the demo seed and the subject form ever created. Attendance, audit,
-- security and login history remain untouched by design — this is reference
-- data, not a record of something that happened.
-- ---------------------------------------------------------------------------

-- ALTER TABLE ... DROP COLUMN only exists from SQLite 3.35, and PHP builds
-- bundle a range of versions, so the column is dropped by rebuilding.
-- The table is rebuilt: a new one in the final shape, the rows copied across,
-- the old one dropped and the new one renamed into its place. Indexes and
-- triggers go with the old table, so they are recreated after.
CREATE TABLE subjects__new (
    subject_id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    subject_code                 TEXT NOT NULL COLLATE NOCASE,
    subject_name                 TEXT NOT NULL COLLATE NOCASE,
    description                  TEXT COLLATE NOCASE,
    department_id                INTEGER NOT NULL,
    status                       TEXT NOT NULL DEFAULT 'active' COLLATE NOCASE CHECK (status IN ('active', 'inactive')),
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    deleted_at                   TEXT,
    CONSTRAINT fk_subject_department FOREIGN KEY (department_id) REFERENCES departments (department_id) ON DELETE RESTRICT ON UPDATE CASCADE
);
INSERT INTO subjects__new (subject_id, subject_code, subject_name, description, department_id, status, created_at, updated_at, deleted_at)
    SELECT subject_id, subject_code, subject_name, description, department_id, status, created_at, updated_at, deleted_at FROM subjects;
DROP TABLE subjects;
ALTER TABLE subjects__new RENAME TO subjects;
CREATE INDEX idx_subject_department ON subjects (department_id);
CREATE INDEX idx_subject_status ON subjects (status, deleted_at);
CREATE UNIQUE INDEX uq_subject_code ON subjects (subject_code);

CREATE TRIGGER trg_subjects_updated_at
AFTER UPDATE ON subjects
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.subject_id IS NOT OLD.subject_id
    OR NEW.subject_code IS NOT OLD.subject_code
    OR NEW.subject_name IS NOT OLD.subject_name
    OR NEW.description IS NOT OLD.description
    OR NEW.department_id IS NOT OLD.department_id
    OR NEW.status IS NOT OLD.status
    OR NEW.created_at IS NOT OLD.created_at
    OR NEW.deleted_at IS NOT OLD.deleted_at
)
BEGIN
    UPDATE subjects SET updated_at = now() WHERE subject_id = NEW.subject_id;
END;
-- Views that read subjects are untouched: the runner renames with legacy_alter_table,
-- which leaves them pointing at the name, not the dropped table.

