-- School Form 2 (SF2) prints two facts the system did not record before: the
-- government School ID that identifies the school to DepEd, and the name of the
-- school head who attests the monthly register. Both are school-wide settings,
-- so they live in `settings` beside the school name and address rather than on
-- any one section. Added here so an installation that predates the SF2 export
-- gains the fields on the Settings page and the form can be filled in.
--
-- INSERT OR IGNORE: on a database that already has these keys (a fresh install
-- seeded them), this changes nothing and the migration is still safe to run.

INSERT OR IGNORE INTO settings
    (setting_key, setting_value, value_type, group_name, label, description, is_sensitive)
VALUES
    ('school.deped_id', '', 'string', 'school', 'DepEd School ID',
        'The government School ID printed on School Form 2 (SF2).', 0),
    ('school.head_name', '', 'string', 'school', 'School Head / Principal',
        'Printed as the attesting official on School Form 2 (SF2).', 0);
