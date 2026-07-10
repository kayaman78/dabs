# DABS — Docker Automated Backup for SQLite

## File
- `sqlite-backup.sh` — script unico
- `README.md` — documentazione

## Flusso (4 fasi)
1. **SCAN** — trova `.db/.sqlite/.sqlite3` (min 10KB) sotto `BASE_DIR`, verifica header SQLite, mappa a container via docker inspect, raggruppa per service. `EXCLUDED_SERVICES` applicato qui.
2. **BACKUP+VERIFY** — stop service → gzip DB (+WAL/SHM) → start → verify 3-step. Stderr catturato su failure.
3. **RETENTION** — N-most-recent per DB (`_files_to_rotate`). Stessa policy per log.
4. **NOTIFICHE** — email HTML (swaks), Telegram, ntfy (indipendenti).

## Verify 3-step
1. `gzip -t` integrità
2. decompress temp + `sqlite3 PRAGMA integrity_check`
3. size drop vs backup precedente (warn se > `SIZE_DROP_WARN`%)

## Exit code
`exit 1` se `COUNT_ERR > 0`, altrimenti `exit 0`. KCR rileva il fallimento.

## Config (variabili top script)
`DRY_RUN`, `BASE_DIR`, `BACKUP_ROOT`, `RETENTION_DAYS`, `STOP_TIMEOUT`, `SIZE_DROP_WARN`, `EXCLUDED_SERVICES`, SMTP, Telegram, ntfy.

## Dipendenze (auto-installate)
`file`, `jq`, `swaks`, `gzip`, `sqlite3`, `curl` — richiede root, Debian/Ubuntu.

## Lanciato da KCR
```json
{ "server_name": "prod", "commands": ["bash /srv/docker/dabs/sqlite-backup.sh"], "timeout_seconds": 600 }
```
