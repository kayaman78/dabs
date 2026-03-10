# DABS — Docker Automated Backup for SQLite

**Version**: 1.0 | **Status**: Active | **Platform**: Debian / Ubuntu

Automatic SQLite backup script for Docker environments. Discovers SQLite databases mounted by running containers, stops each service briefly, creates compressed backups, then restarts the service. Sends an HTML email report on completion.

---

## Features

- **Auto-discovery** — scans compose files under `BASE_DIR` and finds `.db`, `.sqlite`, `.sqlite3` files
- **Service-aware** — groups multiple databases per service: one stop/start per service, not per file
- **WAL support** — backs up `-wal` and `-shm` files alongside the main database
- **Retention** — auto-deletes backups and logs older than `RETENTION_DAYS`
- **Email report** — color-coded HTML email via `swaks` (green/red status per database)
- **Dry-run mode** — scan and report without touching anything
- **Exclusion list** — skip specific services by name
- **Auto-install** — installs missing dependencies via `apt-get` on first run

---

## Requirements

- Debian / Ubuntu host
- Root or `sudo` access
- Docker installed

Dependencies installed automatically if missing: `file`, `jq`, `swaks`, `gzip`.

---

## Configuration

All settings are at the top of the script.

```bash
DRY_RUN="off"                          # "on" to simulate without writing anything
BASE_DIR="/srv/docker"                 # Root path to scan for compose files
BACKUP_ROOT="/srv/docker/kdd/sqlite"   # Where backups are stored
RETENTION_DAYS=7                       # Days to keep backups and logs
STOP_TIMEOUT=60                        # Seconds to wait for container stop

EXCLUDED_SERVICES=("homeassistant" "pihole")  # Services to skip (exact compose service name)

SMTP_SERVER="192.168.7.5"
SMTP_PORT="25"          # 25 = plain | 465 = SMTPS | 587 = STARTTLS
SMTP_USER=""            # Leave empty for unauthenticated relay
SMTP_PASS=""

EMAIL_FROM="alert@example.com"
EMAIL_TO="admin@example.com"
EMAIL_SUBJECT_PREFIX="Backup SQLite"
```

> **TLS is selected automatically by port**: 465 → SMTPS, 587 → STARTTLS, anything else → plain.

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

Or trigger via a [Komodo](https://github.com/mbecker20/komodo) Action using [KCR](https://github.com/kayaman78/kdd):

```json
{
  "server_name": "your-server",
  "run_as": "root",
  "commands": ["bash /srv/docker/dabs/backup-sqlite.sh"],
  "stop_on_error": true
}
```

---

## How It Works

1. Finds all compose files under `BASE_DIR`
2. Locates `.db` / `.sqlite` / `.sqlite3` files (min 10 KB, valid SQLite header verified)
3. Matches each file to a running container via Docker mount inspection
4. Groups databases by service name
5. For each service: stops it → compresses all its databases with `gzip` → restarts it
6. Applies retention policy — removes old `.gz` files and logs
7. Sends a color-coded HTML email report

---

## Notes

- Databases not mounted by any running container are skipped automatically
- Services in `EXCLUDED_SERVICES` are ignored entirely — useful for services like Home Assistant that manage their own backups
- Log files rotate with the same retention policy as backups

---

## License

MIT