-- ===========================================================================
-- L-SIAMS · 004 · Classrooms, IoT devices, API keys, heartbeats, device logs
-- ===========================================================================


CREATE TABLE IF NOT EXISTS classrooms (
    classroom_id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    room_number                  TEXT NOT NULL COLLATE NOCASE,
    building                     TEXT COLLATE NOCASE,
    floor                        TEXT COLLATE NOCASE,
    capacity                     INTEGER NOT NULL DEFAULT 50,
    location_note                TEXT COLLATE NOCASE,
    status                       TEXT NOT NULL DEFAULT 'active' COLLATE NOCASE CHECK (status IN ('active', 'inactive', 'maintenance')),
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    deleted_at                   TEXT
);
CREATE UNIQUE INDEX uq_classroom_room ON classrooms (room_number);
CREATE INDEX idx_classroom_status ON classrooms (status, deleted_at);

CREATE TRIGGER trg_classrooms_updated_at
AFTER UPDATE ON classrooms
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.classroom_id IS NOT OLD.classroom_id
    OR NEW.room_number IS NOT OLD.room_number
    OR NEW.building IS NOT OLD.building
    OR NEW.floor IS NOT OLD.floor
    OR NEW.capacity IS NOT OLD.capacity
    OR NEW.location_note IS NOT OLD.location_note
    OR NEW.status IS NOT OLD.status
    OR NEW.created_at IS NOT OLD.created_at
    OR NEW.deleted_at IS NOT OLD.deleted_at
)
BEGIN
    UPDATE classrooms SET updated_at = now() WHERE classroom_id = NEW.classroom_id;
END;

-- The table is rebuilt: a new one in the final shape, the rows copied across,
-- the old one dropped and the new one renamed into its place. Indexes and
-- triggers go with the old table, so they are recreated after.
CREATE TABLE sections__new (
    section_id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    section_code                 TEXT NOT NULL COLLATE NOCASE,
    section_name                 TEXT NOT NULL COLLATE NOCASE,
    grade_level_id               INTEGER NOT NULL,
    adviser_id                   INTEGER,
    strand                       TEXT COLLATE NOCASE,
    capacity                     INTEGER NOT NULL DEFAULT 45,
    enrolled_count               INTEGER NOT NULL DEFAULT 0,
    school_year_id               INTEGER NOT NULL,
    default_classroom_id         INTEGER,
    status                       TEXT NOT NULL DEFAULT 'active' COLLATE NOCASE CHECK (status IN ('active', 'inactive', 'archived')),
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    deleted_at                   TEXT,
    CONSTRAINT fk_section_adviser FOREIGN KEY (adviser_id) REFERENCES teachers (teacher_id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_section_classroom FOREIGN KEY (default_classroom_id) REFERENCES classrooms (classroom_id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_section_grade FOREIGN KEY (grade_level_id) REFERENCES grade_levels (grade_level_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_section_year FOREIGN KEY (school_year_id) REFERENCES school_years (school_year_id) ON DELETE RESTRICT ON UPDATE CASCADE
);
INSERT INTO sections__new (section_id, section_code, section_name, grade_level_id, adviser_id, strand, capacity, enrolled_count, school_year_id, default_classroom_id, status, created_at, updated_at, deleted_at)
    SELECT section_id, section_code, section_name, grade_level_id, adviser_id, strand, capacity, enrolled_count, school_year_id, default_classroom_id, status, created_at, updated_at, deleted_at FROM sections;
DROP TABLE sections;
ALTER TABLE sections__new RENAME TO sections;
CREATE INDEX fk_section_classroom ON sections (default_classroom_id);
CREATE INDEX fk_section_year ON sections (school_year_id);
CREATE INDEX idx_section_adviser ON sections (adviser_id);
CREATE INDEX idx_section_grade ON sections (grade_level_id);
CREATE INDEX idx_section_status ON sections (status, deleted_at);
CREATE UNIQUE INDEX uq_section_code_year ON sections (section_code, school_year_id);

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

-- ------------------------------------------------------------- devices ----
CREATE TABLE IF NOT EXISTS devices (
    id                           INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id                    TEXT NOT NULL COLLATE NOCASE,  -- Public identifier: DEV-{YYYY}-{NNNN}
    device_name                  TEXT NOT NULL COLLATE NOCASE,
    mac_address                  TEXT NOT NULL COLLATE NOCASE,  -- Normalised uppercase colon-separated
    serial_number                TEXT COLLATE NOCASE,
    classroom_id                 INTEGER,
    -- Part 16.8: one terminal per room is the default deployment; entry/exit
    -- pairs are supported without any schema change.
    device_role                  TEXT NOT NULL DEFAULT 'both' COLLATE NOCASE CHECK (device_role IN ('entry', 'exit', 'both')),
    firmware_version             TEXT NOT NULL DEFAULT '0.0.0' COLLATE NOCASE,
    ip_address                   TEXT COLLATE NOCASE,
    ip_allowlist                 TEXT COLLATE NOCASE,  -- Optional comma-separated CIDR restriction
    wifi_ssid                    TEXT COLLATE NOCASE,
    wifi_signal                  INTEGER,
    timezone                     TEXT NOT NULL DEFAULT 'Asia/Manila' COLLATE NOCASE,
    heartbeat_interval_sec       INTEGER NOT NULL DEFAULT 30,
    sync_interval_sec            INTEGER NOT NULL DEFAULT 60,
    offline_queue_limit          INTEGER NOT NULL DEFAULT 500,
    queue_depth                  INTEGER NOT NULL DEFAULT 0,
    uptime_seconds               INTEGER NOT NULL DEFAULT 0,
    battery_percent              INTEGER,
    status                       TEXT NOT NULL DEFAULT 'pending' COLLATE NOCASE CHECK (status IN ('pending', 'active', 'offline', 'disabled', 'suspended', 'decommissioned')),
    claim_status                 TEXT NOT NULL DEFAULT 'unclaimed' COLLATE NOCASE CHECK (claim_status IN ('unclaimed', 'claimed', 'expired')),
    claimed_at                   TEXT,
    last_heartbeat_at            TEXT,
    last_seen_ip                 TEXT COLLATE NOCASE,
    locked_until                 TEXT,  -- Fingerprint failure lockout
    registered_by                INTEGER,
    location_note                TEXT COLLATE NOCASE,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    deleted_at                   TEXT,
    -- One live device per classroom per role: see uq_one_device_per_classroom_role.
    live_slot                    TEXT GENERATED ALWAYS AS (CASE WHEN status IN ('pending','active','offline','suspended') AND deleted_at IS NULL THEN CAST(classroom_id AS TEXT) || ':' || device_role ELSE NULL END) STORED,
    -- RESTRICT on both actions, for the same reason as rfid_cards.student_id:
    -- live_slot below is a generated column over this one, and MariaDB will not
    -- create it if the engine might rewrite the column behind its back. Neither
    -- action was reachable anyway — classroom_id is a surrogate key that is never
    -- updated, and classrooms are soft-deleted rather than removed. RESTRICT is
    -- also the safer failure: a hard delete that would orphan a terminal is
    -- refused rather than silently unassigning it.
    CONSTRAINT fk_device_classroom FOREIGN KEY (classroom_id) REFERENCES classrooms (classroom_id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_device_registrant FOREIGN KEY (registered_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE UNIQUE INDEX uq_device_public_id ON devices (device_id);
CREATE UNIQUE INDEX uq_device_mac ON devices (mac_address);
CREATE INDEX idx_device_classroom ON devices (classroom_id);
CREATE INDEX idx_device_status ON devices (status, last_heartbeat_at);
CREATE INDEX fk_device_registrant ON devices (registered_by);

CREATE TRIGGER trg_devices_updated_at
AFTER UPDATE ON devices
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.id IS NOT OLD.id
    OR NEW.device_id IS NOT OLD.device_id
    OR NEW.device_name IS NOT OLD.device_name
    OR NEW.mac_address IS NOT OLD.mac_address
    OR NEW.serial_number IS NOT OLD.serial_number
    OR NEW.classroom_id IS NOT OLD.classroom_id
    OR NEW.device_role IS NOT OLD.device_role
    OR NEW.firmware_version IS NOT OLD.firmware_version
    OR NEW.ip_address IS NOT OLD.ip_address
    OR NEW.ip_allowlist IS NOT OLD.ip_allowlist
    OR NEW.wifi_ssid IS NOT OLD.wifi_ssid
    OR NEW.wifi_signal IS NOT OLD.wifi_signal
    OR NEW.timezone IS NOT OLD.timezone
    OR NEW.heartbeat_interval_sec IS NOT OLD.heartbeat_interval_sec
    OR NEW.sync_interval_sec IS NOT OLD.sync_interval_sec
    OR NEW.offline_queue_limit IS NOT OLD.offline_queue_limit
    OR NEW.queue_depth IS NOT OLD.queue_depth
    OR NEW.uptime_seconds IS NOT OLD.uptime_seconds
    OR NEW.battery_percent IS NOT OLD.battery_percent
    OR NEW.status IS NOT OLD.status
    OR NEW.claim_status IS NOT OLD.claim_status
    OR NEW.claimed_at IS NOT OLD.claimed_at
    OR NEW.last_heartbeat_at IS NOT OLD.last_heartbeat_at
    OR NEW.last_seen_ip IS NOT OLD.last_seen_ip
    OR NEW.locked_until IS NOT OLD.locked_until
    OR NEW.registered_by IS NOT OLD.registered_by
    OR NEW.location_note IS NOT OLD.location_note
    OR NEW.created_at IS NOT OLD.created_at
    OR NEW.deleted_at IS NOT OLD.deleted_at
)
BEGIN
    UPDATE devices SET updated_at = now() WHERE id = NEW.id;
END;

-- One live device per classroom per role. `live_slot` is NULL for anything not
-- currently serving (disabled, decommissioned, deleted), and NULLs do not
-- collide — so retired hardware never blocks a replacement, while two active
-- terminals in the same role in one room is impossible. The column itself is
-- declared on devices above: SQLite cannot add a stored generated column later.
CREATE UNIQUE INDEX IF NOT EXISTS uq_one_device_per_classroom_role ON devices (live_slot);

-- ------------------------------------------------------------ API keys ----
-- Part 19.4. key_id is a public lookup handle stored in the clear; the secret
-- is never stored at all, only its peppered SHA-256. The HMAC secret must be
-- recoverable to verify signatures, so it is encrypted (AES-256-GCM), not hashed.
CREATE TABLE IF NOT EXISTS api_keys (
    api_key_id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    key_id                       TEXT NOT NULL COLLATE NOCASE,  -- Public: lsk_XXXXXXXXXXX
    device_row_id                INTEGER,
    user_id                      INTEGER,  -- User-scoped tokens (Part 19.2, default disabled)
    secret_hash                  TEXT NOT NULL COLLATE NOCASE,  -- SHA-256(secret || server pepper)
    secret_last_four             TEXT NOT NULL COLLATE NOCASE,  -- Display only
    hmac_secret_encrypted        BLOB NOT NULL,  -- AES-256-GCM, key held in APP_KEY
    scope                        TEXT NOT NULL DEFAULT 'device' COLLATE NOCASE,
    status                       TEXT NOT NULL DEFAULT 'active' COLLATE NOCASE CHECK (status IN ('active', 'rotating', 'revoked', 'expired', 'suspended')),
    rotated_from                 INTEGER,
    grace_expires_at             TEXT,  -- Old key stays valid until this instant during rotation
    expires_at                   TEXT,
    revoked_at                   TEXT,
    revoked_by                   INTEGER,
    revoke_reason                TEXT COLLATE NOCASE,
    last_used_at                 TEXT,
    last_used_ip                 TEXT COLLATE NOCASE,
    use_count                    INTEGER NOT NULL DEFAULT 0,
    consecutive_signature_failures INTEGER NOT NULL DEFAULT 0,
    created_by                   INTEGER,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_apikey_device FOREIGN KEY (device_row_id) REFERENCES devices (id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_apikey_user FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_apikey_rotated FOREIGN KEY (rotated_from) REFERENCES api_keys (api_key_id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_apikey_creator FOREIGN KEY (created_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_apikey_revoker FOREIGN KEY (revoked_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE UNIQUE INDEX uq_api_key_id ON api_keys (key_id);
CREATE INDEX idx_apikey_device ON api_keys (device_row_id, status);
CREATE INDEX idx_apikey_user ON api_keys (user_id, status);
CREATE INDEX idx_apikey_status ON api_keys (status, expires_at);
CREATE INDEX fk_apikey_rotated ON api_keys (rotated_from);
CREATE INDEX fk_apikey_creator ON api_keys (created_by);
CREATE INDEX fk_apikey_revoker ON api_keys (revoked_by);

CREATE TRIGGER trg_api_keys_updated_at
AFTER UPDATE ON api_keys
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.api_key_id IS NOT OLD.api_key_id
    OR NEW.key_id IS NOT OLD.key_id
    OR NEW.device_row_id IS NOT OLD.device_row_id
    OR NEW.user_id IS NOT OLD.user_id
    OR NEW.secret_hash IS NOT OLD.secret_hash
    OR NEW.secret_last_four IS NOT OLD.secret_last_four
    OR NEW.hmac_secret_encrypted IS NOT OLD.hmac_secret_encrypted
    OR NEW.scope IS NOT OLD.scope
    OR NEW.status IS NOT OLD.status
    OR NEW.rotated_from IS NOT OLD.rotated_from
    OR NEW.grace_expires_at IS NOT OLD.grace_expires_at
    OR NEW.expires_at IS NOT OLD.expires_at
    OR NEW.revoked_at IS NOT OLD.revoked_at
    OR NEW.revoked_by IS NOT OLD.revoked_by
    OR NEW.revoke_reason IS NOT OLD.revoke_reason
    OR NEW.last_used_at IS NOT OLD.last_used_at
    OR NEW.last_used_ip IS NOT OLD.last_used_ip
    OR NEW.use_count IS NOT OLD.use_count
    OR NEW.consecutive_signature_failures IS NOT OLD.consecutive_signature_failures
    OR NEW.created_by IS NOT OLD.created_by
    OR NEW.created_at IS NOT OLD.created_at
)
BEGIN
    UPDATE api_keys SET updated_at = now() WHERE api_key_id = NEW.api_key_id;
END;

-- Keys are never deleted from history — only their status changes (Part 19.6).
CREATE TABLE IF NOT EXISTS api_key_history (
    history_id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    api_key_id                   INTEGER NOT NULL,
    device_row_id                INTEGER,
    event                        TEXT NOT NULL COLLATE NOCASE CHECK (event IN ('generated', 'rotated', 'revoked', 'expired', 'suspended', 'resumed', 'ip_anomaly', 'auto_revoked')),
    reason                       TEXT COLLATE NOCASE,
    performed_by                 INTEGER,
    ip_address                   TEXT COLLATE NOCASE,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_akh_key FOREIGN KEY (api_key_id) REFERENCES api_keys (api_key_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_akh_device FOREIGN KEY (device_row_id) REFERENCES devices (id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_akh_user FOREIGN KEY (performed_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE INDEX idx_akh_key ON api_key_history (api_key_id, created_at);
CREATE INDEX idx_akh_device ON api_key_history (device_row_id, created_at);
CREATE INDEX fk_akh_user ON api_key_history (performed_by);

-- Single-use first-boot credential activation (Part 19.5).
CREATE TABLE IF NOT EXISTS device_claims (
    claim_id                     INTEGER PRIMARY KEY AUTOINCREMENT,
    device_row_id                INTEGER NOT NULL,
    claim_token_hash             TEXT NOT NULL COLLATE NOCASE,
    expires_at                   TEXT NOT NULL,
    claimed_at                   TEXT,
    claimed_ip                   TEXT COLLATE NOCASE,
    claimed_mac                  TEXT COLLATE NOCASE,
    created_by                   INTEGER,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_claim_device FOREIGN KEY (device_row_id) REFERENCES devices (id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_claim_user FOREIGN KEY (created_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE UNIQUE INDEX uq_claim_token ON device_claims (claim_token_hash);
CREATE INDEX idx_claim_device ON device_claims (device_row_id, expires_at);
CREATE INDEX fk_claim_user ON device_claims (created_by);

-- ---------------------------------------------------------- heartbeats ----
CREATE TABLE IF NOT EXISTS device_heartbeats (
    heartbeat_id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    device_row_id                INTEGER NOT NULL,
    firmware_version             TEXT COLLATE NOCASE,
    wifi_signal                  INTEGER,
    queue_depth                  INTEGER NOT NULL DEFAULT 0,
    uptime_seconds               INTEGER NOT NULL DEFAULT 0,
    battery_percent              INTEGER,
    free_heap_bytes              INTEGER,
    active_session_id            INTEGER,
    ip_address                   TEXT COLLATE NOCASE,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_heartbeat_device FOREIGN KEY (device_row_id) REFERENCES devices (id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX idx_heartbeat_device ON device_heartbeats (device_row_id, created_at);
-- 90-day retention sweep
CREATE INDEX idx_heartbeat_created ON device_heartbeats (created_at);

CREATE TABLE IF NOT EXISTS device_logs (
    log_id                       INTEGER PRIMARY KEY AUTOINCREMENT,
    device_row_id                INTEGER,
    device_id_text               TEXT COLLATE NOCASE,  -- Preserved even when the device row is unknown
    event                        TEXT NOT NULL COLLATE NOCASE CHECK (event IN ('boot', 'shutdown', 'restart', 'wifi_connected', 'wifi_lost', 'sync_started', 'sync_completed', 'sync_failed', 'auth_success', 'auth_failed', 'claim', 'queue_warning', 'queue_full', 'error', 'firmware_update', 'offline', 'online', 'time_sync', 'locked', 'unlocked')),
    severity                     TEXT NOT NULL DEFAULT 'info' COLLATE NOCASE CHECK (severity IN ('info', 'warning', 'error', 'critical')),
    message                      TEXT COLLATE NOCASE,
    context_json                 TEXT CHECK (context_json IS NULL OR json_valid(context_json)),
    ip_address                   TEXT COLLATE NOCASE,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_devlog_device FOREIGN KEY (device_row_id) REFERENCES devices (id) ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE INDEX idx_devlog_device ON device_logs (device_row_id, created_at);
CREATE INDEX idx_devlog_event ON device_logs (event, created_at);

-- ------------------------------------ replay protection & idempotency ----
-- Part 6: a nonce may be used exactly once per device. The unique key is the
-- enforcement; the application never has to "check then insert" and race.
CREATE TABLE IF NOT EXISTS device_nonces (
    nonce_id                     INTEGER PRIMARY KEY AUTOINCREMENT,
    device_row_id                INTEGER NOT NULL,
    nonce                        TEXT NOT NULL COLLATE NOCASE,
    used_at                      TEXT NOT NULL,
    CONSTRAINT fk_nonce_device FOREIGN KEY (device_row_id) REFERENCES devices (id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE UNIQUE INDEX uq_device_nonce ON device_nonces (device_row_id, nonce);
-- 24-hour retention sweep
CREATE INDEX idx_nonce_used ON device_nonces (used_at);

-- Part 17.3: a repeated request_id returns the stored response verbatim, which
-- is what makes offline-queue retries after a network timeout safe.
CREATE TABLE IF NOT EXISTS processed_requests (
    processed_id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    request_id                   TEXT NOT NULL COLLATE NOCASE,
    device_row_id                INTEGER,
    endpoint                     TEXT NOT NULL COLLATE NOCASE,
    response_code                INTEGER NOT NULL,
    response_body                TEXT NOT NULL CHECK (response_body IS NULL OR json_valid(response_body)),
    created_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_processed_device FOREIGN KEY (device_row_id) REFERENCES devices (id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE UNIQUE INDEX uq_request_id ON processed_requests (request_id);
CREATE INDEX idx_processed_created ON processed_requests (created_at);
CREATE INDEX fk_processed_device ON processed_requests (device_row_id);

-- Generic token-bucket state for rate limiting (devices, logins, API users).
CREATE TABLE IF NOT EXISTS rate_limits (
    bucket_key                   TEXT PRIMARY KEY NOT NULL COLLATE NOCASE,
    hits                         INTEGER NOT NULL DEFAULT 0,
    window_start                 TEXT NOT NULL,
    blocked_until                TEXT,
    updated_at                   TEXT NOT NULL DEFAULT (now())
);
CREATE INDEX idx_ratelimit_window ON rate_limits (window_start);

CREATE TRIGGER trg_rate_limits_updated_at
AFTER UPDATE ON rate_limits
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.bucket_key IS NOT OLD.bucket_key
    OR NEW.hits IS NOT OLD.hits
    OR NEW.window_start IS NOT OLD.window_start
    OR NEW.blocked_until IS NOT OLD.blocked_until
)
BEGIN
    UPDATE rate_limits SET updated_at = now() WHERE bucket_key = NEW.bucket_key;
END;

