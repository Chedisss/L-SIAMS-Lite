-- ===========================================================================
-- L-SIAMS · 002 · Academic structure (Part 13)
-- ===========================================================================
-- Departments, grade levels and sections are first-class, referentially
-- enforced entities. Every teacher, subject, student, schedule and attendance
-- record resolves to a real row in these tables — `department` is never a
-- free-text field and `section` is never a loose label.
-- ===========================================================================


-- ---------------------------------------------------------- school years ----
CREATE TABLE IF NOT EXISTS school_years (
    school_year_id               INTEGER PRIMARY KEY AUTOINCREMENT,
    year_label                   TEXT NOT NULL COLLATE NOCASE,  -- e.g. 2026-2027
    start_date                   TEXT NOT NULL,
    end_date                     TEXT NOT NULL,
    is_current                   INTEGER NOT NULL DEFAULT 0,
    status                       TEXT NOT NULL DEFAULT 'active' COLLATE NOCASE CHECK (status IN ('active', 'closed', 'archived')),
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now())
);
CREATE UNIQUE INDEX uq_school_year ON school_years (year_label);
CREATE INDEX idx_school_year_current ON school_years (is_current);

CREATE TRIGGER trg_school_years_updated_at
AFTER UPDATE ON school_years
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.school_year_id IS NOT OLD.school_year_id
    OR NEW.year_label IS NOT OLD.year_label
    OR NEW.start_date IS NOT OLD.start_date
    OR NEW.end_date IS NOT OLD.end_date
    OR NEW.is_current IS NOT OLD.is_current
    OR NEW.status IS NOT OLD.status
    OR NEW.created_at IS NOT OLD.created_at
)
BEGIN
    UPDATE school_years SET updated_at = now() WHERE school_year_id = NEW.school_year_id;
END;

-- ----------------------------------------------------------- departments ----
CREATE TABLE IF NOT EXISTS departments (
    department_id                INTEGER PRIMARY KEY AUTOINCREMENT,
    department_code              TEXT NOT NULL COLLATE NOCASE,  -- Unique and immutable after creation (Part 13.2)
    department_name              TEXT NOT NULL COLLATE NOCASE,
    description                  TEXT COLLATE NOCASE,
    head_teacher_id              INTEGER,
    status                       TEXT NOT NULL DEFAULT 'active' COLLATE NOCASE CHECK (status IN ('active', 'inactive')),
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    deleted_at                   TEXT,
    -- teachers is created further down; SQLite resolves a foreign key when it
    -- is used, not when it is declared, so the head of department can be
    -- declared here instead of added afterwards with ALTER TABLE.
    CONSTRAINT fk_department_head FOREIGN KEY (head_teacher_id) REFERENCES teachers (teacher_id) ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE INDEX fk_department_head ON departments (head_teacher_id);
CREATE UNIQUE INDEX uq_department_code ON departments (department_code);
CREATE UNIQUE INDEX uq_department_name ON departments (department_name);
CREATE INDEX idx_department_status ON departments (status, deleted_at);

CREATE TRIGGER trg_departments_updated_at
AFTER UPDATE ON departments
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.department_id IS NOT OLD.department_id
    OR NEW.department_code IS NOT OLD.department_code
    OR NEW.department_name IS NOT OLD.department_name
    OR NEW.description IS NOT OLD.description
    OR NEW.head_teacher_id IS NOT OLD.head_teacher_id
    OR NEW.status IS NOT OLD.status
    OR NEW.created_at IS NOT OLD.created_at
    OR NEW.deleted_at IS NOT OLD.deleted_at
)
BEGIN
    UPDATE departments SET updated_at = now() WHERE department_id = NEW.department_id;
END;

-- ---------------------------------------------------------- grade levels ----
CREATE TABLE IF NOT EXISTS grade_levels (
    grade_level_id               INTEGER PRIMARY KEY AUTOINCREMENT,
    grade_level_code             TEXT NOT NULL COLLATE NOCASE,  -- G7 … G12
    grade_level_name             TEXT NOT NULL COLLATE NOCASE,
    -- All programmatic comparisons use numeric_level. Never compare grade levels
    -- as strings ("G10" < "G7" lexically, which would be a silent disaster).
    numeric_level                INTEGER NOT NULL,
    track                        TEXT COLLATE NOCASE CHECK (track IN ('Academic', 'TVL', 'Sports', 'Arts and Design')),
    status                       TEXT NOT NULL DEFAULT 'active' COLLATE NOCASE CHECK (status IN ('active', 'inactive')),
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now())
);
CREATE UNIQUE INDEX uq_grade_code ON grade_levels (grade_level_code);
CREATE UNIQUE INDEX uq_grade_numeric ON grade_levels (numeric_level);
CREATE INDEX idx_grade_status ON grade_levels (status);

CREATE TRIGGER trg_grade_levels_updated_at
AFTER UPDATE ON grade_levels
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.grade_level_id IS NOT OLD.grade_level_id
    OR NEW.grade_level_code IS NOT OLD.grade_level_code
    OR NEW.grade_level_name IS NOT OLD.grade_level_name
    OR NEW.numeric_level IS NOT OLD.numeric_level
    OR NEW.track IS NOT OLD.track
    OR NEW.status IS NOT OLD.status
    OR NEW.created_at IS NOT OLD.created_at
)
BEGIN
    UPDATE grade_levels SET updated_at = now() WHERE grade_level_id = NEW.grade_level_id;
END;

-- -------------------------------------------------------------- subjects ----
CREATE TABLE IF NOT EXISTS subjects (
    subject_id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    subject_code                 TEXT NOT NULL COLLATE NOCASE,
    subject_name                 TEXT NOT NULL COLLATE NOCASE,
    description                  TEXT COLLATE NOCASE,
    -- Part 13.2: every subject belongs to exactly one department. This column is
    -- what makes the Part 14.1 cross-department constraint enforceable at all.
    department_id                INTEGER NOT NULL,
    units                        NUMERIC NOT NULL DEFAULT 1.00,
    status                       TEXT NOT NULL DEFAULT 'active' COLLATE NOCASE CHECK (status IN ('active', 'inactive')),
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    deleted_at                   TEXT,
    CONSTRAINT fk_subject_department FOREIGN KEY (department_id) REFERENCES departments (department_id) ON DELETE RESTRICT ON UPDATE CASCADE
);
CREATE UNIQUE INDEX uq_subject_code ON subjects (subject_code);
CREATE INDEX idx_subject_department ON subjects (department_id);
CREATE INDEX idx_subject_status ON subjects (status, deleted_at);

CREATE TRIGGER trg_subjects_updated_at
AFTER UPDATE ON subjects
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.subject_id IS NOT OLD.subject_id
    OR NEW.subject_code IS NOT OLD.subject_code
    OR NEW.subject_name IS NOT OLD.subject_name
    OR NEW.description IS NOT OLD.description
    OR NEW.department_id IS NOT OLD.department_id
    OR NEW.units IS NOT OLD.units
    OR NEW.status IS NOT OLD.status
    OR NEW.created_at IS NOT OLD.created_at
    OR NEW.deleted_at IS NOT OLD.deleted_at
)
BEGIN
    UPDATE subjects SET updated_at = now() WHERE subject_id = NEW.subject_id;
END;

-- Which grade levels a subject is offered to (schedule validation rule 7).
CREATE TABLE IF NOT EXISTS subject_grade_levels (
    subject_id                   INTEGER NOT NULL,
    grade_level_id               INTEGER NOT NULL,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    PRIMARY KEY (subject_id, grade_level_id),
    CONSTRAINT fk_sgl_subject FOREIGN KEY (subject_id) REFERENCES subjects (subject_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_sgl_grade FOREIGN KEY (grade_level_id) REFERENCES grade_levels (grade_level_id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX idx_sgl_grade ON subject_grade_levels (grade_level_id);

-- ------------------------------------------------------------- teachers ----
CREATE TABLE IF NOT EXISTS teachers (
    teacher_id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    employee_number              TEXT NOT NULL COLLATE NOCASE,  -- Unique and immutable after creation
    user_id                      INTEGER,  -- Web account; NULL until credentials are issued
    department_id                INTEGER NOT NULL,  -- Primary department (Part 13.2)
    first_name                   TEXT NOT NULL COLLATE NOCASE,
    middle_name                  TEXT COLLATE NOCASE,
    last_name                    TEXT NOT NULL COLLATE NOCASE,
    suffix                       TEXT COLLATE NOCASE,
    email                        TEXT NOT NULL COLLATE NOCASE,
    phone                        TEXT COLLATE NOCASE,
    position                     TEXT COLLATE NOCASE,
    photo_path                   TEXT COLLATE NOCASE,
    fingerprint_status           TEXT NOT NULL DEFAULT 'not_enrolled' COLLATE NOCASE CHECK (fingerprint_status IN ('not_enrolled', 'enrolled', 'disabled')),
    status                       TEXT NOT NULL DEFAULT 'active' COLLATE NOCASE CHECK (status IN ('active', 'inactive', 'archived')),
    hired_at                     TEXT,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    deleted_at                   TEXT,
    CONSTRAINT fk_teacher_user FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_teacher_department FOREIGN KEY (department_id) REFERENCES departments (department_id) ON DELETE RESTRICT ON UPDATE CASCADE
);
CREATE UNIQUE INDEX uq_teacher_employee ON teachers (employee_number);
CREATE UNIQUE INDEX uq_teacher_user ON teachers (user_id);
CREATE UNIQUE INDEX uq_teacher_email ON teachers (email);
CREATE INDEX idx_teacher_department ON teachers (department_id);
CREATE INDEX idx_teacher_status ON teachers (status, deleted_at);
CREATE INDEX idx_teacher_name ON teachers (last_name, first_name);

CREATE TRIGGER trg_teachers_updated_at
AFTER UPDATE ON teachers
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.teacher_id IS NOT OLD.teacher_id
    OR NEW.employee_number IS NOT OLD.employee_number
    OR NEW.user_id IS NOT OLD.user_id
    OR NEW.department_id IS NOT OLD.department_id
    OR NEW.first_name IS NOT OLD.first_name
    OR NEW.middle_name IS NOT OLD.middle_name
    OR NEW.last_name IS NOT OLD.last_name
    OR NEW.suffix IS NOT OLD.suffix
    OR NEW.email IS NOT OLD.email
    OR NEW.phone IS NOT OLD.phone
    OR NEW.position IS NOT OLD.position
    OR NEW.photo_path IS NOT OLD.photo_path
    OR NEW.fingerprint_status IS NOT OLD.fingerprint_status
    OR NEW.status IS NOT OLD.status
    OR NEW.hired_at IS NOT OLD.hired_at
    OR NEW.created_at IS NOT OLD.created_at
    OR NEW.deleted_at IS NOT OLD.deleted_at
)
BEGIN
    UPDATE teachers SET updated_at = now() WHERE teacher_id = NEW.teacher_id;
END;

-- (fk_department_head is declared on departments above.)

-- Secondary departments (Part 14.6). The primary lives on teachers.department_id;
-- rows here are always the result of an explicit, audited administrator action.
CREATE TABLE IF NOT EXISTS teacher_departments (
    teacher_id                   INTEGER NOT NULL,
    department_id                INTEGER NOT NULL,
    is_primary                   INTEGER NOT NULL DEFAULT 0,
    assigned_by                  INTEGER,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    PRIMARY KEY (teacher_id, department_id),
    CONSTRAINT fk_td_teacher FOREIGN KEY (teacher_id) REFERENCES teachers (teacher_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_td_department FOREIGN KEY (department_id) REFERENCES departments (department_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_td_assigner FOREIGN KEY (assigned_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE INDEX idx_td_department ON teacher_departments (department_id);
CREATE INDEX fk_td_assigner ON teacher_departments (assigned_by);

-- Part 14.2: most teachers handle one grade level; the pivot supports several
-- without any redesign.
CREATE TABLE IF NOT EXISTS teacher_grade_levels (
    teacher_id                   INTEGER NOT NULL,
    grade_level_id               INTEGER NOT NULL,
    assigned_by                  INTEGER,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    PRIMARY KEY (teacher_id, grade_level_id),
    CONSTRAINT fk_tgl_teacher FOREIGN KEY (teacher_id) REFERENCES teachers (teacher_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_tgl_grade FOREIGN KEY (grade_level_id) REFERENCES grade_levels (grade_level_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_tgl_assigner FOREIGN KEY (assigned_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE INDEX idx_tgl_grade ON teacher_grade_levels (grade_level_id);
CREATE INDEX fk_tgl_assigner ON teacher_grade_levels (assigned_by);

CREATE TABLE IF NOT EXISTS teacher_subjects (
    teacher_id                   INTEGER NOT NULL,
    subject_id                   INTEGER NOT NULL,
    assigned_by                  INTEGER,
    is_exception                 INTEGER NOT NULL DEFAULT 0,  -- Granted through a cross-department exception
    created_at                   TEXT NOT NULL DEFAULT (now()),
    PRIMARY KEY (teacher_id, subject_id),
    CONSTRAINT fk_ts_teacher FOREIGN KEY (teacher_id) REFERENCES teachers (teacher_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_ts_subject FOREIGN KEY (subject_id) REFERENCES subjects (subject_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_ts_assigner FOREIGN KEY (assigned_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE INDEX idx_ts_subject ON teacher_subjects (subject_id);
CREATE INDEX fk_ts_assigner ON teacher_subjects (assigned_by);

-- ------------------------------------------------------------- sections ----
CREATE TABLE IF NOT EXISTS sections (
    section_id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    section_code                 TEXT NOT NULL COLLATE NOCASE,
    section_name                 TEXT NOT NULL COLLATE NOCASE,
    grade_level_id               INTEGER NOT NULL,
    adviser_id                   INTEGER,
    strand                       TEXT COLLATE NOCASE,  -- STEM, ABM, HUMSS, GAS, ICT …
    capacity                     INTEGER NOT NULL DEFAULT 45,
    -- Maintained by trigger on students INSERT/UPDATE/DELETE so it is never a
    -- stale copy that capacity checks could be fooled by.
    enrolled_count               INTEGER NOT NULL DEFAULT 0,
    school_year_id               INTEGER NOT NULL,
    default_classroom_id         INTEGER,
    status                       TEXT NOT NULL DEFAULT 'active' COLLATE NOCASE CHECK (status IN ('active', 'inactive', 'archived')),
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    deleted_at                   TEXT,
    CONSTRAINT fk_section_grade FOREIGN KEY (grade_level_id) REFERENCES grade_levels (grade_level_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_section_adviser FOREIGN KEY (adviser_id) REFERENCES teachers (teacher_id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_section_year FOREIGN KEY (school_year_id) REFERENCES school_years (school_year_id) ON DELETE RESTRICT ON UPDATE CASCADE
);
CREATE UNIQUE INDEX uq_section_code_year ON sections (section_code, school_year_id);
CREATE INDEX idx_section_grade ON sections (grade_level_id);
CREATE INDEX idx_section_adviser ON sections (adviser_id);
CREATE INDEX idx_section_status ON sections (status, deleted_at);
CREATE INDEX fk_section_year ON sections (school_year_id);

CREATE TRIGGER trg_sections_updated_at
AFTER UPDATE ON sections
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.section_id IS NOT OLD.section_id
    OR NEW.section_code IS NOT OLD.section_code
    OR NEW.section_name IS NOT OLD.section_name
    OR NEW.grade_level_id IS NOT OLD.grade_level_id
    OR NEW.adviser_id IS NOT OLD.adviser_id
    OR NEW.strand IS NOT OLD.strand
    OR NEW.capacity IS NOT OLD.capacity
    OR NEW.enrolled_count IS NOT OLD.enrolled_count
    OR NEW.school_year_id IS NOT OLD.school_year_id
    OR NEW.default_classroom_id IS NOT OLD.default_classroom_id
    OR NEW.status IS NOT OLD.status
    OR NEW.created_at IS NOT OLD.created_at
    OR NEW.deleted_at IS NOT OLD.deleted_at
)
BEGIN
    UPDATE sections SET updated_at = now() WHERE section_id = NEW.section_id;
END;

CREATE TABLE IF NOT EXISTS teacher_sections (
    teacher_id                   INTEGER NOT NULL,
    section_id                   INTEGER NOT NULL,
    assigned_by                  INTEGER,
    is_exception                 INTEGER NOT NULL DEFAULT 0,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    PRIMARY KEY (teacher_id, section_id),
    CONSTRAINT fk_tsec_teacher FOREIGN KEY (teacher_id) REFERENCES teachers (teacher_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_tsec_section FOREIGN KEY (section_id) REFERENCES sections (section_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_tsec_assigner FOREIGN KEY (assigned_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE INDEX idx_tsec_section ON teacher_sections (section_id);
CREATE INDEX fk_tsec_assigner ON teacher_sections (assigned_by);

-- ------------------------------------ controlled overrides (Part 14.6) ----
-- Exceptions never weaken the default rule; they are named, time-boxed and
-- audited grants that the validators consult explicitly.
CREATE TABLE IF NOT EXISTS teacher_department_exceptions (
    exception_id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    teacher_id                   INTEGER NOT NULL,
    department_id                INTEGER NOT NULL,
    reason                       TEXT NOT NULL COLLATE NOCASE,
    effective_from               TEXT NOT NULL,
    effective_to                 TEXT NOT NULL,
    granted_by                   INTEGER NOT NULL,
    revoked_at                   TEXT,
    revoked_by                   INTEGER,
    status                       TEXT NOT NULL DEFAULT 'active' COLLATE NOCASE CHECK (status IN ('active', 'expired', 'revoked')),
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_tde_teacher FOREIGN KEY (teacher_id) REFERENCES teachers (teacher_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_tde_department FOREIGN KEY (department_id) REFERENCES departments (department_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_tde_granter FOREIGN KEY (granted_by) REFERENCES users (user_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_tde_revoker FOREIGN KEY (revoked_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE INDEX idx_tde_lookup ON teacher_department_exceptions (teacher_id, department_id, status, effective_from, effective_to);
CREATE INDEX fk_tde_department ON teacher_department_exceptions (department_id);
CREATE INDEX fk_tde_granter ON teacher_department_exceptions (granted_by);
CREATE INDEX fk_tde_revoker ON teacher_department_exceptions (revoked_by);

CREATE TRIGGER trg_teacher_department_exceptions_updated_at
AFTER UPDATE ON teacher_department_exceptions
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.exception_id IS NOT OLD.exception_id
    OR NEW.teacher_id IS NOT OLD.teacher_id
    OR NEW.department_id IS NOT OLD.department_id
    OR NEW.reason IS NOT OLD.reason
    OR NEW.effective_from IS NOT OLD.effective_from
    OR NEW.effective_to IS NOT OLD.effective_to
    OR NEW.granted_by IS NOT OLD.granted_by
    OR NEW.revoked_at IS NOT OLD.revoked_at
    OR NEW.revoked_by IS NOT OLD.revoked_by
    OR NEW.status IS NOT OLD.status
    OR NEW.created_at IS NOT OLD.created_at
)
BEGIN
    UPDATE teacher_department_exceptions SET updated_at = now() WHERE exception_id = NEW.exception_id;
END;

CREATE TABLE IF NOT EXISTS teacher_grade_level_exceptions (
    exception_id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    teacher_id                   INTEGER NOT NULL,
    grade_level_id               INTEGER NOT NULL,
    reason                       TEXT NOT NULL COLLATE NOCASE,
    effective_from               TEXT NOT NULL,
    effective_to                 TEXT NOT NULL,
    granted_by                   INTEGER NOT NULL,
    revoked_at                   TEXT,
    revoked_by                   INTEGER,
    status                       TEXT NOT NULL DEFAULT 'active' COLLATE NOCASE CHECK (status IN ('active', 'expired', 'revoked')),
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_tgle_teacher FOREIGN KEY (teacher_id) REFERENCES teachers (teacher_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_tgle_grade FOREIGN KEY (grade_level_id) REFERENCES grade_levels (grade_level_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_tgle_granter FOREIGN KEY (granted_by) REFERENCES users (user_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_tgle_revoker FOREIGN KEY (revoked_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE INDEX idx_tgle_lookup ON teacher_grade_level_exceptions (teacher_id, grade_level_id, status, effective_from, effective_to);
CREATE INDEX fk_tgle_grade ON teacher_grade_level_exceptions (grade_level_id);
CREATE INDEX fk_tgle_granter ON teacher_grade_level_exceptions (granted_by);
CREATE INDEX fk_tgle_revoker ON teacher_grade_level_exceptions (revoked_by);

CREATE TRIGGER trg_teacher_grade_level_exceptions_updated_at
AFTER UPDATE ON teacher_grade_level_exceptions
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.exception_id IS NOT OLD.exception_id
    OR NEW.teacher_id IS NOT OLD.teacher_id
    OR NEW.grade_level_id IS NOT OLD.grade_level_id
    OR NEW.reason IS NOT OLD.reason
    OR NEW.effective_from IS NOT OLD.effective_from
    OR NEW.effective_to IS NOT OLD.effective_to
    OR NEW.granted_by IS NOT OLD.granted_by
    OR NEW.revoked_at IS NOT OLD.revoked_at
    OR NEW.revoked_by IS NOT OLD.revoked_by
    OR NEW.status IS NOT OLD.status
    OR NEW.created_at IS NOT OLD.created_at
)
BEGIN
    UPDATE teacher_grade_level_exceptions SET updated_at = now() WHERE exception_id = NEW.exception_id;
END;

