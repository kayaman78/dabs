# DABS — Docker Automated Backup for SQLite

**Project Status**: Active | **Version**: 1.2 | **Maintained**: Yes

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Docker](https://img.shields.io/badge/docker-required-blue.svg)](https://www.docker.com/)
[![Platform](https://img.shields.io/badge/platform-Debian%20%2F%20Ubuntu-informational.svg)](https://www.debian.org/)

Automatic SQLite backup script for Docker environments. Discovers SQLite databases mounted by running containers, stops each service briefly, creates compressed backups, restarts the service, and immediately verifies the backup integrity. Sends an HTML email report on completion.

> Part of the **KDD ecosystem** — see also [KDD](https://github.com/kayaman78/kdd) for MySQL / PostgreSQL / MongoDB backups and [KCR](https://github.com/kayaman78/kcr) to run DABS from a Komodo Action.

---

## Features

- **Auto-discovery** — scans compose files under `BASE_DIR` and finds `.db`, `.sqlite`, `.sqlite3` files
- **Service-aware** — groups multiple databases per service: one stop/start per service, not per file
- **WAL support** — backs up `-wal` and `-shm` files alongside the main database
- **Backup verification** — every backup is verified immediately after creation (see below)
- **Retention** — auto-deletes backups and logs older than `RETENTION_DAYS`
- **Email report** — color-coded HTML email with separate Backup and Verify columns per database
- **Push notifications** — optional Telegram and ntfy alerts, fully independent from each other and from email
- **Dry-run mode** — scan and report without touching anything
- **Exclusion list** — skip specific services by name
- **Auto-install** — installs missing dependencies via `apt-get` on first run

---

## How Verification Works

After each backup is created, DABS runs three checks in sequence. A backup must pass all three to be marked OK.

**1. gzip integrity**
Runs `gzip -t` on the `.gz` file. Catches truncated or corrupt archives produced by write errors or disk issues.

**2. SQLite integrity check**
Decompresses the backup to a temporary file and runs `PRAGMA integrity_check` via `sqlite3`. This is SQLite's built-in consistency check — it verifies the B-tree structure, page consistency, and internal pointers. Returns `ok` if the database is intact. The temp file is deleted immediately after.

**3. Size trend**
Compares the size of the new backup against the most recent previous backup for the same database. If the new file is smaller by more than `SIZE_DROP_WARN`% (default: 20%), the verify is marked WARN with the old and new sizes shown. This catches silent data loss — for example a service that truncated its database or a misconfiguration that wiped tables.

### Verify vs Backup status in the email

| Backup | Verify | Meaning |
|--------|--------|---------|
| OK | OK | Backup written and verified clean |
| OK | WARN | Backup valid but size dropped unexpectedly — investigate |
| OK | FAIL | Backup written but corrupt — do not rely on it |
| ERROR | skipped | Backup failed, verify not attempted |

A WARN does not block the process — the backup is kept and the service continues. A FAIL sets the global status to ERROR and is highlighted in the email subject.

---

## Requirements

- Debian / Ubuntu host
- Root or `sudo` access
- Docker installed

Dependencies installed automatically if missing: `file`, `jq`, `swaks`, `gzip`, `sqlite3`.

---

## Configuration

All settings are at the top of the script.

```bash
DRY_RUN="off"                          # "on" to simulate without writing anything. use this at first attempt
BASE_DIR="/srv/docker"                 # Root directory to scan for compose files
BACKUP_ROOT="/srv/docker/dabs/backups" # Root directory where backups will be stored
RETENTION_DAYS=7                       # How many days to keep backups and logs
STOP_TIMEOUT=60                        # Seconds to wait for container stop before proceeding
SIZE_DROP_WARN=20                      # % size drop vs previous backup that triggers a warning

EXCLUDED_SERVICES=()                   # Exact compose service names to skip

SMTP_SERVER="smtp.example.com"
SMTP_PORT="587"         # 25 = plain relay | 465 = SMTPS | 587 = STARTTLS
SMTP_USER=""            # Leave empty for unauthenticated relay
SMTP_PASS=""

EMAIL_FROM="dabs@example.com"
EMAIL_TO="admin@example.com"
EMAIL_SUBJECT_PREFIX="SQLite Backup"

# Telegram (optional)
TELEGRAM_ENABLED="false"
TELEGRAM_TOKEN=""
TELEGRAM_CHAT_ID=""

# ntfy (optional)
NTFY_ENABLED="false"
NTFY_URL=""             # e.g. https://ntfy.sh or your self-hosted instance
NTFY_TOPIC=""           # e.g. dabs-backups

# Attach log to push notifications
NOTIFY_ATTACH_LOG="false"
```

> **TLS is selected automatically by port**: 465 → SMTPS, 587 → STARTTLS, anything else → plain.

---

## Notifications

DABS supports three independent notification channels. Each can be enabled or disabled without affecting the others.

### Email

Full HTML report with color-coded table, per-database Backup and Verify status. Best for detailed post-run review.

### Telegram

Compact message sent to a bot or channel. Requires a bot token and chat ID.

Example message:
```
DABS Backup — myserver | 2025-01-15 03:00
SQLite 3 OK 0 ERR (total: 3)
Verify 3 OK 0 WARN 0 ERR
```

### ntfy

Sends a push notification to any ntfy-compatible client (ntfy.sh or self-hosted). Priority is set automatically: default on success, urgent on any backup or verify error.

### Log attachment

Set `NOTIFY_ATTACH_LOG="true"` to attach the current day's log file to both Telegram and ntfy notifications. Useful to inspect errors directly from the phone without opening SSH.

---

## Backup Structure

```
BACKUP_ROOT/
├── <service-name>/
│   ├── <db-name>_20250115_030000.gz
│   ├── <db-name>_20250115_030000-wal.gz   # if WAL file present
│   └── <db-name>_20250115_030000-shm.gz   # if SHM file present
└── log/
    └── backup-sqlite_20250115.log
```

---

## Usage

```bash
# Run manually as root
sudo bash backup-sqlite.sh

# Schedule via cron — daily at 3 AM
0 3 * * * /bin/bash /srv/docker/dabs/backup-sqlite.sh
```

### Running from Komodo via KCR

Use [KCR](https://github.com/kayaman78/kcr) to trigger DABS directly from a Komodo Action:

```json
{
  "server_name": "your-server",
  "run_as": "root",
  "commands": ["bash /srv/docker/dabs/backup-sqlite.sh"],
  "stop_on_error": true
}
```

Then combine it with a KDD Action inside a **Komodo Procedure** for full database coverage in one scheduled job.

---

## How It Works

1. Finds all compose files under `BASE_DIR`
2. Locates `.db` / `.sqlite` / `.sqlite3` files (min 10 KB, valid SQLite header verified)
3. Matches each file to a running container via Docker mount inspection
4. Groups databases by service name
5. For each service: stops it → compresses all its databases with `gzip` → restarts it
6. Verifies each backup: gzip integrity + `PRAGMA integrity_check` + size trend
7. Applies retention policy — removes old `.gz` files and logs
8. Sends email report, Telegram message, and/or ntfy alert — each independently

---

## Changelog

### v1.2
- Added Telegram push notifications (independent of email and ntfy)
- Added ntfy push notifications (independent of email and Telegram)
- Added `NOTIFY_ATTACH_LOG` option to attach the daily log to push notifications
- ntfy priority set to urgent automatically on backup or verify errors

### v1.1
- Added backup verification (gzip integrity, `PRAGMA integrity_check`, size trend)
- Added `SIZE_DROP_WARN` setting (default: 20%)
- Added `sqlite3` to auto-installed dependencies
- Email report now has separate Backup and Verify columns
- Global status now distinguishes OK / WARN / ERROR
- Email subject reflects verify outcome

### v1.0
- Initial release

---

## Notes

- Databases not mounted by any running container are skipped automatically
- Services in `EXCLUDED_SERVICES` are ignored entirely — useful for services like Home Assistant that manage their own backups
- Log files rotate with the same retention policy as backups

---

## Related Projects

| Project | Description |
|---------|-------------|
| [KDD](https://github.com/kayaman78/kdd) | Docker backup for MySQL, PostgreSQL, MongoDB |
| [KCR](https://github.com/kayaman78/kcr) | Komodo Action to run shell commands on remote servers |

---

## License

MIT