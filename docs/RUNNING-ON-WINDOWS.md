# Running L-SIAMS on Windows

A step-by-step guide for a Windows machine with XAMPP. Follow it once and the
system is set up; after that, running it is a double-click.

This is the guide for **developing and demonstrating** — writing your capstone,
testing, showing the system to a panel. Putting it into a school for real is a
different job, covered in [DEPLOYMENT.md](DEPLOYMENT.md).

---

## Before you start

You need two things.

### 1. XAMPP

Download it from <https://www.apachefriends.org> and install it. Take the
defaults; installing to `C:\xampp` is easiest because the scripts look there
first.

This system uses one thing from XAMPP: **PHP**, the language it is written in.
The database is not a separate program — it is a single file,
`storage\database\lsiams.sqlite`, inside the project folder — so XAMPP's MySQL
can stay off. (If you are moving over from the MariaDB version of L-SIAMS, see
[MIGRATING-FROM-MARIADB.md](MIGRATING-FROM-MARIADB.md) first.)

You do **not** need Apache for this guide. `start.bat` runs its own small web
server, so there is no XAMPP configuration to do.

### 2. The project files

Put the project folder somewhere simple, like `C:\L-SIAMS`.

It does **not** need to go in `htdocs`. `start.bat` serves the site itself, and
keeping it out of `htdocs` is actually safer — nothing is exposed by Apache by
accident.

---

## First run — about five minutes

### Step 1 — Nothing to start

There is no database server. Go straight to step 2.

### Step 2 — Double-click `start.bat`

Open `C:\L-SIAMS` and double-click **`start.bat`**. A black window opens and
walks through the setup. You will see it:

1. find PHP and check the version and extensions
2. create the `.env` configuration file
3. generate the cryptographic keys
4. see there is no database yet and ask whether to **import** one from the
   MariaDB version or start a **new** one — press **N** for a new installation
5. create `storage\database\lsiams.sqlite` and apply the schema (36 migrations)
6. load the reference data — roles, permissions, grade levels, departments

Then it stops and asks you to create your administrator account.

### Step 3 — Create your administrator account

It asks four things, in this order:

```
Full name: Juan Dela Cruz
Username:  admin
Email:     admin@school.local
Password:  (you will not see what you type)
Confirm password:
```

**The password rules are strict** — this is an attendance system, so it insists:

- at least **12 characters**
- at least one **UPPERCASE** letter
- at least one **lowercase** letter
- at least one **number**
- at least one **symbol** (`! @ # $ % & * ?` …)
- not your own name, username or email
- not on the common-password list

A password like `MySchool-2026!Pass` satisfies all of it.

If it refuses, it prints exactly which rule failed. Fix it and run `start.bat`
again.

> Nothing you type at the password prompt appears on screen — not even dots.
> That is normal. Type it and press Enter.

### Step 4 — The system starts

Three windows open and stay open:

| Window | What it does |
|---|---|
| **L-SIAMS web** | the site itself — this is the window `start.bat` becomes |
| **L-SIAMS worker** | closes sessions left open, marks offline terminals, tidies old data |
| **L-SIAMS realtime** | pushes live updates to the dashboards |

Your browser opens at **<http://localhost:8080>** by itself.

### Step 5 — Log in

Use the username and password from Step 3. You land on the dashboard.

It will be mostly empty, because there are no students yet. That is the next
step.

---

## Add sample data (recommended)

An empty system is hard to judge. This fills it with a small complete school so
every page has something real on it.

Open a Command Prompt in the project folder — Shift + right-click the folder in
Explorer, then "Open PowerShell window here" — and run:

```
console.bat seed --demo
```

That creates 7 teachers with fingerprints enrolled, 5 sections, ~140 students
with RFID cards, 5 terminals, 25 schedules, and **30 school days of attendance**
— around 3,000 records.

Refresh your browser. The dashboard, reports and analytics now have data.

> It refuses to run if the database already holds real students, so you cannot
> mix sample data into genuine records by accident.

The demo teachers can log in too — username is first initial + surname
(`mreyes`, `acruz`, `lbautista`), and the password is printed when the seeder
finishes. Log in as one to see the teacher's side, which is deliberately much
narrower than the administrator's.

---

## Every day after that

**Double-click `start.bat`.** That is all. It skips the whole setup because `.env` already exists, and goes
straight to starting the system.

To stop: **double-click `stop.bat`**, or just close the three windows. There is
nothing else running.

---

## Getting a newer version — `update.bat`

Do **not** delete the folder and download the ZIP again. That throws away your
`.env` file, your uploaded photos and your generated reports, and it makes you
redo the whole setup.

Double-click **`update.bat`** instead. It downloads only what actually changed —
usually a few kilobytes — and applies any new database changes for you.

The first time you run it, it will say the folder is not linked to GitHub yet
and offer to link it. Answer **Y**. That happens once. Every update after that
is: double-click, wait a few seconds, done.

It needs Git installed. If you do not have it, `update.bat` will say so and
point you at <https://git-scm.com/download/win> — run the installer and click
Next through every screen, the defaults are all correct. Also a one-time thing.

**What is never touched by an update:**

| Safe | Why |
|---|---|
| `.env` | your keys are not in the repository |
| `public/uploads/` | student and teacher photos |
| `storage/reports/`, `storage/logs/` | generated reports and logs |
| `database/backups/` | your backups |
| `storage/database/` | the database file itself — never tracked, never replaced |

**What is replaced:** the program files. If you edited any of them yourself,
your edit is replaced by the official version — so keep your own changes
somewhere else.

After it finishes, close the running L-SIAMS windows and run `start.bat` again
so the new version is loaded.

---

## Using it from a phone or another laptop

`start.bat` prints two addresses when it finishes:

```
     On this PC:        http://localhost:8080
     On other devices:  http://192.168.1.14:8080
```

Any device on the same Wi-Fi can open that second one. Nothing to install on
those devices, and nothing to configure here — but Windows Firewall has to be
allowed through once. [`NETWORK-ACCESS.md`](NETWORK-ACCESS.md) walks through it.

---

## `console.bat` — the useful commands

Open a Command Prompt in the project folder (Shift + right-click the folder →
"Open PowerShell/Terminal here") and run:

| Command | What it does |
|---|---|
| `console.bat doctor` | check the whole installation and list what is wrong |
| `import-from-mariadb.bat` | bring data over from the MariaDB version (drop a backup or export on it if MySQL will not start) |
| `import.bat` | drag a `.sql` file or backup onto it to load it into the database |
| `console.bat seed --demo` | fill the system with sample data |
| `console.bat user:create-admin` | add another administrator |
| `console.bat backup` | take an encrypted backup right now |
| `console.bat migrate:status` | show which database changes have been applied |
| `console.bat security:audit-keys` | check the key-generation code for weak randomness |
| `console.bat` | list everything |

---

## Restoring a `.sql` file

Drag the file onto **`import.bat`**. It works out what kind of file it is:

- **A SQLite dump** — what `console.bat backup:decrypt` writes. It replaces the
  database as **one transaction**: either the whole file goes in, or nothing
  changes. If the database already holds data you are asked to confirm with
  `--force`:

  ```
  console.bat db:import "C:\path\to\file.sql" --force
  ```

- **A file from the MariaDB version** — a phpMyAdmin export, a mysqldump, or a
  `.sql.gz.lsiams` backup taken before the move. It is handed to the MariaDB
  importer, which rebuilds it into SQLite and checks every table. See
  [MIGRATING-FROM-MARIADB.md](MIGRATING-FROM-MARIADB.md).

### Restoring a `.sql.gz.lsiams` backup

`console.bat backup` writes a compressed, encrypted archive to
`database\backups`. Windows shows it as an unknown file type, which is
correct — it is a file only this system knows how to read.

Archives taken before this was fixed end in `.sql.gz.enc`, and Windows hands
that extension to whatever program has claimed it, commonly Wireshark. That
was only ever an icon: the file is not a capture and nothing is wrong with it.
Do not open it in that program. Everything below works on both names.

Normally you restore one from **Admin → Backup → Restore**. That needs the
`backups` row describing the archive, which lives in the database — so it is
gone in exactly the situation where a backup matters. From a Command Prompt
you can go straight at the file:

```
console.bat backup:decrypt lsiams-manual-20260814-120753.sql.gz.lsiams
console.bat db:import database\backups\lsiams-manual-20260814-120753.sql --force
```

(A `.sql.gz.lsiams` taken by the **MariaDB** version is imported differently:
drop it onto `import-from-mariadb.bat`.)

Delete the decrypted `.sql` afterwards — it is plaintext school data.

> **Keep `.env` with your backups, and never regenerate the keys while an
> archive still matters.** The archive is encrypted with `APP_KEY`. A new
> `APP_KEY` does not fail loudly — it fails with `authentication tag
> mismatch`, and there is no recovery from that.

### After importing an older export

A file exported before you last updated the project describes an older
database. The import will succeed and the system will then break in ways that
look nothing like an import problem — missing fingerprint enrolment, terminals
that never leave *Pending*. `db:import` tells you when this has happened:

```
  5 migration(s) in this release are not in that file:
    008_create_fingerprint_enrollment_requests.sql
    ...
  Apply them now:  console.bat migrate
```

Run `console.bat migrate` and the database is brought up to date without
touching your data.

---

## When something goes wrong

### Start here

```
console.bat doctor
```

It checks the whole installation and prints what it finds: PHP and its
extensions, the keys in `.env`, the database connection and migrations, how many
teachers/students/terminals actually exist, whether any fingerprint record
contradicts itself, which terminals have claimed their key and when each last
reported in, and whether the realtime server is running. It changes nothing, so
it is safe to run at any time, including on a live installation.

It ends with a summary in two parts: problems that will stop something working,
and things merely worth knowing about. Most questions of the form "why does this
page show nothing?" are answered in that summary.

**"No scanner is available, so no teacher can be registered"**
A fingerprint has to be read by a fingerprint sensor, and the PC does not have
one. Register an **enrolment scanner** — an ESP32 and R307 sitting on your desk
— under **IoT Devices → Register Device**, choosing *Enrolment scanner* rather
than *Classroom terminal*. It needs no classroom and records no attendance; it
exists so the whole enrolment happens at this computer instead of walking people
to a classroom. Flash it exactly like a terminal, and it activates itself.

**A page shows no teachers**
A *user account* with the teacher role is not a *teacher record*. Fingerprints,
schedules and sections all attach to the teacher record, which is created under
**Teachers**, not under Users. `doctor` prints the count of each, so if it says
`teachers 0` while you have teacher logins, that is the explanation.

**The pill in the top bar says "Polling" instead of "Live"**
Not an error. It means the realtime server is not reachable, so the pages
refresh every few seconds instead of receiving updates instantly. Everything
still works — attendance, enrolment, reports. Usually the **L-SIAMS realtime**
window was closed; run `start.bat` again, or `console.bat doctor` to confirm.

"Connecting" for a second or two on a fresh page load is normal — it is choosing
a transport. "Reconnecting" means a connection that was working has dropped.

**"PHP is missing: ..." and it refuses to start**
Only four extensions are genuinely required — `pdo_sqlite`, `openssl`,
`mbstring` and `json`. Open `C:\xampp\php\php.ini` in Notepad, press Ctrl+F,
find each name it listed, and delete the `;` at the start of that line:

```
;extension=mbstring     becomes     extension=mbstring
```

Save, then run `start.bat` again.

**"Off, and only these features need them: gd"**
Not an error — the system starts and runs normally. `gd` powers one thing:
profile photo uploads. Every other page works without it, and the upload form
says exactly what to enable if you try to use it.

To switch it on, same as above: find `;extension=gd` in `C:\xampp\php\php.ini`,
delete the leading `;`, save, run `start.bat` again.

`zip` used to be listed here as well, because Excel export, Excel import and
the bulk device provisioning bundle were built on it. They are not any more —
L-SIAMS writes and reads the `.xlsx` container itself — so a stock XAMPP with
nothing enabled runs every one of those features.

**"Could not find php.exe"**
XAMPP is not installed, or not on `C:`, `D:` or `E:`. Install it, or add
`C:\xampp\php` to your PATH.

**"The database file would not open"**
`storage\database\lsiams.sqlite` is read-only, was damaged in a copy, or is
not a database at all. Run `console.bat doctor`, which checks the file in
detail. To go back to a known-good state, restore a backup from the Backups
page or with `import.bat`. Copy the database only while L-SIAMS is stopped
(`stop.bat`): a copy taken while it runs can miss the latest writes, which sit
in the `lsiams.sqlite-wal` file beside it until they are folded in.

**The browser says "can't reach this page"**
The web window closed. Look for an error in it, then run `start.bat` again.

**Port 8080 is already in use**
Something else is using it. Open `start.bat` in Notepad and change
`set "WEB_PORT=8080"` to `8081`, then change `APP_URL` in `.env` to match.

**Login says the password is wrong and you are sure it is not**
Check `SESSION_COOKIE_SECURE=false` in `.env`. A "Secure" cookie is never sent
over `http://`, so login fails silently if that is set to true locally.

**Everything freezes when a page is open**
Check `REALTIME_SSE_ENABLED=false` in `.env`. The small development web server
handles one request at a time, and a live-updates stream would hold it open
forever.

**You forgot the administrator password**
Create another administrator: `console.bat user:create-admin`. There is no way
to read the old one — passwords are stored as bcrypt hashes, which is the point.

---

## What to say if you are asked "how does it run?"

Useful for a defence panel:

- **PHP** serves the web application; **SQLite** stores the data in a single
  file. Several terminals can write at once: each write takes SQLite's write
  lock for a few milliseconds and the others wait their turn, and the database
  itself enforces that attendance can never be recorded twice or deleted.
- `start.bat` runs three processes: the **web server**, a **maintenance worker**
  that closes abandoned sessions and tidies old data, and a **realtime server**
  that pushes live updates to open dashboards.
- The classroom terminals are **ESP32** boards that talk to the web application
  over the school's own network — every request they send is **signed**, so a
  laptop on the same network cannot forge attendance.
- Nothing needs the internet. The whole system runs on one machine inside the
  school.

---

## Important: this setup is for development

`start.bat` is built for one person on one machine. It uses PHP's small
built-in web server, which handles **one request at a time**, and the local
configuration turns off three protections that only make sense to relax on your
own PC — they are each labelled in `.env.local.example`:

| Relaxed locally | Why | Why it matters in a school |
|---|---|---|
| Session cookie not marked Secure | a Secure cookie is never sent over `http://`, so login would fail | over HTTPS this must be on, or the cookie can be read in transit |
| Realtime server runs without TLS | no certificate exists on a fresh PC | otherwise attendance events cross the network in the clear |
| Server-Sent Events off | one open stream blocks the single-threaded dev server | on a real server this is the fastest live-update path |

For an actual classroom installation — Apache or nginx, HTTPS, the worker and
realtime server running as services, the database folder locked down and
backups going off the machine — follow [DEPLOYMENT.md](DEPLOYMENT.md) instead.
