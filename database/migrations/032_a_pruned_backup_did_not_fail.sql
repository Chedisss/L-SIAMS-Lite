-- ---------------------------------------------------------------------------
-- 032: a pruned backup did not fail
--
-- A backup taken successfully and later removed by the retention policy was
-- recorded as status = 'failed', with the reason in error_message. It did not
-- fail — it did exactly what the policy asked of it.
--
-- The effect is on the Backups page, where every pruned archive shows in red
-- alongside genuine failures. A school that keeps 30 backups and takes one a
-- day sees a growing list of "failed" rows for a retention policy that is
-- working perfectly, which is the fastest way to stop somebody trusting their
-- backups — and the point of a backup system is that it is trusted.
-- ---------------------------------------------------------------------------

-- An enum is a CHECK constraint in SQLite, and a constraint cannot be changed
-- in place, so adding 'pruned' rebuilds the table.
-- The table is rebuilt: a new one in the final shape, the rows copied across,
-- the old one dropped and the new one renamed into its place. Indexes and
-- triggers go with the old table, so they are recreated after.
CREATE TABLE backups__new (
    backup_id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    backup_name                  TEXT NOT NULL COLLATE NOCASE,
    file_path                    TEXT NOT NULL COLLATE NOCASE,
    file_size                    INTEGER NOT NULL DEFAULT 0,
    checksum                     TEXT COLLATE NOCASE,
    is_encrypted                 INTEGER NOT NULL DEFAULT 1,
    is_compressed                INTEGER NOT NULL DEFAULT 1,
    trigger_type                 TEXT NOT NULL DEFAULT 'manual' COLLATE NOCASE CHECK (trigger_type IN ('manual', 'scheduled')),
    table_count                  INTEGER NOT NULL DEFAULT 0,
    status                       TEXT NOT NULL DEFAULT 'running' COLLATE NOCASE CHECK (status IN ('running', 'completed', 'failed', 'verified', 'restored', 'pruned')),
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
INSERT INTO backups__new (backup_id, backup_name, file_path, file_size, checksum, is_encrypted, is_compressed, trigger_type, table_count, status, error_message, duration_seconds, created_by, created_at, verified_at, restored_at, restored_by)
    SELECT backup_id, backup_name, file_path, file_size, checksum, is_encrypted, is_compressed, trigger_type, table_count, status, error_message, duration_seconds, created_by, created_at, verified_at, restored_at, restored_by FROM backups;
DROP TABLE backups;
ALTER TABLE backups__new RENAME TO backups;
CREATE INDEX fk_backup_creator ON backups (created_by);
CREATE INDEX fk_backup_restorer ON backups (restored_by);
CREATE INDEX idx_backup_status ON backups (status, created_at);

UPDATE backups
   SET status = 'pruned', error_message = 'Archive removed by the retention policy.'
 WHERE status = 'failed'
   AND error_message = 'Archive pruned by the retention policy.';

