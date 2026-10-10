-- ===========================================================================
-- L-SIAMS · 001 · Authentication, authorisation and session tables
-- ===========================================================================
-- Every table here has explicit foreign keys. Historical tables
-- (login_history, audit_logs, security_logs) use ON DELETE RESTRICT so a user
-- row can never be removed in a way that would orphan or erase its history.
-- ===========================================================================


-- ---------------------------------------------------------------- roles ----
CREATE TABLE IF NOT EXISTS roles (
    role_id                      INTEGER PRIMARY KEY AUTOINCREMENT,
    role_name                    TEXT NOT NULL COLLATE NOCASE,
    role_slug                    TEXT NOT NULL COLLATE NOCASE,
    description                  TEXT COLLATE NOCASE,
    is_system                    INTEGER NOT NULL DEFAULT 0,  -- System roles cannot be deleted
    status                       TEXT NOT NULL DEFAULT 'active' COLLATE NOCASE CHECK (status IN ('active', 'inactive')),
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now())
);
CREATE UNIQUE INDEX uq_role_slug ON roles (role_slug);
CREATE UNIQUE INDEX uq_role_name ON roles (role_name);

CREATE TRIGGER trg_roles_updated_at
AFTER UPDATE ON roles
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.role_id IS NOT OLD.role_id
    OR NEW.role_name IS NOT OLD.role_name
    OR NEW.role_slug IS NOT OLD.role_slug
    OR NEW.description IS NOT OLD.description
    OR NEW.is_system IS NOT OLD.is_system
    OR NEW.status IS NOT OLD.status
    OR NEW.created_at IS NOT OLD.created_at
)
BEGIN
    UPDATE roles SET updated_at = now() WHERE role_id = NEW.role_id;
END;

-- ---------------------------------------------------------- permissions ----
CREATE TABLE IF NOT EXISTS permissions (
    permission_id                INTEGER PRIMARY KEY AUTOINCREMENT,
    permission_key               TEXT NOT NULL COLLATE NOCASE,  -- e.g. students.create
    module                       TEXT NOT NULL COLLATE NOCASE,
    description                  TEXT COLLATE NOCASE,
    created_at                   TEXT NOT NULL DEFAULT (now())
);
CREATE UNIQUE INDEX uq_permission_key ON permissions (permission_key);
CREATE INDEX idx_permission_module ON permissions (module);

CREATE TABLE IF NOT EXISTS role_permissions (
    role_id                      INTEGER NOT NULL,
    permission_id                INTEGER NOT NULL,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    PRIMARY KEY (role_id, permission_id),
    CONSTRAINT fk_rp_role FOREIGN KEY (role_id) REFERENCES roles (role_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_rp_permission FOREIGN KEY (permission_id) REFERENCES permissions (permission_id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX idx_rp_permission ON role_permissions (permission_id);

-- ---------------------------------------------------------------- users ----
CREATE TABLE IF NOT EXISTS users (
    user_id                      INTEGER PRIMARY KEY AUTOINCREMENT,
    role_id                      INTEGER NOT NULL,
    username                     TEXT NOT NULL COLLATE NOCASE,
    email                        TEXT NOT NULL COLLATE NOCASE,
    password_hash                TEXT NOT NULL COLLATE NOCASE,  -- bcrypt/argon2id — never plaintext
    full_name                    TEXT NOT NULL COLLATE NOCASE,
    status                       TEXT NOT NULL DEFAULT 'active' COLLATE NOCASE CHECK (status IN ('active', 'inactive', 'locked', 'archived')),
    must_change_password         INTEGER NOT NULL DEFAULT 1,
    password_changed_at          TEXT,
    failed_login_count           INTEGER NOT NULL DEFAULT 0,
    locked_until                 TEXT,
    last_login_at                TEXT,
    last_login_ip                TEXT COLLATE NOCASE,
    photo_path                   TEXT COLLATE NOCASE,
    two_factor_enabled           INTEGER NOT NULL DEFAULT 0,  -- Reserved for 2FA (Part 6 future extensions)
    two_factor_secret            BLOB,
    created_by                   INTEGER,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    deleted_at                   TEXT,
    CONSTRAINT fk_users_role FOREIGN KEY (role_id) REFERENCES roles (role_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_users_creator FOREIGN KEY (created_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
);
-- Uniqueness includes archived rows on purpose: a recycled username would
-- make historical audit entries ambiguous.
CREATE UNIQUE INDEX uq_users_username ON users (username);
CREATE UNIQUE INDEX uq_users_email ON users (email);
CREATE INDEX idx_users_role ON users (role_id);
CREATE INDEX idx_users_status ON users (status);
CREATE INDEX idx_users_deleted ON users (deleted_at);
CREATE INDEX fk_users_creator ON users (created_by);

CREATE TRIGGER trg_users_updated_at
AFTER UPDATE ON users
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.user_id IS NOT OLD.user_id
    OR NEW.role_id IS NOT OLD.role_id
    OR NEW.username IS NOT OLD.username
    OR NEW.email IS NOT OLD.email
    OR NEW.password_hash IS NOT OLD.password_hash
    OR NEW.full_name IS NOT OLD.full_name
    OR NEW.status IS NOT OLD.status
    OR NEW.must_change_password IS NOT OLD.must_change_password
    OR NEW.password_changed_at IS NOT OLD.password_changed_at
    OR NEW.failed_login_count IS NOT OLD.failed_login_count
    OR NEW.locked_until IS NOT OLD.locked_until
    OR NEW.last_login_at IS NOT OLD.last_login_at
    OR NEW.last_login_ip IS NOT OLD.last_login_ip
    OR NEW.photo_path IS NOT OLD.photo_path
    OR NEW.two_factor_enabled IS NOT OLD.two_factor_enabled
    OR NEW.two_factor_secret IS NOT OLD.two_factor_secret
    OR NEW.created_by IS NOT OLD.created_by
    OR NEW.created_at IS NOT OLD.created_at
    OR NEW.deleted_at IS NOT OLD.deleted_at
)
BEGIN
    UPDATE users SET updated_at = now() WHERE user_id = NEW.user_id;
END;

-- Password reuse prevention (security.password.history_depth).
CREATE TABLE IF NOT EXISTS password_history (
    history_id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id                      INTEGER NOT NULL,
    password_hash                TEXT NOT NULL COLLATE NOCASE,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_pwhist_user FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX idx_pwhist_user ON password_history (user_id, created_at);

CREATE TABLE IF NOT EXISTS password_resets (
    reset_id                     INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id                      INTEGER NOT NULL,
    token_hash                   TEXT NOT NULL COLLATE NOCASE,  -- SHA-256 of the emitted token; the token itself is never stored
    expires_at                   TEXT NOT NULL,
    used_at                      TEXT,
    requested_ip                 TEXT COLLATE NOCASE,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_reset_user FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE UNIQUE INDEX uq_reset_token ON password_resets (token_hash);
CREATE INDEX idx_reset_user ON password_resets (user_id, expires_at);

-- ------------------------------------------------------- user sessions ----
-- Part 18: the server, not the browser, decides when a session dies.
CREATE TABLE IF NOT EXISTS user_sessions (
    session_id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id                      INTEGER NOT NULL,
    token_hash                   TEXT NOT NULL COLLATE NOCASE,  -- SHA-256 of a 256-bit CSPRNG token
    ip_address                   TEXT NOT NULL COLLATE NOCASE,
    ip_prefix                    TEXT COLLATE NOCASE,  -- /24 (v4) or /64 (v6) binding
    user_agent                   TEXT COLLATE NOCASE,
    user_agent_hash              TEXT COLLATE NOCASE,
    device_label                 TEXT COLLATE NOCASE,
    browser_label                TEXT COLLATE NOCASE,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    last_activity_at             TEXT NOT NULL,
    idle_expires_at              TEXT NOT NULL,
    absolute_expires_at          TEXT NOT NULL,
    terminated_at                TEXT,
    termination_reason           TEXT COLLATE NOCASE CHECK (termination_reason IN ('logout', 'idle_timeout', 'absolute_timeout', 'admin_terminated', 'password_changed', 'concurrent_limit', 'hijack_suspected', 'device_replaced')),
    CONSTRAINT fk_session_user FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE UNIQUE INDEX uq_session_token ON user_sessions (token_hash);
CREATE INDEX idx_session_user ON user_sessions (user_id, terminated_at);
CREATE INDEX idx_session_idle ON user_sessions (idle_expires_at);
CREATE INDEX idx_session_active ON user_sessions (terminated_at, idle_expires_at);

-- ------------------------------------------------------- login history ----
-- Permanent record. No delete path exists anywhere in the application.
CREATE TABLE IF NOT EXISTS login_history (
    login_id                     INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id                      INTEGER,  -- NULL when the username did not resolve
    username_try                 TEXT COLLATE NOCASE,
    ip_address                   TEXT NOT NULL COLLATE NOCASE,
    user_agent                   TEXT COLLATE NOCASE,
    browser                      TEXT COLLATE NOCASE,
    platform                     TEXT COLLATE NOCASE,
    status                       TEXT NOT NULL COLLATE NOCASE CHECK (status IN ('success', 'failed', 'locked', 'logout', 'idle_timeout', 'absolute_timeout', 'admin_terminated', 'blocked_ip', 'rate_limited')),
    detail                       TEXT COLLATE NOCASE,
    session_duration_sec         INTEGER,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_login_user FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE RESTRICT ON UPDATE CASCADE
);
CREATE INDEX idx_login_user ON login_history (user_id, created_at);
CREATE INDEX idx_login_status ON login_history (status, created_at);
CREATE INDEX idx_login_ip ON login_history (ip_address, created_at);

-- Login throttling state, keyed by username+IP so one attacker cannot lock out
-- an entire school by hammering a single known username from many hosts.
CREATE TABLE IF NOT EXISTS login_attempts (
    attempt_id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    identifier                   TEXT NOT NULL COLLATE NOCASE,
    ip_address                   TEXT NOT NULL COLLATE NOCASE,
    attempted_at                 TEXT NOT NULL
);
CREATE INDEX idx_attempt_lookup ON login_attempts (identifier, ip_address, attempted_at);

