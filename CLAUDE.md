# DABS — Docker Automated Backup for SQLite

## File
- `sqlite-backup.sh` — script unico
- `volumes.conf` — generato da `--setup`, non versionato
- `README.md` — documentazione

## Flusso (4 fasi)
1. **SCAN** — due sorgenti, stesso filtro:
   - **1a** `.db/.sqlite/.sqlite3` (min 10KB) sotto `BASE_DIR`, accanto ai compose
   - **1b** stessi tipi dentro i **volumi nominati** dei container vivi
   Entrambe passano da `register_db()`: header SQLite verificato con `file`, mappatura a container via docker inspect, raggruppamento per service, `EXCLUDED_SERVICES` applicato.
2. **BACKUP+VERIFY** — stop service → gzip DB (+WAL/SHM) → start → verify 3-step. Stderr catturato su failure.
3. **RETENTION** — N-most-recent per DB (`_files_to_rotate`). Stessa policy per log.
4. **NOTIFICHE** — email HTML (swaks), Telegram, ntfy (indipendenti).

## Perché la fase 1b esiste
Un DB in volume nominato non ha path sotto `BASE_DIR`: la 1a non lo raggiunge **e non lo dice**. Riporta un giro pulito e il database non è salvato. Il `Source` di un volume è un path host vero, quindi tutto ciò che sta a valle (lookup del service, stop, verify) funziona già.

## ⚠️ `DB_IMAGE_PATTERNS` — non è ordine, è una guardia
Stessa lista di DABV, apposta. I motori di database scrivono SQLite veri nelle proprie data dir come scratch (PostgreSQL + `vchord`). Senza la guardia, DABS li troverebbe, li attribuirebbe al service `postgres` e **fermerebbe il DB di produzione ogni notte** per copiare un file temporaneo — con il report che dice OK. Quei file stanno spesso appena sotto i 10KB: **la soglia non è la protezione, la lista sì.**

## `--setup` — l'unica modalità interattiva
Il giro notturno (cron/KCR) non chiede mai niente: un prompt lì appenderebbe il job fino al timeout. `--setup` scansiona, mostra i DB per volume, chiede, scrive `volumes.conf`. Il run legge e basta.
- `SCAN_VOLUMES="on"|"off"` — interruttore generale
- Nessun `volumes.conf` = tutti i volumi non-database

## ⚠️ Trappola pagata addosso (S592): `read` dentro un `while` con process substitution
`done < <(...)` ridirige lo stdin **dell'intero blocco**, quindi un `read` interattivo dentro il loop consuma la process substitution, non le risposte dell'utente. Torna riga vuota → ogni prompt veniva letto come «sì». Cura: `exec 3<&0` prima dei loop e `read -u 3`. E un `read` fallito **esce**, non assume «include»: un default silenzioso qui ti iscrive a fermare un servizio ogni notte.

## Verify 3-step
1. `gzip -t` integrità
2. decompress temp + `sqlite3 PRAGMA integrity_check`
3. size drop vs backup precedente (warn se > `SIZE_DROP_WARN`%)

## Exit code
`exit 1` se `COUNT_ERR > 0`, altrimenti `exit 0`. KCR rileva il fallimento.

## Config (variabili top script)
`DRY_RUN`, `BASE_DIR`, `BACKUP_ROOT`, `RETENTION_DAYS`, `STOP_TIMEOUT`, `SIZE_DROP_WARN`, `EXCLUDED_SERVICES`, `SCAN_VOLUMES`, `VOLUMES_CONFIG_FILE`, `DB_IMAGE_PATTERNS`, SMTP, Telegram, ntfy.

## Dipendenze (auto-installate)
`file`, `jq`, `swaks`, `gzip`, `sqlite3`, `curl` — richiede root, Debian/Ubuntu.

## Lanciato da KCR
```json
{ "server_name": "prod", "commands": ["bash /srv/docker/dabs/sqlite-backup.sh"], "timeout_seconds": 600 }
```

## Ecosistema (5 tool)
KDD (MySQL/PG/Mongo) · **DABS** (SQLite) · DABV (volumi Docker) · DABR (path e file) · KCR (esegue i bash da Komodo)
