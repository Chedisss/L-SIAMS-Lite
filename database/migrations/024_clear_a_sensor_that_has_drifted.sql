-- ===========================================================================
-- L-SIAMS · 024 · Let an administrator wipe a sensor that has drifted
-- ===========================================================================
-- Migration 015 gave terminals a way to report how many templates their sensor
-- holds, and the Fingerprints page has been able to say "this sensor holds four
-- but one is recorded" ever since. It has also been recommending a fix nobody
-- could carry out: "clearing the sensor and enrolling everybody again is the
-- reliable fix", with no button anywhere that clears a sensor.
--
-- Orphans are not cosmetic. A slot holding a template the server has no record
-- of is still matchable by the reader, and a scan that lands on one is refused
-- as unrecognised — a genuinely enrolled teacher, turned away for matching the
-- wrong copy of their own finger. The automatic cleanup only reaches slots left
-- by abandoned enrolment requests; anything older, or written by a build that
-- allocated a fresh slot on every re-enrolment, is invisible to it.
--
-- The server cannot reach into a sensor's flash, so this is a request the
-- terminal collects and acts on, in the same shape as everything else here:
-- the terminal polls, wipes, and confirms. One column carries the request and
-- one carries the acknowledgement, so a wipe that was asked for but never
-- performed is distinguishable from one that completed — a terminal that is
-- switched off must not look like a terminal that has finished.
--
-- Wiping is safe in a way it would not have been before migration 018. Every
-- template the server holds is queued straight back onto the sensor and
-- rewritten within a couple of minutes. The exception is a template that
-- exists ONLY in the sensor being wiped — an enrolment predating template
-- storage — which is destroyed permanently, so the application refuses the
-- request unless the administrator has been shown the count and accepted it.
-- ===========================================================================


-- The wipe columns and fk_devices_wipe_requested_by arrive in one rebuild:
-- SQLite cannot add a named foreign key to an existing table.
-- The table is rebuilt: a new one in the final shape, the rows copied across,
-- the old one dropped and the new one renamed into its place. Indexes and
-- triggers go with the old table, so they are recreated after.
CREATE TABLE devices__new (
    id                           INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id                    TEXT NOT NULL COLLATE NOCASE,
    device_name                  TEXT NOT NULL COLLATE NOCASE,
    mac_address                  TEXT NOT NULL COLLATE NOCASE,
    serial_number                TEXT COLLATE NOCASE,
    classroom_id                 INTEGER,
    device_role                  TEXT NOT NULL DEFAULT 'both' COLLATE NOCASE CHECK (device_role IN ('entry', 'exit', 'both')),
    enrollment_station           INTEGER NOT NULL DEFAULT 0,
    firmware_version             TEXT NOT NULL DEFAULT '0.0.0' COLLATE NOCASE,
    ip_address                   TEXT COLLATE NOCASE,
    ip_allowlist                 TEXT COLLATE NOCASE,
    wifi_ssid                    TEXT COLLATE NOCASE,
    wifi_signal                  INTEGER,
    timezone                     TEXT NOT NULL DEFAULT 'Asia/Manila' COLLATE NOCASE,
    heartbeat_interval_sec       INTEGER NOT NULL DEFAULT 30,
    sync_interval_sec            INTEGER NOT NULL DEFAULT 60,
    offline_queue_limit          INTEGER NOT NULL DEFAULT 500,
    queue_depth                  INTEGER NOT NULL DEFAULT 0,
    sensor_template_count        INTEGER,
    sensor_wipe_requested_at     TEXT,
    sensor_wipe_requested_by     INTEGER,
    sensor_wiped_at              TEXT,
    sensor_reported_at           TEXT,
    rfid_ok                      INTEGER,
    fingerprint_ok               INTEGER,
    modules_reported_at          TEXT,
    uptime_seconds               INTEGER NOT NULL DEFAULT 0,
    battery_percent              INTEGER,
    status                       TEXT NOT NULL DEFAULT 'pending' COLLATE NOCASE CHECK (status IN ('pending', 'active', 'offline', 'disabled', 'suspended', 'decommissioned')),
    claim_status                 TEXT NOT NULL DEFAULT 'unclaimed' COLLATE NOCASE CHECK (claim_status IN ('unclaimed', 'claimed', 'expired')),
    claimed_at                   TEXT,
    last_heartbeat_at            TEXT,
    last_seen_ip                 TEXT COLLATE NOCASE,
    locked_until                 TEXT,
    registered_by                INTEGER,
    location_note                TEXT COLLATE NOCASE,
    created_at                   TEXT NOT NULL DEFAULT (now()),
    updated_at                   TEXT NOT NULL DEFAULT (now()),
    deleted_at                   TEXT,
    live_slot                    TEXT GENERATED ALWAYS AS (CASE WHEN status IN ('pending','active','offline','suspended') AND deleted_at IS NULL THEN CAST(classroom_id AS TEXT) || ':' || device_role ELSE NULL END) STORED,
    CONSTRAINT fk_devices_wipe_requested_by FOREIGN KEY (sensor_wipe_requested_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_device_classroom FOREIGN KEY (classroom_id) REFERENCES classrooms (classroom_id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_device_registrant FOREIGN KEY (registered_by) REFERENCES users (user_id) ON DELETE SET NULL ON UPDATE CASCADE
);
INSERT INTO devices__new (id, device_id, device_name, mac_address, serial_number, classroom_id, device_role, enrollment_station, firmware_version, ip_address, ip_allowlist, wifi_ssid, wifi_signal, timezone, heartbeat_interval_sec, sync_interval_sec, offline_queue_limit, queue_depth, sensor_template_count, sensor_reported_at, rfid_ok, fingerprint_ok, modules_reported_at, uptime_seconds, battery_percent, status, claim_status, claimed_at, last_heartbeat_at, last_seen_ip, locked_until, registered_by, location_note, created_at, updated_at, deleted_at)
    SELECT id, device_id, device_name, mac_address, serial_number, classroom_id, device_role, enrollment_station, firmware_version, ip_address, ip_allowlist, wifi_ssid, wifi_signal, timezone, heartbeat_interval_sec, sync_interval_sec, offline_queue_limit, queue_depth, sensor_template_count, sensor_reported_at, rfid_ok, fingerprint_ok, modules_reported_at, uptime_seconds, battery_percent, status, claim_status, claimed_at, last_heartbeat_at, last_seen_ip, locked_until, registered_by, location_note, created_at, updated_at, deleted_at FROM devices;
DROP TABLE devices;
ALTER TABLE devices__new RENAME TO devices;
CREATE INDEX fk_devices_wipe_requested_by ON devices (sensor_wipe_requested_by);
CREATE INDEX fk_device_registrant ON devices (registered_by);
CREATE INDEX idx_devices_module_health ON devices (rfid_ok, fingerprint_ok);
CREATE INDEX idx_device_classroom ON devices (classroom_id);
CREATE INDEX idx_device_enrollment_station ON devices (enrollment_station, deleted_at);
CREATE INDEX idx_device_status ON devices (status, last_heartbeat_at);
CREATE UNIQUE INDEX uq_device_mac ON devices (mac_address);
CREATE UNIQUE INDEX uq_device_public_id ON devices (device_id);
CREATE UNIQUE INDEX uq_one_device_per_classroom_role ON devices (live_slot);

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
    OR NEW.enrollment_station IS NOT OLD.enrollment_station
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
    OR NEW.sensor_template_count IS NOT OLD.sensor_template_count
    OR NEW.sensor_wipe_requested_at IS NOT OLD.sensor_wipe_requested_at
    OR NEW.sensor_wipe_requested_by IS NOT OLD.sensor_wipe_requested_by
    OR NEW.sensor_wiped_at IS NOT OLD.sensor_wiped_at
    OR NEW.sensor_reported_at IS NOT OLD.sensor_reported_at
    OR NEW.rfid_ok IS NOT OLD.rfid_ok
    OR NEW.fingerprint_ok IS NOT OLD.fingerprint_ok
    OR NEW.modules_reported_at IS NOT OLD.modules_reported_at
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
-- Views that read devices are untouched: the runner renames with legacy_alter_table,
-- which leaves them pointing at the name, not the dropped table.


