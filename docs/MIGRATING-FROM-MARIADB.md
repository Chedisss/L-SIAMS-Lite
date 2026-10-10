# Moving from the MariaDB version to L-SIAMS-Lite

L-SIAMS-Lite is the same system — the same pages, the same terminals, the same
firmware and API — with one difference: the database is a single file,
`storage\database\lsiams.sqlite`, instead of XAMPP's MySQL. There is no
database server to start, so there is nothing to fail to start.

Moving over takes about fifteen minutes. Your existing installation is never
changed by it, so you can go back at any time until you are satisfied.

## What you need

- The PC that runs L-SIAMS now, with XAMPP (its PHP is still used; its MySQL
  is only needed once, for step 4 — and not even then if it will not start).
- The L-SIAMS-Lite folder.
- Your old installation's **`.env` file**. This matters more than anything
  else on this page: it holds `APP_KEY`, `API_KEY_PEPPER` and
  `REALTIME_TICKET_SECRET`, the keys that encrypted the terminals' secrets,
  the fingerprint templates and your backups. With new keys none of those can
  be read, and every terminal and fingerprint would have to be set up again.

## Steps

### 1. Take a backup in the old system

Sign in as an administrator, open **Backups** and press **Back up now**.
Whatever happens next, this archive is your safety net. Note where it is saved
(`database\backups\` in the old folder).

### 2. Stop the old system

Close the L-SIAMS windows (or run the old `stop.bat`). Leave the old folder
exactly as it is.

### 3. Put L-SIAMS-Lite in place and copy the `.env`

Put the L-SIAMS-Lite folder wherever you like (for example
`C:\xampp\htdocs\L-SIAMS-Lite`). Then copy the **`.env`** file from the old
folder into the new one.

Copy `public\uploads\students` and `public\uploads\teachers` across as well, so
the photos come with the records.

### 4. Bring the data across

**If MySQL still starts:** start MySQL in the XAMPP Control Panel and
double-click **`import-from-mariadb.bat`**. It reads the old database using the
`DB_HOST`, `DB_NAME`, `DB_USER` and `DB_PASS` lines that are already in your
`.env`.

**If MySQL will not start:** you do not need it. Drag your newest backup — a
`.sql.gz.lsiams` file from the old folder's `database\backups` — onto
**`import-from-mariadb.bat`**. A phpMyAdmin export (`.sql`) works the same way.

Either way the importer:

1. builds the new database to exactly the version of the old one,
2. copies every row,
3. checks every table — the number of rows and a fingerprint of their
   contents must match what it read,
4. applies any newer updates,
5. and only then puts the file in place.

If anything does not match, it stops and changes nothing. When it finishes it
lists every table and how many rows came across.

### 5. Start L-SIAMS-Lite

Double-click **`start.bat`** and sign in as before. Check a few things you
know: today's attendance, a student, a teacher's schedule, a terminal on the
Devices page.

The terminals need no change if the PC's address and port are the same as
before.

### 6. When you are satisfied

Turn MySQL off in the XAMPP Control Panel (and untick its autostart). The old
folder can stay as an archive for as long as you like.

## Questions

**The times on records look eight hours out.** Only possible with a hand-made
`mysqldump` that does not say which time zone it was written in; the importer
warns about this when it happens. Import again with the offset the dump was
made in, e.g. `console.bat db:import-mysql --from-file="dump.sql" --timezone=+00:00 --force`.
Backups made by L-SIAMS and phpMyAdmin exports are not affected.

**It says there is already a database with data.** You are importing a second
time. Add `--force`: the database already there is renamed to
`lsiams.sqlite.before-import-<date>`, never deleted.

**It lists "rows whose parent row is missing".** Those rows were already like
that in the old database (usually left behind by an old import done with
checks switched off). They are copied as they were, so nothing is lost; the
list tells you where to look if you want to tidy them up.

**Can I restore an old MariaDB-era backup later, from the Backups page?** No —
those are MySQL SQL. Import them with `import-from-mariadb.bat` instead. Every
backup taken after the move is a SQLite backup and restores normally.

**How do I back up now?** Exactly as before: the Backups page, the nightly
schedule, or `console.bat backup`. You can also copy
`storage\database\lsiams.sqlite` while L-SIAMS is stopped.

## For the curious: what changed underneath

- The 36 migrations were translated one for one into SQLite and checked, step
  by step, to leave exactly the schema MariaDB did (`database/migrations/README.md`).
- The rules the database enforces itself — attendance cannot be deleted, audit
  logs cannot be changed, a section cannot go over capacity — are SQLite
  triggers with the same messages. `console.bat security:privileges` tries
  each forbidden change on a real row inside a transaction that is rolled back,
  and reports any rule that did not hold.
- Several terminals can tap at once. SQLite lets one write happen at a time and
  each takes a few milliseconds; the others wait their turn rather than fail.
  `tests/concurrency/parallel.php` races real processes against the file to
  prove it.
