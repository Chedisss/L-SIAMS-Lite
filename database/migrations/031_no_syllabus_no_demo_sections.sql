-- ---------------------------------------------------------------------------
-- 031: drop the per-grade syllabus, and clear the demo sections
--
-- The syllabus field was built on request and withdrawn on sight, which is the
-- right way round: a subject offered to six grades produced six empty
-- textareas on the edit form, and six boxes nobody is going to fill in are
-- worse than none — they push the fields that matter below the fold.
--
-- Dropped rather than hidden, for the same reason subjects.units was in
-- migration 027: a dead column outlives everyone who knew it was dead.
--
-- The Grade 7 sections and their students are the last of the demo data the
-- school has confirmed is not real. Soft deletes, restorable from the Sections
-- page, and no attendance record is touched.
--
-- ---------------------------------------------------------------------------
-- Two things in here are defensive rather than decorative, and both are the
-- result of this migration failing on the deployed database:
--
--   IF EXISTS on the column drop. A migration that fails part-way is not
--   recorded as applied, so the next run starts it again from the top — and
--   DDL had already committed. Without the guard the retry fails on "check
--   that it exists" and the school is stuck in a loop it cannot get out of.
--
--   The temporary table. students carries an AFTER UPDATE trigger that keeps
--   sections.enrolled_count in step, and MySQL refuses (error 1442) to let a
--   trigger write to a table the invoking statement is already reading. The
--   original wrote UPDATE students JOIN sections, which reads sections, so
--   every school with actual students in those sections hit it. Copying the
--   ids out first means the UPDATE never mentions sections at all.
--
-- The reason this passed here and failed there is worth recording: the demo
-- database had no active students in those sections, so the UPDATE matched
-- nothing, the trigger never fired, and the bug was invisible. Verifying the
-- end state is not the same as verifying the work happened.
--
-- On SQLite neither problem exists — a migration runs in one transaction, DDL
-- included, so a failure leaves nothing half-done; and a trigger may write to
-- a table its statement reads. The structure is kept so this file still lines
-- up with the MariaDB one.
-- ---------------------------------------------------------------------------

-- Dropped by rebuilding: ALTER TABLE ... DROP COLUMN only exists from SQLite 3.35.
-- The table is rebuilt: a new one in the final shape, the rows copied across,
-- the old one dropped and the new one renamed into its place. Indexes and
-- triggers go with the old table, so they are recreated after.
CREATE TABLE subject_grade_levels__new (
    subject_id                   INTEGER NOT NULL,
    grade_level_id               INTEGER NOT NULL,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    PRIMARY KEY (subject_id, grade_level_id),
    CONSTRAINT fk_sgl_grade FOREIGN KEY (grade_level_id) REFERENCES grade_levels (grade_level_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_sgl_subject FOREIGN KEY (subject_id) REFERENCES subjects (subject_id) ON DELETE CASCADE ON UPDATE CASCADE
);
INSERT INTO subject_grade_levels__new (subject_id, grade_level_id, created_at)
    SELECT subject_id, grade_level_id, created_at FROM subject_grade_levels;
DROP TABLE subject_grade_levels;
ALTER TABLE subject_grade_levels__new RENAME TO subject_grade_levels;
CREATE INDEX idx_sgl_grade ON subject_grade_levels (grade_level_id);

-- ------------------------------------------------------------ demo sections
-- The ids, copied out of sections so that nothing below has to read from it.

CREATE TEMP TABLE IF NOT EXISTS tmp_demo_sections (
    section_id INTEGER NOT NULL PRIMARY KEY
);

DELETE FROM tmp_demo_sections;

INSERT INTO tmp_demo_sections (section_id)
SELECT section_id FROM sections WHERE section_code IN ('G7-S1','G7-S2');

-- Students first: archiveSection() refuses while any are enrolled, and this
-- follows the same order the interface would force.

UPDATE students
   SET status = 'inactive', deleted_at = NOW(), updated_at = NOW()
 WHERE section_id IN (SELECT section_id FROM tmp_demo_sections)
   AND deleted_at IS NULL;

UPDATE schedules
   SET status = 'archived', deleted_at = NOW(), updated_at = NOW()
 WHERE section_id IN (SELECT section_id FROM tmp_demo_sections)
   AND status = 'active'
   AND deleted_at IS NULL;

UPDATE sections
   SET status = 'archived', deleted_at = NOW(), updated_at = NOW()
 WHERE section_code IN ('G7-S1','G7-S2')
   AND deleted_at IS NULL;

DROP TABLE IF EXISTS temp.tmp_demo_sections;
