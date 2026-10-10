# Deployment

This describes deploying L-SIAMS on a single Linux server inside a school's LAN,
which is what the system is designed for. Nothing here requires internet access
at runtime.

---

## 1. Server preparation

### Packages

```bash
# Debian / Ubuntu
sudo apt update
sudo apt install -y \
    php8.4 php8.4-fpm php8.4-sqlite3 php8.4-mbstring php8.4-zip \
    php8.4-gd php8.4-curl php8.4-xml php8.4-sockets \
    nginx

# RHEL / Rocky
sudo dnf install -y \
    php php-fpm php-pdo php-mbstring php-zip php-gd php-json php-sockets \
    nginx
```

Confirm every extension the application needs is loaded:

```bash
php -m | grep -E '^(pdo_sqlite|openssl|mbstring|zip|gd|json|zlib|sockets)$'
```

All eight must appear. `sockets` is used only by the realtime server; the rest
are used by the web application and will cause a hard failure at boot if absent.

`gmp` is **not** required. The base62 encoder in the key path uses it when
present and falls back to rejection sampling when it is not; both routes produce
the same 59-character keys, and `php bin/console security:audit-keys` exercises
whichever one this host takes.

### No database server

The database is one SQLite file, compiled into PHP's `pdo_sqlite`; there is no
server package to install. It needs SQLite 3.31 or newer, which every PHP 8.1+
build has — `php bin/console doctor` prints the version.

## 2. Files and permissions

```bash
sudo git clone <repository-url> /var/www/lsiams
cd /var/www/lsiams

sudo chown -R www-data:www-data /var/www/lsiams

# The application only needs to write to these places. storage/ includes
# storage/database, which holds the database file and SQLite's -wal and -shm
# files beside it: the folder, not only the file, must be writable.
sudo chmod -R 750 /var/www/lsiams
sudo chmod -R 770 storage public/uploads database/backups

# Nobody but the application's account may read or write the database: there
# are no database accounts in SQLite, so the file's permissions are the
# boundary between "can use the system" and "can rewrite its history".
sudo chmod 700 storage/database

# .env holds the master keys.
sudo chmod 640 .env
sudo chown root:www-data .env
```

Only `public/` is served. `app/`, `config/`, `database/`, `storage/` and `.env`
must never be reachable over HTTP — the web-server configurations below place the
document root at `public/` precisely so they cannot be.

---

## 3. Database

### Create it

```bash
sudo -u www-data php bin/console install    # migrate + seed + first administrator
```

That creates `storage/database/lsiams.sqlite` (or wherever `DB_PATH` points)
and applies every migration, each as one transaction. Run every console command
as the web server's account (`www-data` here), so the files SQLite creates
beside the database belong to it too; a `-wal` file owned by root is the classic
reason for "attempt to write a readonly database".

Coming from the MariaDB version of L-SIAMS, import instead of installing:
`sudo -u www-data php bin/console db:import-mysql` (see
[MIGRATING-FROM-MARIADB.md](MIGRATING-FROM-MARIADB.md)).

### How it is opened

Every connection sets the same four things (`app/Core/Database.php`):

| | Why |
|---|---|
| `journal_mode = WAL` | readers — the dashboards, the realtime server, reports — never wait for a tap, and a tap never waits for them |
| `synchronous = NORMAL` | the documented safe setting under WAL: a power cut can lose the last instant of commits but never corrupts the file |
| `foreign_keys = ON` | SQLite ships with them off, per connection |
| `busy_timeout` (`DB_BUSY_TIMEOUT_MS`, default 5000) | one connection writes at a time; the others wait up to this long instead of failing |

Write transactions begin `IMMEDIATE`, taking the write lock at the start. That
is what replaces the MariaDB version's `SELECT ... FOR UPDATE` row locks: a
transaction that holds the only write lock cannot have the rows it read changed
underneath it. A write that still finds the database busy after the timeout is
retried with backoff (`deadlock_retry` in `config/database.php`).

Keep the file on a **local disk**. SQLite's locking depends on the operating
system's file locks, which network file systems (SMB shares, NFS) do not
reliably provide.

### Protecting history

The audit log, security log and login history cannot be deleted, and attendance
records cannot be deleted or re-attributed: the services have no method that
would, and triggers in the database refuse the statement whoever sends it.

There are no database accounts to withhold privileges from, so the layer the
MariaDB version built with GRANTs is the file system here: only the account
that runs L-SIAMS may open `storage/database`. Then prove the triggers are in
place rather than assuming it:

```bash
sudo -u www-data php bin/console security:privileges
```

It attempts each forbidden change on a real row, inside a transaction that is
always rolled back, and lists any guard that let it through. Run it after any
restore.

### Health

```bash
sudo -u www-data php bin/console doctor
```

checks the file opens, is writable, is in WAL mode with foreign keys on, passes
SQLite's `quick_check`, and has every migration applied; it also lists any
rows whose parent row is missing.

## 4. Web server

### nginx

`/etc/nginx/sites-available/lsiams`:

```nginx
server {
    listen 80;
    server_name lsiams.yourschool.internal 192.168.1.10;

    # Everything is HTTPS. The device API signs requests, but the browser
    # session cookie must never travel in the clear.
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name lsiams.yourschool.internal 192.168.1.10;

    root /var/www/lsiams/public;
    index index.php;

    ssl_certificate     /etc/ssl/lsiams/server.crt;
    ssl_certificate_key /etc/ssl/lsiams/server.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache   shared:SSL:10m;

    client_max_body_size 10M;

    # Do not advertise the server version.
    server_tokens off;

    # The application sets its own security headers; these cover static files
    # too, which never reach PHP.
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php8.4-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_read_timeout 120;
    }

    # Uploads are user-supplied bytes. Serving them is fine; executing them is
    # not, and neither is letting a browser sniff one into a script.
    location ^~ /uploads/ {
        location ~ \.php$ { deny all; }
        add_header X-Content-Type-Options nosniff always;
        add_header Content-Disposition "inline" always;
    }

    # Nothing outside public/ is reachable anyway, but say so explicitly.
    location ~ /\.(?!well-known) { deny all; }
    location ~ ^/(app|config|database|storage|routes|bin|tests|firmware|realtime)/ { deny all; }

    access_log /var/log/nginx/lsiams-access.log;
    error_log  /var/log/nginx/lsiams-error.log warn;
}
```

Enable it:

```bash
sudo ln -s /etc/nginx/sites-available/lsiams /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

### Apache

`/etc/apache2/sites-available/lsiams.conf`:

```apache
<VirtualHost *:80>
    ServerName lsiams.yourschool.internal
    Redirect permanent / https://lsiams.yourschool.internal/
</VirtualHost>

<VirtualHost *:443>
    ServerName lsiams.yourschool.internal
    DocumentRoot /var/www/lsiams/public

    SSLEngine on
    SSLCertificateFile    /etc/ssl/lsiams/server.crt
    SSLCertificateKeyFile /etc/ssl/lsiams/server.key
    SSLProtocol -all +TLSv1.2 +TLSv1.3

    <Directory /var/www/lsiams/public>
        Options -Indexes -MultiViews +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    # Refuse to serve anything above the document root even if a symlink or a
    # misconfiguration ever exposes it.
    <Directory /var/www/lsiams>
        Require all denied
    </Directory>

    ServerTokens Prod
    ServerSignature Off

    ErrorLog  ${APACHE_LOG_DIR}/lsiams-error.log
    CustomLog ${APACHE_LOG_DIR}/lsiams-access.log combined
</VirtualHost>
```

```bash
sudo a2enmod rewrite ssl headers
sudo a2ensite lsiams
sudo apachectl configtest && sudo systemctl reload apache2
```

The repository ships `public/.htaccess` (front-controller rewriting and security
headers) and `public/uploads/.htaccess` (`php_flag engine off`), both of which
Apache picks up automatically.

---

## 5. TLS

> **On Windows and XAMPP, do not follow this section by hand.**
> `console.bat tls:generate` and `console.bat tls:apache` do all of it — the
> root, the server certificate with the right SANs, the Apache configuration,
> and the header the terminals compile in — and `console.bat doctor` verifies
> the result. See [`HTTPS.md`](HTTPS.md). The commands work on Linux too
> (`php bin/console tls:generate`); the manual steps below are kept for
> administrators integrating with an existing organisational CA.

The devices and browsers are all on the school LAN, so a public CA is neither
available nor necessary. Use an internal CA and install its root certificate on
every terminal and every administrator machine.

```bash
sudo mkdir -p /etc/ssl/lsiams && cd /etc/ssl/lsiams

# Root CA — keep ca.key offline, on removable media, not on this server.
sudo openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout ca.key -out ca.crt \
    -subj "/CN=School Internal CA/O=<School Name>"

# Server certificate. The SANs must list every name and address that will be
# used to reach the server, including the bare IP the terminals are configured
# with — a terminal validating a certificate cannot fall back to a name.
sudo openssl req -newkey rsa:2048 -sha256 -nodes \
    -keyout server.key -out server.csr \
    -subj "/CN=lsiams.yourschool.internal/O=<School Name>"

cat > san.cnf <<'EOF'
subjectAltName = DNS:lsiams.yourschool.internal, DNS:lsiams, IP:192.168.1.10
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF

sudo openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out server.crt -days 825 -sha256 -extfile san.cnf

sudo chmod 600 server.key ca.key
sudo chown root:root /etc/ssl/lsiams/*
```

Copy `ca.crt` into `firmware/L_SIAMS_Bench/` and reference it from
`config.h` so the terminals validate the server rather than trusting whatever
answers. A terminal configured to skip validation would accept any device on the
LAN claiming to be the server.

---

## 6. Services

Two long-running processes: the maintenance worker and the realtime server.

Both unit files are in the repository — `docs/deploy/lsiams-worker.service` and
`docs/deploy/lsiams-realtime.service` — so they can be copied straight into
place rather than retyped. They are reproduced here for reference.

`/etc/systemd/system/lsiams-worker.service`:

```ini
[Unit]
Description=L-SIAMS maintenance worker
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/var/www/lsiams
ExecStart=/usr/bin/php /var/www/lsiams/bin/console worker --interval=60
Restart=always
RestartSec=10

# The worker touches the database and the storage directory, nothing else.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/www/lsiams/storage /var/www/lsiams/database/backups

StandardOutput=append:/var/log/lsiams/worker.log
StandardError=append:/var/log/lsiams/worker.log

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/lsiams-realtime.service`:

```ini
[Unit]
Description=L-SIAMS realtime WebSocket server
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/var/www/lsiams
ExecStart=/usr/bin/php /var/www/lsiams/realtime/server.php
Restart=always
RestartSec=5

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/www/lsiams/storage

# Binding 8443 needs no privilege; reading the TLS key does.
SupplementaryGroups=ssl-cert

StandardOutput=append:/var/log/lsiams/realtime.log
StandardError=append:/var/log/lsiams/realtime.log

[Install]
WantedBy=multi-user.target
```

```bash
sudo mkdir -p /var/log/lsiams && sudo chown www-data:www-data /var/log/lsiams
sudo systemctl daemon-reload
sudo systemctl enable --now lsiams-worker lsiams-realtime
sudo systemctl status lsiams-worker lsiams-realtime
```

If the realtime server cannot start, the web application still works — the
front-end falls back to SSE and then to polling on its own. If the **worker**
is not running, sessions do not auto-close, stale devices are never marked
offline, and the retention sweeps never run. Monitor it.

### What the worker does, each pass

| Task | Frequency |
|---|---|
| Close sessions past their expiry window | every pass |
| Warn sessions closing within 5 minutes | every pass |
| Mark devices offline after missed heartbeats | every pass |
| Expire idle and absolute web sessions | every pass |
| Auto-revoke rotated API keys past their grace window | every pass |
| Retention sweeps (heartbeats, notifications, realtime events, processed requests, nonces) | hourly |

---

## 7. Log rotation

`/etc/logrotate.d/lsiams`:

```
/var/log/lsiams/*.log /var/www/lsiams/storage/logs/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0640 www-data www-data
    sharedscripts
}
```

Application logs are for operations. The **audit log, security log and login
history live in the database, not in files**, are never rotated, and are never
deleted — they are the record of who did what.

---

## 8. Backups

The application takes gzip-compressed, AES-256-GCM-encrypted backups. Encryption
uses `APP_KEY`, so **a backup is worthless without `.env`** — store a copy of
`APP_KEY` somewhere separate from the backups themselves, or a restore after a
disk failure will be impossible.

Nightly, via cron for `www-data`:

```cron
15 1 * * * cd /var/www/lsiams && /usr/bin/php bin/console backup >> /var/log/lsiams/backup.log 2>&1
```

A backup is taken while the system runs: it reads one consistent moment through
a read transaction and holds up no terminal. Restoring replaces the database in
a single transaction, so a restore that fails part-way changes nothing.

Then copy the encrypted files off the machine — a backup on the same disk as the
database is not a backup:

```cron
45 1 * * * rsync -a --delete /var/www/lsiams/database/backups/ /mnt/nas/lsiams-backups/
```

Verify restores on a scratch database at least once a term. An unverified backup
is a hope, not a plan. The Backup page has a **Verify** action that checks
integrity without restoring, and a **Restore** action that takes an automatic
safety backup first, requires password re-confirmation and a typed `RESTORE`
phrase, and signs every session out when it completes.

---

## 9. Network placement

- Put the terminals, the server and the administrator machines on the **same
  VLAN**, isolated from the general student network.
- Set `TRUSTED_WEB_CIDRS` and `TRUSTED_DEVICE_CIDRS` in `.env` to the actual
  ranges. Requests from outside them are refused by middleware before any
  authentication runs, so a stolen API key is useless from the wrong subnet.
- Give each terminal a **DHCP reservation**, and put that address in the device's
  IP allowlist on its detail page. A signed request from an unexpected address is
  refused and logged as an anomaly.
- Open only 443 (web) and 8443 (realtime WebSocket) inbound. Nothing needs
  outbound internet access.

---

## 10. Going live — checklist

- [ ] `APP_ENV=production` and `APP_DEBUG=false` in `.env`
- [ ] `APP_KEY`, `API_KEY_PEPPER` and `REALTIME_TICKET_SECRET` generated, not left blank
- [ ] `.env` is `chmod 640`, owned `root:www-data`
- [ ] `storage/database` is `chmod 700`, owned by the web server's account
- [ ] `php bin/console security:privileges` reports every guard holding
- [ ] TLS certificate installed; HTTP redirects to HTTPS
- [ ] The internal CA root is installed on every terminal
- [ ] `TRUSTED_WEB_CIDRS` and `TRUSTED_DEVICE_CIDRS` reflect the real network
- [ ] `lsiams-worker` and `lsiams-realtime` are enabled and running
- [ ] Nightly backup cron in place, and the off-machine copy is running
- [ ] A restore has been tested on a scratch database
- [ ] `php bin/console security:audit-keys` passes
- [ ] The first administrator's password has been changed from the installer's
- [ ] Every terminal has been claimed and shows **online** on the Devices page

---

## 11. Upgrading

```bash
cd /var/www/lsiams

sudo systemctl stop lsiams-worker lsiams-realtime
php bin/console backup                     # before anything else

git pull

sudo -u www-data php bin/console migrate   # each migration all-or-nothing
sudo -u www-data php bin/console seed      # idempotent: picks up new permissions and settings

sudo systemctl start lsiams-worker lsiams-realtime
sudo systemctl reload nginx
```

`seed` without `--demo` is safe to re-run on a live system — it inserts only
missing reference rows and updates descriptions. That is exactly when you want
it: after an upgrade that adds a permission or a setting.

---

## 12. Troubleshooting

**A terminal shows `SIGNATURE_INVALID`.** Almost always clock drift. The
signature covers a timestamp, and the server rejects anything outside its
tolerance window. Check the terminal's time against `GET /api/device/time`.

**A terminal shows `DEVICE_UNCLAIMED`.** It has credentials but has never
presented its single-use claim token. Re-flash it with a fresh provisioning file
from the device detail page.

**Taps are accepted but no session is open.** Sessions open only on fingerprint
verification by a teacher scheduled for that classroom at that time. Check the
schedule, and check the teacher's fingerprint is enrolled.

**A teacher opens a class in one room but the reader in another does not know
them.** Usually a matter of time: a sensor can only match templates in its own
flash, so a new terminal starts empty and fills itself as it polls, one template
per poll. Admin → Fingerprints shows how far each terminal has got, room by
room.

**How long a new enrolment takes to reach the other rooms.** One template
moves per poll, and the poll is `FINGERPRINT_SYNC_POLL_SECONDS` (default 15).
So a single teacher reaches every terminal within about fifteen seconds, and a
backlog of forty takes roughly ten minutes — per terminal, but terminals poll
independently, so twenty-five of them take no longer than one. On the day you
first enrol a whole staff, set it to 3 for the afternoon and the same forty
take two minutes; put it back afterwards, because a terminal recording taps
should not interrupt itself every three seconds to ask about fingerprints.

If you run with `FINGERPRINT_SYNC_SCOPE=timetable`, check the schedule first —
that setting sends a terminal only the teachers timetabled into its own room, so
a teacher with no schedule there is unknown to that reader by design, and the
coverage table counts against the room rather than the school ("2 of 2" is
complete in a room two people teach in). On the default, `all`, every terminal
is owed every enrolled teacher and the timetable makes no difference to what a
sensor holds.

Two states in that table need a person rather than time:

- *"enrolled on one terminal only"* — the enrolment predates template storage,
  so the bytes exist solely in the sensor that captured them. Enrol that teacher
  once more, on any terminal, and every reader gets them.
- *n failed* — the sensor refused the write. That is a hardware fault, not a
  finger; the terminal will not retry on its own.

**Sessions stay open past the end of the period.** The worker is not running.
`systemctl status lsiams-worker`.

**The connection pill shows "polling".** The WebSocket server is unreachable, so
the front-end degraded. Everything still works, with a few seconds more latency.
`systemctl status lsiams-realtime`, and check that 8443 is open and that the
terminal's TLS certificate covers the address in `REALTIME_WS_PUBLIC_URL`.

**"Database busy, retrying the transaction" appears in the log.** A write waited
longer than `DB_BUSY_TIMEOUT_MS` for another one and was retried. Occasional
retries under a burst of taps are handled. If it is constant, something is
holding a write transaction open — look for a console command or a script left
running against the file.

**"attempt to write a readonly database".** The database file or its folder is
not writable by the account running PHP, usually because a command was run as
root and created the `-wal` file. `chown -R www-data:www-data storage/database`.
