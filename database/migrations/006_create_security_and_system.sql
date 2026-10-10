-- ===========================================================================
-- L-SIAMS · 006 · Audit, security, realtime, notifications, settings, backups
-- ===========================================================================
-- audit_logs, security_logs and login_history are append-only by policy. There
-- is no UPDATE or DELETE path to them anywhere in the application, and the
-- application database user is granted only INSERT and SELECT on them
-- (see docs/DEPLOYMENT.md, "Database privileges").
-- ===========================================================================


CREATE TABLE IF NOT EXISTS audit_logs (
    audit_id                     INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id                      INTEGER,
    actor_label                  TEXT COLLATE NOCASE,  -- Snapshot of who acted, valid even if the user row changes
    role_name                    TEXT COLLATE NOCASE,
    action                       TEXT NOT NULL COLLATE NOCASE,  -- e.g. STUDENT_SECTION_TRANSFER
    module                       TEXT NOT NULL COLLATE NOCASE,
    record_type                  TEXT COLLATE NOCASE,
    record_id                    TEXT COLLATE NOCASE,
    old_value                    TEXT CHECK (old_value IS NULL OR json_valid(old_value)),
    new_value                    TEXT CHECK (new_value IS NULL OR json_valid(new_value)),
    description                  TEXT COLLATE NOCASE,
    ip_address                   TEXT COLLATE NOCASE,
    user_agent                   TEXT COLLATE NOCASE,
    device_label                 TEXT COLLATE NOCASE,
    session_id                   INTEGER,
    result                       TEXT NOT NULL DEFAULT 'success' COLLATE NOCASE CHECK (result IN ('success', 'failure')),
    created_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_audit_user FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE RESTRICT ON UPDATE CASCADE
);
CREATE INDEX idx_audit_user ON audit_logs (user_id, created_at);
CREATE INDEX idx_audit_action ON audit_logs (action, created_at);
CREATE INDEX idx_audit_module ON audit_logs (module, created_at);
CREATE INDEX idx_audit_record ON audit_logs (record_type, record_id);
CREATE INDEX idx_audit_created ON audit_logs (created_at);

CREATE TABLE IF NOT EXISTS security_logs (
    security_id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    event                        TEXT NOT NULL COLLATE NOCASE,  -- REPLAY_DETECTED, SIGNATURE_INVALID, …
    severity                     TEXT NOT NULL DEFAULT 'low' COLLATE NOCASE CHECK (severity IN ('low', 'medium', 'high', 'critical')),
    description                  TEXT NOT NULL COLLATE NOCASE,
    context_json                 TEXT CHECK (context_json IS NULL OR json_valid(context_json)),
    source_ip                    TEXT COLLATE NOCASE,
    user_id                      INTEGER,
    device_row_id                INTEGER,
    device_id_text               TEXT COLLATE NOCASE,
    endpoint                     TEXT COLLATE NOCASE,
    http_method                  TEXT COLLATE NOCASE,
    user_agent                   TEXT COLLATE NOCASE,
    resolution_status            TEXT NOT NULL DEFAULT 'open' COLLATE NOCASE CHECK (resolution_status IN ('open', 'investigating', 'resolved', 'false_positive')),
    resolved_by                  INTEGER,
    resolved_at                  TEXT,
    admin_notes                  TEXT COLLATE NOCASE,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_seclog_user FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_seclog_device FOREIGN KEY (device_row_id) REFERENCES devices (id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_seclog_admin FOREIGN KEY (resolved_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE INDEX idx_seclog_event ON security_logs (event, created_at);
CREATE INDEX idx_seclog_severity ON security_logs (severity, created_at);
CREATE INDEX idx_seclog_ip ON security_logs (source_ip, created_at);
CREATE INDEX idx_seclog_status ON security_logs (resolution_status, created_at);
CREATE INDEX idx_seclog_created ON security_logs (created_at);
CREATE INDEX fk_seclog_user ON security_logs (user_id);
CREATE INDEX fk_seclog_device ON security_logs (device_row_id);
CREATE INDEX fk_seclog_admin ON security_logs (resolved_by);

CREATE TABLE IF NOT EXISTS blocked_ips (
    block_id                     INTEGER PRIMARY KEY AUTOINCREMENT,
    ip_address                   TEXT NOT NULL COLLATE NOCASE,
    reason                       TEXT NOT NULL COLLATE NOCASE,
    blocked_by                   INTEGER,
    auto_blocked                 INTEGER NOT NULL DEFAULT 0,
    expires_at                   TEXT,  -- NULL = permanent
    status                       TEXT NOT NULL DEFAULT 'active' COLLATE NOCASE CHECK (status IN ('active', 'lifted')),
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_blockip_user FOREIGN KEY (blocked_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE UNIQUE INDEX uq_blocked_ip ON blocked_ips (ip_address);
CREATE INDEX idx_blocked_status ON blocked_ips (status, expires_at);
CREATE INDEX fk_blockip_user ON blocked_ips (blocked_by);

CREATE TRIGGER trg_blocked_ips_updated_at
AFTER UPDATE ON blocked_ips
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.block_id IS NOT OLD.block_id
    OR NEW.ip_address IS NOT OLD.ip_address
    OR NEW.reason IS NOT OLD.reason
    OR NEW.blocked_by IS NOT OLD.blocked_by
    OR NEW.auto_blocked IS NOT OLD.auto_blocked
    OR NEW.expires_at IS NOT OLD.expires_at
    OR NEW.status IS NOT OLD.status
    OR NEW.created_at IS NOT OLD.created_at
)
BEGIN
    UPDATE blocked_ips SET updated_at = now() WHERE block_id = NEW.block_id;
END;

CREATE TABLE IF NOT EXISTS blocked_devices (
    block_id                     INTEGER PRIMARY KEY AUTOINCREMENT,
    device_row_id                INTEGER,
    device_id_text               TEXT COLLATE NOCASE,
    mac_address                  TEXT COLLATE NOCASE,
    reason                       TEXT NOT NULL COLLATE NOCASE,
    blocked_by                   INTEGER,
    auto_blocked                 INTEGER NOT NULL DEFAULT 0,
    status                       TEXT NOT NULL DEFAULT 'active' COLLATE NOCASE CHECK (status IN ('active', 'lifted')),
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_blockdev_device FOREIGN KEY (device_row_id) REFERENCES devices (id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_blockdev_user FOREIGN KEY (blocked_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE INDEX idx_blockdev_device ON blocked_devices (device_row_id, status);
CREATE INDEX idx_blockdev_text ON blocked_devices (device_id_text, status);
CREATE INDEX fk_blockdev_user ON blocked_devices (blocked_by);

CREATE TRIGGER trg_blocked_devices_updated_at
AFTER UPDATE ON blocked_devices
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.block_id IS NOT OLD.block_id
    OR NEW.device_row_id IS NOT OLD.device_row_id
    OR NEW.device_id_text IS NOT OLD.device_id_text
    OR NEW.mac_address IS NOT OLD.mac_address
    OR NEW.reason IS NOT OLD.reason
    OR NEW.blocked_by IS NOT OLD.blocked_by
    OR NEW.auto_blocked IS NOT OLD.auto_blocked
    OR NEW.status IS NOT OLD.status
    OR NEW.created_at IS NOT OLD.created_at
)
BEGIN
    UPDATE blocked_devices SET updated_at = now() WHERE block_id = NEW.block_id;
END;

-- --------------------------------------------------- realtime transport ----
-- Part 17.7: the replay buffer. `sequence` is a monotonically increasing
-- per-channel counter, so a client that reconnects can ask for everything after
-- the last sequence it saw and lose nothing.
CREATE TABLE IF NOT EXISTS realtime_events (
    event_id                     INTEGER PRIMARY KEY AUTOINCREMENT,
    channel                      TEXT NOT NULL COLLATE NOCASE,
    sequence                     INTEGER NOT NULL,
    event_type                   TEXT NOT NULL COLLATE NOCASE,
    payload                      TEXT NOT NULL CHECK (payload IS NULL OR json_valid(payload)),
    created_at                   TEXT NOT NULL
);
CREATE UNIQUE INDEX uq_channel_sequence ON realtime_events (channel, sequence);
CREATE INDEX idx_rt_channel_created ON realtime_events (channel, created_at);
-- 48-hour retention sweep
CREATE INDEX idx_rt_created ON realtime_events (created_at);
CREATE INDEX idx_rt_id ON realtime_events (event_id);

CREATE TABLE IF NOT EXISTS realtime_channel_cursors (
    channel                      TEXT PRIMARY KEY NOT NULL COLLATE NOCASE,
    last_sequence                INTEGER NOT NULL DEFAULT 0,
    updated_at                   TEXT NOT NULL DEFAULT (now())
);

CREATE TRIGGER trg_realtime_channel_cursors_updated_at
AFTER UPDATE ON realtime_channel_cursors
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.channel IS NOT OLD.channel
    OR NEW.last_sequence IS NOT OLD.last_sequence
)
BEGIN
    UPDATE realtime_channel_cursors SET updated_at = now() WHERE channel = NEW.channel;
END;

CREATE TABLE IF NOT EXISTS realtime_tickets (
    ticket_id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    ticket_hash                  TEXT NOT NULL COLLATE NOCASE,
    user_id                      INTEGER NOT NULL,
    session_id                   INTEGER NOT NULL,
    channels                     TEXT NOT NULL CHECK (channels IS NULL OR json_valid(channels)),
    expires_at                   TEXT NOT NULL,
    consumed_at                  TEXT,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_ticket_user FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_ticket_session FOREIGN KEY (session_id) REFERENCES user_sessions (session_id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE UNIQUE INDEX uq_ticket_hash ON realtime_tickets (ticket_hash);
CREATE INDEX idx_ticket_expiry ON realtime_tickets (expires_at);
CREATE INDEX fk_ticket_user ON realtime_tickets (user_id);
CREATE INDEX fk_ticket_session ON realtime_tickets (session_id);

-- -------------------------------------------------------- notifications ----
CREATE TABLE IF NOT EXISTS notifications (
    notification_id              INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id                      INTEGER,  -- NULL = broadcast to every administrator
    role_target                  TEXT COLLATE NOCASE,
    category                     TEXT NOT NULL COLLATE NOCASE,
    title                        TEXT NOT NULL COLLATE NOCASE,
    message                      TEXT NOT NULL COLLATE NOCASE,
    link                         TEXT COLLATE NOCASE,
    priority                     TEXT NOT NULL DEFAULT 'normal' COLLATE NOCASE CHECK (priority IN ('low', 'normal', 'high', 'critical')),
    is_read                      INTEGER NOT NULL DEFAULT 0,
    read_at                      TEXT,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_notif_user FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX idx_notif_user ON notifications (user_id, is_read, created_at);
CREATE INDEX idx_notif_role ON notifications (role_target, is_read, created_at);
-- 180-day retention sweep
CREATE INDEX idx_notif_created ON notifications (created_at);

-- ------------------------------------------------------------- settings ----
CREATE TABLE IF NOT EXISTS settings (
    setting_key                  TEXT PRIMARY KEY NOT NULL COLLATE NOCASE,
    setting_value                TEXT COLLATE NOCASE,
    value_type                   TEXT NOT NULL DEFAULT 'string' COLLATE NOCASE CHECK (value_type IN ('string', 'int', 'float', 'bool', 'json')),
    group_name                   TEXT NOT NULL DEFAULT 'general' COLLATE NOCASE,
    label                        TEXT NOT NULL COLLATE NOCASE,
    description                  TEXT COLLATE NOCASE,
    -- Sensitive settings require administrator re-authentication before they can
    -- be changed (Part 2 business rules).
    is_sensitive                 INTEGER NOT NULL DEFAULT 0,
    min_value                    TEXT COLLATE NOCASE,
    max_value                    TEXT COLLATE NOCASE,
    updated_by                   INTEGER,
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_settings_user FOREIGN KEY (updated_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE INDEX idx_settings_group ON settings (group_name);
CREATE INDEX fk_settings_user ON settings (updated_by);

CREATE TRIGGER trg_settings_updated_at
AFTER UPDATE ON settings
FOR EACH ROW WHEN NEW.updated_at IS OLD.updated_at AND (
    NEW.setting_key IS NOT OLD.setting_key
    OR NEW.setting_value IS NOT OLD.setting_value
    OR NEW.value_type IS NOT OLD.value_type
    OR NEW.group_name IS NOT OLD.group_name
    OR NEW.label IS NOT OLD.label
    OR NEW.description IS NOT OLD.description
    OR NEW.is_sensitive IS NOT OLD.is_sensitive
    OR NEW.min_value IS NOT OLD.min_value
    OR NEW.max_value IS NOT OLD.max_value
    OR NEW.updated_by IS NOT OLD.updated_by
)
BEGIN
    UPDATE settings SET updated_at = now() WHERE setting_key = NEW.setting_key;
END;

-- ------------------------------------------------- reports and backups ----
CREATE TABLE IF NOT EXISTS generated_reports (
    report_id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    report_name                  TEXT NOT NULL COLLATE NOCASE,
    report_type                  TEXT NOT NULL COLLATE NOCASE,
    format                       TEXT NOT NULL COLLATE NOCASE CHECK (format IN ('pdf', 'xlsx', 'csv')),
    parameters                   TEXT CHECK (parameters IS NULL OR json_valid(parameters)),
    file_path                    TEXT NOT NULL COLLATE NOCASE,  -- Under storage/reports — outside the web root
    file_size                    INTEGER NOT NULL DEFAULT 0,
    checksum                     TEXT COLLATE NOCASE,
    row_count                    INTEGER NOT NULL DEFAULT 0,
    generated_by                 INTEGER NOT NULL,
    expires_at                   TEXT,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    CONSTRAINT fk_report_user FOREIGN KEY (generated_by) REFERENCES users (user_id) ON DELETE RESTRICT ON UPDATE CASCADE
);
CREATE INDEX idx_report_user ON generated_reports (generated_by, created_at);
CREATE INDEX idx_report_type ON generated_reports (report_type, created_at);

CREATE TABLE IF NOT EXISTS backups (
    backup_id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    backup_name                  TEXT NOT NULL COLLATE NOCASE,
    file_path                    TEXT NOT NULL COLLATE NOCASE,
    file_size                    INTEGER NOT NULL DEFAULT 0,
    checksum                     TEXT COLLATE NOCASE,  -- SHA-256 for integrity verification
    is_encrypted                 INTEGER NOT NULL DEFAULT 1,
    is_compressed                INTEGER NOT NULL DEFAULT 1,
    trigger_type                 TEXT NOT NULL DEFAULT 'manual' COLLATE NOCASE CHECK (trigger_type IN ('manual', 'scheduled')),
    table_count                  INTEGER NOT NULL DEFAULT 0,
    status                       TEXT NOT NULL DEFAULT 'running' COLLATE NOCASE CHECK (status IN ('running', 'completed', 'failed', 'verified', 'restored')),
    error_message                TEXT COLLATE NOCASE,
    duration_seconds             INTEGER,
    created_by                   INTEGER,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    verified_at                  TEXT,
    restored_at                  TEXT,
    restored_by                  INTEGER,
    CONSTRAINT fk_backup_creator FOREIGN KEY (created_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_backup_restorer FOREIGN KEY (restored_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE INDEX idx_backup_status ON backups (status, created_at);
CREATE INDEX fk_backup_creator ON backups (created_by);
CREATE INDEX fk_backup_restorer ON backups (restored_by);

-- Migration bookkeeping.
CREATE TABLE IF NOT EXISTS schema_migrations (
    migration                    TEXT PRIMARY KEY NOT NULL COLLATE NOCASE,
    batch                        INTEGER NOT NULL,
    checksum                     TEXT NOT NULL COLLATE NOCASE,
    applied_at                   TEXT NOT NULL DEFAULT (now())
);

