# DABS — Docker Automated Backup for SQLite

**Project Status**: Active | **Version**: 1.0 | **Maintained**: Yes

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Docker](https://img.shields.io/badge/docker-required-blue.svg)](https://www.docker.com/)
[![Platform](https://img.shields.io/badge/platform-Debian%20%2F%20Ubuntu-informational.svg)](https://www.debian.org/)

Automatic SQLite backup script for Docker environments. Discovers SQLite databases mounted by running containers, stops each service briefly, creates compressed backups, then restarts the service. Sends an HTML email report on completion.

> Part of the **KDD ecosystem** — see also [KDD](https://github.com/kayaman78/kdd) for MySQL / PostgreSQL / MongoDB backups and [KCR](https://github.com/kayaman78/kcr) to run DABS from a Komodo Action.

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
BASE_DIR="/srv/docker"                 # Root directory to scan for compose files
BACKUP_ROOT="/srv/docker/dabs/backups" # Root directory where backups will be stored
RETENTION_DAYS=7                       # How many days to keep backups and logs
STOP_TIMEOUT=60                        # Seconds to wait for container stop before proceeding

EXCLUDED_SERVICES=()                   # Exact compose service names to skip

SMTP_SERVER="smtp.example.com"
SMTP_PORT="587"         # 25 = plain relay | 465 = SMTPS | 587 = STARTTLS
SMTP_USER=""            # Leave empty for unauthenticated relay
SMTP_PASS=""

EMAIL_FROM="dabs@example.com"
EMAIL_TO="admin@example.com"
EMAIL_SUBJECT_PREFIX="SQLite Backup"
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
6. Applies retention policy — removes old `.gz` files and logs
7. Sends a color-coded HTML email report

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