# DABS — Docker Automated Backup for SQLite

**Project Status**: Active | **Version**: 1.7 | **Maintained**: Yes

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Docker](https://img.shields.io/badge/docker-required-blue.svg)](https://www.docker.com/)
[![Platform](https://img.shields.io/badge/platform-Debian%20%2F%20Ubuntu-informational.svg)](https://www.debian.org/)

Automatic SQLite backup script for Docker environments. Discovers SQLite databases used by running containers — both in bind mounts and in **named volumes** — stops each service briefly, creates compressed backups, restarts the service, and immediately verifies the backup integrity. Sends an HTML email report on completion.

> Part of the **KDD ecosystem** — see also [KDD](https://github.com/kayaman78/kdd) for MySQL / PostgreSQL / MongoDB, [DABV](https://github.com/kayaman78/dabv) for Docker volumes, [DABR](https://github.com/kayaman78/dabr) for host paths, and [KCR](https://github.com/kayaman78/kcr) to run DABS from a Komodo Action.

---

## Features

- **Auto-discovery** — scans compose files under `BASE_DIR` and finds `.db`, `.sqlite`, `.sqlite3` files
- **Named volume support** — also scans the named volumes of running containers, so databases with no path under `BASE_DIR` are still found
- **Database volumes skipped** — volumes belonging to database engines are left to KDD, never opened by DABS
- **Service-aware** — groups multiple databases per service: one stop/start per service, not per file
- **WAL support** — backs up `-wal` and `-shm` files alongside the main database
- **Backup verification** — every backup is verified immediately after creation (see below)
- **Retention** — keeps the `RETENTION_DAYS` most recent dumps per database (calendar-independent — pause-safe)
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

Dependencies installed automatically if missing: `file`, `jq`, `swaks`, `gzip`, `sqlite3`, `curl`.

---

## Configuration

All settings are at the top of the script.

```bash
DRY_RUN="off"                          # "on" to simulate without writing anything
BASE_DIR="/srv/docker"                 # Root directory to scan for compose files
BACKUP_ROOT="/srv/docker/dabs/backups" # Root directory where backups will be stored
RETENTION_DAYS=7                       # Number of most recent dumps to keep per database (calendar-independent)
STOP_TIMEOUT=60                        # Seconds to wait for container stop before proceeding
SIZE_DROP_WARN=20                      # % size drop vs previous backup that triggers a warning

EXCLUDED_SERVICES=()                   # Exact compose service names to skip

# Container images whose named volumes are never scanned (data belongs to KDD).
# Substring match on the image name — add your own engines if you run any.
DB_IMAGE_PATTERNS=("postgres" "mysql" "mariadb" "mongo" "redis" "timescaledb" "postgis")

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
sudo bash sqlite-backup.sh

# Schedule via cron — daily at 3 AM
0 3 * * * /bin/bash /srv/docker/dabs/sqlite-backup.sh
```

### Running from Komodo via KCR

Use [KCR](https://github.com/kayaman78/kcr) to trigger DABS directly from a Komodo Action:

```json
{
  "server_name": "your-server",
  "run_as": "root",
  "commands": ["bash /srv/docker/dabs/sqlite-backup.sh"],
  "stop_on_error": true
}
```

Then combine it with a KDD Action and a DABV step inside a **Komodo Procedure** for full coverage in one scheduled job.

---

## How It Works

1. Finds all compose files under `BASE_DIR`
2. Locates `.db` / `.sqlite` / `.sqlite3` files (min 10 KB, valid SQLite header verified)
3. Scans the **named volumes** of every running container for the same file types, skipping containers whose image is a database engine
4. Matches each file to a running container via Docker mount inspection
5. Groups databases by service name
6. For each service: stops it → compresses all its databases with `gzip` → restarts it
7. Verifies each backup: gzip integrity + `PRAGMA integrity_check` + size trend
8. Applies retention policy — keeps the N most recent `.gz` files per database (and logs); older ones removed only when replaced
9. Sends email report, Telegram message, and/or ntfy alert — each independently

---

## Named volumes — why they need their own scan

A database in a named volume has no path under `BASE_DIR`, so the compose scan
can never reach it. The failure mode is the dangerous one: DABS finds nothing,
reports a clean run, and the database is simply never backed up. Nothing in the
email says so.

The mount `Source` of a named volume *is* a real host path
(`/var/lib/docker/volumes/<name>/_data`), so once the file is found everything
downstream — matching it to a service, stopping that service, verifying the
archive — works exactly as it does for bind mounts.

### Choosing which volumes to include — `--setup`

Backing up a database means stopping its service for the duration of the copy,
so the volume scan is worth a deliberate answer rather than a default. Run:

```bash
sudo bash sqlite-backup.sh --setup
```

It walks the named volumes of running containers, shows the SQLite databases
found in each one and which service would be stopped, asks, and writes
`volumes.conf`:

```
# DABS volume config — generated 2026-09-01 13:20
# Format:  <volume name>: include | exclude
myapp-data: include
cache-data: exclude
```

Edit that file directly anytime — no need to re-run `--setup`. A volume not
listed is included.

**The nightly run never asks anything.** It is started by cron or KCR, where a
prompt would hang the job until the timeout: `--setup` is the only interactive
mode, and the run just reads the answer. Two switches control it:

| Setting | Effect |
|---|---|
| `SCAN_VOLUMES="off"` | volume scan disabled entirely, back to pre-1.7 behaviour |
| `VOLUMES_CONFIG_FILE` | path of the file written by `--setup`; if absent, every non-database volume is scanned |

### Database volumes are skipped on purpose

Volumes belonging to a database engine are never scanned. The `DB_IMAGE_PATTERNS`
list at the top of the script matches the container image:

```bash
DB_IMAGE_PATTERNS=("postgres" "mysql" "mariadb" "mongo" "redis" "timescaledb" "postgis")
```

This is the same list DABV uses, deliberately: the two tools must agree on what
counts as a database.

The reason is not tidiness. Database engines write real SQLite files into their
own data directories as scratch space — PostgreSQL with the `vchord` vector
extension is one example. Without this guard, DABS would find such a file,
attribute it to the `postgres` service, and **stop your production database
every night to copy a temporary file**. Nothing would look wrong: the report
would show a successful backup.

Those scratch files are often just under the 10 KB threshold, which means a
setup can look fine for months and start stopping the database the day they
grow. The size threshold is not a safety mechanism — this list is.

Data inside database volumes belongs to [KDD](https://github.com/kayaman78/kdd),
which takes proper logical dumps without stopping anything.

---

## Updating

The script logic and your configuration live in the same file (`sqlite-backup.sh`), so updating requires a quick two-step process to avoid overwriting your settings.

**1. Save your current configuration**

Your settings are at the top of the script (everything above the `INITIAL CHECKS` block). Copy that section somewhere before replacing the file.

**2. Replace the script**

```bash
curl -sL https://raw.githubusercontent.com/kayaman78/dabs/main/sqlite-backup.sh \
  -o /srv/docker/dabs/sqlite-backup.sh
```

**3. Re-apply your settings**

Paste your configuration block back at the top of the new script.

---

### Updating from Komodo (recommended)

Create a KCR Action to handle the download step on each server, then re-apply settings manually:

```json
{
  "server_name": "your-server",
  "run_as": "root",
  "commands": [
    "cp /srv/docker/dabs/sqlite-backup.sh /srv/docker/dabs/sqlite-backup.sh.bak",
    "curl -sL https://raw.githubusercontent.com/kayaman78/dabs/main/sqlite-backup.sh -o /srv/docker/dabs/sqlite-backup.sh.new"
  ]
}
```

This downloads the new version alongside the old one. You can then diff them, identify only what changed (see the [Changelog](#changelog) for guidance), and apply the code changes manually — leaving your configuration block untouched.

> **Tip**: If you manage multiple servers, duplicate this Action and change `server_name` for each one. The process is the same across all of them.

---

## Changelog

### v1.7
- **`--setup` mode** — interactive volume discovery, writes `volumes.conf`. The nightly run stays fully non-interactive. Plus `SCAN_VOLUMES` to switch the whole thing off.
- **Named volumes are now scanned.** Databases living in a named volume have no path under `BASE_DIR`, so the compose scan never reached them — DABS reported a clean run and backed up nothing. Found on a real setup: a 3.7 MB SQLite database had never been backed up, and no report ever said so.
- **`DB_IMAGE_PATTERNS` guard** — volumes of database engines are skipped, same list as DABV. Without it, PostgreSQL's `vchord` scratch SQLite files would be picked up and the production database stopped nightly to copy them. They currently sit just under the 10 KB threshold, so the problem appears only once they grow: the threshold was never the safeguard.
- **The stop is now verified.** After stopping a service, DABS checks that no container with that service label is still running. If one is, the copy still happens — a doubtful backup beats no backup — but the row is marked `OK (HOT — service did not stop)` and the global status becomes WARN, instead of reporting a clean green backup of a live database.
- **Multi-file compose projects** — the container label lists compose files comma-separated. They were passed to `docker compose -f` as one string, which fails, so the service would not be stopped before the copy. Each file now gets its own `-f`.
- Scan logic extracted into `register_db()`, shared by both phases so they cannot drift apart.

### v1.6
- Stderr on gzip failures is now captured and logged instead of hidden.
- Proper exit code: `exit 1` if any backup failed, `exit 0` otherwise. KCR can now detect failures.

### v1.5
- Fixed `build_text_summary()` in dry-run mode — push notifications (Telegram/ntfy) were showing `0✅ 0❌ (total: 0)` instead of dry-run info; now show `🔍 DABS DRY-RUN — N database(s) found. No backups written.`

### v1.4
- Fixed dry-run mode: retention phase was executing `rm -f` even with `DRY_RUN=on`, deleting real backups and logs while reporting "no filesystem changes"
- Dry-run now shows a preview of what retention would remove without touching anything
- Email report in dry-run mode includes a retention preview line when files would be affected

### v1.3
- Fixed missing `curl` dependency — was used by Telegram and ntfy notifications but not auto-installed, causing silent failures when both email and push were configured
- Fixed WAL/SHM backup error handling — on `gzip` failure for auxiliary files, the partial archive is now removed and a warning is logged; the main database backup is unaffected
- Updated auto-install list to include `curl`

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
| [DABV](https://github.com/kayaman78/dabv) | Docker automated backup for volumes |
| [DABR](https://github.com/kayaman78/dabr) | Hardlinked snapshots of host paths |
| [KCR](https://github.com/kayaman78/kcr) | Komodo Action to run shell commands on remote servers |

---

## License

MIT