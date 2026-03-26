# DABS — Docker Automated Backup for SQLite

## Scopo
Script Bash standalone che esegue backup automatici di database SQLite in ambienti Docker. Scopre automaticamente i DB dai compose file, ferma gracefully i container, comprime e verifica i backup.

## File
- `sqlite-backup.sh` — script principale, unico entry point
- `README.md` — documentazione utente

## Flusso principale (4 fasi)
1. **SCAN** — cerca `.db/.sqlite/.sqlite3` (min 10KB) sotto `BASE_DIR`, verifica header SQLite, mappa ai container via `docker inspect`, raggruppa per service name
2. **BACKUP+VERIFY** — stop service → `gzip` DB (+ WAL/SHM files con error handling) → riavvia → 3-step verify
3. **RETENTION** — rimuove `.gz` e log con `-mtime +"$((RETENTION_DAYS - 1))"`, pulisce dir vuote
4. **NOTIFICHE** — email HTML, Telegram, ntfy (indipendenti, ognuno con proprio `enabled` flag)

## Verifica 3-step
1. `gzip -t` — integrità archivio
2. decompress temp + `sqlite3 PRAGMA integrity_check` — integrità DB
3. confronto size vs backup precedente — warning se calo > `SIZE_DROP_WARN`%

## WAL/SHM handling
Dopo il backup del file `.db` principale, tenta di comprimere anche i file `-wal` e `-shm` se presenti. Se `gzip` fallisce su questi file ausiliari: rimuove il file parziale e logga un warning (non conta come errore del backup principale, che è già stato completato).

## Configurazione (variabili top script)
```bash
DRY_RUN="off"
BASE_DIR="/srv/docker"          # root per discover compose files
BACKUP_ROOT="/srv/docker/dabs/backups"
RETENTION_DAYS=7
STOP_TIMEOUT=60                 # secondi attesa stop container
SIZE_DROP_WARN=20               # % calo size che triggera warning
EXCLUDED_SERVICES=()

# SMTP via swaks (25/465/587 — auto-TLS)
SMTP_SERVER, SMTP_PORT, EMAIL_FROM, EMAIL_TO

# Push notifications (ciascuno indipendente)
TELEGRAM_ENABLED="false"
NTFY_ENABLED="false"
```

## Output struttura
```
BACKUP_ROOT/
├── <service-name>/
│   ├── app.db_YYYYMMDD_HHMMSS.gz
│   └── app.db_YYYYMMDD_HHMMSS-wal.gz   # solo se presente
└── log/
    └── backup-sqlite_YYYYMMDD.log
```

## Dipendenze (auto-installate se mancanti)
`file`, `jq`, `swaks`, `gzip`, `sqlite3`, `curl` — richiede root, piattaforma Debian/Ubuntu

## Integrazione nell'ecosistema
Viene lanciato da **KCR** (Komodo Command Runner) come action schedulata:
```json
{
  "server_name": "prod",
  "run_as": "root",
  "commands": ["bash /srv/docker/dabs/backup-sqlite.sh"],
  "timeout_seconds": 600
}
```

## Coerenza con l'ecosistema
- Retention: usa `-mtime +"$((RETENTION_DAYS - 1))"` — identico a DABV
- Notifiche: struttura `send_telegram` / `send_ntfy` / `build_text_summary` — identica a DABV
- Email: via `swaks` — identico a DABV (KDD usa `msmtp`)

## Non implementato (by design o low-priority)
- Backup su storage remoto (S3, rsync)
- Encryption at rest
- Parallelizzazione (sequenziale per safety)
- Retry su errori transitori
