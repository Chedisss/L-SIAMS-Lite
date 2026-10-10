-- ---------------------------------------------------------------------------
-- 036: a security event is triaged, not rewritten
--
-- security_logs was always meant to be updatable — an administrator resolves an
-- event, marks it a false positive, adds a note. That is why migration 007 gave
-- it a BEFORE DELETE guard but, unlike audit_logs, no BEFORE UPDATE guard: the
-- row is delete-proof, and its triage fields are meant to change.
--
-- The database privilege lockdown missed that distinction. It revoked UPDATE on
-- security_logs alongside audit_logs and login_history, on the reasoning that
-- all three are "log tables", and the resolve action then failed with
-- "1142 UPDATE command denied". The account has to be allowed to update the
-- table again — but a bare UPDATE grant would also let the event's own content
-- be rewritten, and a security log whose description can be edited is not
-- evidence of anything.
--
-- So the same treatment attendance_records already has: the table is updatable,
-- and a trigger freezes everything that identifies the event, leaving only the
-- triage columns free to change. What happened, when, to whom, from where — all
-- immutable; whether somebody has dealt with it — editable, and itself written
-- to the audit log by the service that changes it.
--
-- This restores the resolve workflow AND makes the guarantee precise rather than
-- broad: a security event cannot be deleted, and its content cannot be altered.
-- Only its resolution status and the administrator's note can move.
-- ---------------------------------------------------------------------------


DROP TRIGGER IF EXISTS trg_security_immutable_content;

-- IS NOT is SQLite's NULL-safe inequality, MariaDB's NOT (a <=> b).
--
-- One allowance MariaDB never needed: device_row_id may become NULL.
-- fk_seclog_device is ON DELETE SET NULL, and where MariaDB carries out a
-- foreign-key action without running triggers, SQLite runs them — so without
-- this, removing a device that ever appeared in a security event would be
-- refused here. Any other change to it is still rejected.
CREATE TRIGGER trg_security_immutable_content
BEFORE UPDATE ON security_logs
WHEN NEW.security_id     IS NOT OLD.security_id
  OR NEW.event           IS NOT OLD.event
  OR NEW.severity        IS NOT OLD.severity
  OR NEW.description     IS NOT OLD.description
  OR NEW.context_json    IS NOT OLD.context_json
  OR NEW.source_ip       IS NOT OLD.source_ip
  OR NEW.user_id         IS NOT OLD.user_id
  OR (NEW.device_row_id  IS NOT OLD.device_row_id AND NEW.device_row_id IS NOT NULL)
  OR NEW.device_id_text  IS NOT OLD.device_id_text
  OR NEW.endpoint        IS NOT OLD.endpoint
  OR NEW.http_method     IS NOT OLD.http_method
  OR NEW.user_agent      IS NOT OLD.user_agent
  OR NEW.created_at      IS NOT OLD.created_at
BEGIN
    SELECT RAISE(ABORT, 'A security event is immutable except for its resolution status and notes.');
END;



