-- ---------------------------------------------------------------------------
-- 037: an absence can become an arrival
--
-- Closing a class writes an Absent row for every student who never tapped in.
-- Those rows have no card and no request id: nobody tapped. When the teacher
-- reopens the class, a student who arrives late must still be able to tap in,
-- and the tap turns that Absent row into their arrival rather than adding a
-- second row for the same student and session.
--
-- The identity trigger refused that, because it treated a card and a request id
-- that were never written the same as ones that were. A refused write meant the
-- arrival kept no request id, so a terminal's retry of the same queued tap was
-- not recognised as a duplicate.
--
-- The rule is now "written once": rfid_uid and request_id may go from NULL to a
-- value, and never change after that. Every other identity column is as before.
-- ---------------------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_attendance_immutable_identity;

CREATE TRIGGER trg_attendance_immutable_identity
BEFORE UPDATE ON attendance_records
WHEN NEW.attendance_id  IS NOT OLD.attendance_id
  OR NEW.session_id     IS NOT OLD.session_id
  OR NEW.student_id     IS NOT OLD.student_id
  OR NEW.section_id     IS NOT OLD.section_id
  OR NEW.grade_level_id IS NOT OLD.grade_level_id
  OR NEW.subject_id     IS NOT OLD.subject_id
  OR NEW.teacher_id     IS NOT OLD.teacher_id
  OR NEW.classroom_id   IS NOT OLD.classroom_id
  OR NEW.created_at     IS NOT OLD.created_at
  OR (OLD.rfid_uid   IS NOT NULL AND NEW.rfid_uid   IS NOT OLD.rfid_uid)
  OR (OLD.request_id IS NOT NULL AND NEW.request_id IS NOT OLD.request_id)
BEGIN
    SELECT RAISE(ABORT, 'An attendance record cannot be re-attributed. Its student, session, section, grade level, subject, teacher, classroom, card, request id and creation time are permanent.');
END;
