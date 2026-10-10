# Migrations

These are the 36 migrations of the MariaDB version of L-SIAMS, translated one
for one into SQLite. Each file has the same number and name as its MariaDB
original and leaves the database in the same state: the same tables, columns,
defaults, keys, indexes, foreign keys, CHECK rules, triggers, views and
reference data. An installation's `schema_migrations` table therefore records
the same names on either database.

`php bin/console migrate` applies them. Each file runs in one transaction,
with foreign keys off and `legacy_alter_table` on, and is committed only if
`PRAGMA foreign_key_check` finds nothing broken. A migration that fails leaves
the database exactly as it was, DDL included.

## How MariaDB constructs were translated

| MariaDB | SQLite |
|---|---|
| `INT … AUTO_INCREMENT PRIMARY KEY` | `INTEGER PRIMARY KEY AUTOINCREMENT` |
| `ENUM('a','b')` | `TEXT CHECK (col IN ('a','b'))` |
| `utf8mb4_unicode_ci` text (case-insensitive) | `COLLATE NOCASE`; `_bin` and JSON columns stay case-sensitive |
| `DEFAULT CURRENT_TIMESTAMP` | `DEFAULT (now())` — `now()` is supplied by the application in `APP_TIMEZONE` |
| `ON UPDATE CURRENT_TIMESTAMP` | an `AFTER UPDATE` trigger named `trg_<table>_<column>` |
| `TIME` | text, normalised to `HH:MM:SS` by trigger, compared with `time()` |
| An index MariaDB creates for a foreign key | created explicitly, with the constraint's name |
| `SIGNAL SQLSTATE '45000'` | `RAISE(ABORT, …)` with the same message |
| `NOT (a <=> b)` | `a IS NOT b` |
| `CREATE OR REPLACE VIEW` | `DROP VIEW IF EXISTS` then `CREATE VIEW` |
| `INSERT IGNORE` / `UPDATE IGNORE` | `INSERT OR IGNORE` / `UPDATE OR IGNORE` |
| `ON DUPLICATE KEY UPDATE k = k` | `ON CONFLICT DO NOTHING` |
| `UPDATE … JOIN`, `DELETE t FROM … JOIN` | the join as an `IN (…)` subquery or a CTE |
| `MODIFY COLUMN`, `ADD CONSTRAINT`, `DROP COLUMN`, adding a stored generated column | the table is rebuilt (new table, copy, drop, rename, then its indexes and triggers) |

When the constraint or generated column is added in the same migration that
creates the table, it is declared in the `CREATE TABLE` instead of rebuilding.

Two behaviours differ on purpose, each noted where it happens:

- **Foreign-key actions run triggers in SQLite.** MariaDB does not. So
  `trg_security_immutable_content` (036) lets `security_logs.device_row_id`
  become NULL, which `fk_seclog_device ON DELETE SET NULL` needs when a device
  is removed. Every other change to a security event is still refused.
- **Division.** SQLite divides integers as integers, so percentages in views
  multiply by `100.0` before dividing.

## Writing a new migration

Add `037_….sql` in SQLite syntax. Keep it to plain statements: the runner
executes the whole file at once, so there are no `DELIMITER` blocks, and
triggers are written with `BEGIN … END;` directly.
