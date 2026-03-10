#!/usr/bin/env bash
# ==============================================================================
# DABS — Docker Automated Backup for SQLite
# Version: 1.0
# Platform: Debian / Ubuntu
# https://github.com/youruser/dabs
# ==============================================================================

# --- GENERAL SETTINGS ---
DRY_RUN="off"                              # [on/off] — set to "on" to simulate without writing anything
BASE_DIR="/srv/docker"                     # Root directory to scan for compose files
BACKUP_ROOT="/srv/docker/dabs/backups"     # Root directory where backups will be stored
RETENTION_DAYS=7                           # How many days to keep backups and logs
STOP_TIMEOUT=60                            # Seconds to wait for container stop before proceeding

# Services to skip — exact compose service names (com.docker.compose.service label)
# Example: EXCLUDED_SERVICES=("homeassistant" "pihole")
EXCLUDED_SERVICES=()

# --- SMTP SETTINGS ---
SMTP_SERVER="smtp.example.com"
SMTP_PORT="587"         # 25 = plain relay | 465 = SMTPS (immediate SSL) | 587 = STARTTLS
SMTP_USER=""            # Leave empty for unauthenticated relay
SMTP_PASS=""

# --- EMAIL SETTINGS ---
EMAIL_FROM="dabs@example.com"
EMAIL_TO="admin@example.com"

# Subject prefix — hostname and date are appended automatically.
# Final result: "[✅ OK] Backup SQLite | myserver | 2025-01-15 03:00"
EMAIL_SUBJECT_PREFIX="SQLite Backup"

# ==============================================================================
# INITIAL CHECKS
# ==============================================================================
[[ $EUID -ne 0 ]] && echo "Error: run as root or with sudo." && exit 1

# Daily log file (does not grow indefinitely)
LOG_DIR="$BACKUP_ROOT/log"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/backup-sqlite_$(date +%Y%m%d).log"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

# Docker is mandatory
if ! command -v docker &>/dev/null; then
    echo "FATAL ERROR: 'docker' not found. Cannot continue." >&2
    exit 1
fi

# Auto-install missing dependencies (Debian/Ubuntu)
declare -A DEP_MAP=(
    [file]="file"
    [jq]="jq"
    [swaks]="swaks"
    [gzip]="gzip"
)

MISSING_PKGS=()
for cmd in "${!DEP_MAP[@]}"; do
    command -v "$cmd" &>/dev/null || MISSING_PKGS+=("${DEP_MAP[$cmd]}")
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "[*] Installing missing dependencies: ${MISSING_PKGS[*]}"
    apt-get update -qq && apt-get install -y -qq "${MISSING_PKGS[@]}"
fi

# ==============================================================================
# WORKING VARIABLES
# ==============================================================================
DATE_ID=$(date +%Y%m%d_%H%M%S)
DATE_LABEL=$(date "+%Y-%m-%d %H:%M")
HOSTNAME=$(hostname)

TABLE_ROWS=""
GLOBAL_STATUS="OK"
declare -A SEEN_DBS  # prevents double-processing the same db path
COUNT_OK=0
COUNT_ERR=0
COUNT_DRY=0

echo "============================================================"
echo "START SQLite Backup: $(date) — Host: $HOSTNAME"
echo "Mode: $([ "$DRY_RUN" == "on" ] && echo "DRY-RUN (no backup will be written)" || echo "PRODUCTION")"
if [ ${#EXCLUDED_SERVICES[@]} -gt 0 ]; then
    echo "Excluded services: ${EXCLUDED_SERVICES[*]}"
fi
echo "============================================================"

# ==============================================================================
# PHASE 1 — SCAN: collect all databases grouped by service
# Stop/start happens once per service, even if it has multiple databases.
# ==============================================================================
declare -A SERVICE_DBS   # SERVICE_DBS[svc]="path1\npath2\n..."
declare -A SERVICE_CF    # SERVICE_CF[svc]="/path/to/compose.yml"

mapfile -t COMPOSE_FILES < <(
    find "$BASE_DIR" -type f \( -name "compose.y*ml" -o -name "docker-compose.y*ml" \) \
    -not -path "$BACKUP_ROOT/*"
)

if [ ${#COMPOSE_FILES[@]} -eq 0 ]; then
    echo "[!] No compose files found under $BASE_DIR"
fi

# Cache mounts to avoid repeated docker inspect calls per database
declare -A CID_SVC    # CID_SVC[cid]=service_name
declare -A CID_MOUNTS # CID_MOUNTS[cid]="src1\nsrc2\n..."
while IFS= read -r cid; do
    SVC=$(docker inspect "$cid" --format '{{index .Config.Labels "com.docker.compose.service"}}' 2>/dev/null)
    [ -z "$SVC" ] && continue
    CID_SVC[$cid]="$SVC"
    CID_MOUNTS[$cid]=$(docker inspect "$cid" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' 2>/dev/null)
done < <(docker ps -q)

for cf in "${COMPOSE_FILES[@]}"; do
    STACK_DIR=$(dirname "$cf")

    mapfile -t SQL_FILES < <(
        find "$STACK_DIR" -type f \( -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite3" \) \
        -not -path "$BACKUP_ROOT/*" -size +10k
    )

    for db_path in "${SQL_FILES[@]}"; do
        [[ -n "${SEEN_DBS[$db_path]}" ]] && continue
        SEEN_DBS[$db_path]=1

        # Verify SQLite header
        if ! file "$db_path" | grep -q "SQLite 3.x database"; then
            echo "[~] Skipped (not SQLite): $db_path"
            continue
        fi

        if [ ${#CID_SVC[@]} -eq 0 ]; then
            echo "[~] Skipped (no running containers): $db_path"
            continue
        fi

        # Find the service mounting this db — longest matching source wins
        SERVICE_NAME=""
        BEST_LEN=0
        for cid in "${!CID_SVC[@]}"; do
            SVC="${CID_SVC[$cid]}"
            while IFS= read -r src; do
                [ -z "$src" ] && continue
                if [[ "$db_path" == "$src/"* ]] || [[ "$db_path" == "$src" ]]; then
                    if [ ${#src} -gt $BEST_LEN ]; then
                        BEST_LEN=${#src}
                        SERVICE_NAME="$SVC"
                    fi
                fi
            done <<< "${CID_MOUNTS[$cid]}"
        done

        if [ -z "$SERVICE_NAME" ] || [ "$SERVICE_NAME" == "null" ]; then
            echo "[~] Skipped (no active container mounts this path): $db_path"
            continue
        fi

        # Skip excluded services
        if [ ${#EXCLUDED_SERVICES[@]} -gt 0 ] && printf '%s\n' "${EXCLUDED_SERVICES[@]}" | grep -qx "$SERVICE_NAME"; then
            echo "[~] Skipped (excluded): $SERVICE_NAME → $(basename "$db_path")"
            continue
        fi

        SERVICE_DBS[$SERVICE_NAME]+="$db_path"$'\n'
        SERVICE_CF[$SERVICE_NAME]="$cf"
    done
done

# ==============================================================================
# PHASE 2 — BACKUP: one stop/start per service
# ==============================================================================
for SERVICE_NAME in "${!SERVICE_DBS[@]}"; do
    cf="${SERVICE_CF[$SERVICE_NAME]}"

    mapfile -t DB_LIST < <(printf '%s' "${SERVICE_DBS[$SERVICE_NAME]}" | grep -v '^$')

    DB_COUNT=${#DB_LIST[@]}
    echo ""
    echo "[*] Service: $SERVICE_NAME — $DB_COUNT database(s) to back up"

    if [ "$DRY_RUN" == "off" ]; then
        echo "    Stopping $SERVICE_NAME..."
        docker compose -f "$cf" stop -t "$STOP_TIMEOUT" "$SERVICE_NAME"
    fi

    DEST_DIR="$BACKUP_ROOT/$SERVICE_NAME"
    [ "$DRY_RUN" == "off" ] && mkdir -p "$DEST_DIR"

    for db_path in "${DB_LIST[@]}"; do
        DB_NAME=$(basename "$db_path")
        DB_SIZE=$(du -h "$db_path" | cut -f1)

        echo "    → $DB_NAME ($DB_SIZE)"

        if [ "$DRY_RUN" == "off" ]; then
            DEST_BASE="$DEST_DIR/${DB_NAME}_${DATE_ID}"

            if gzip -c "$db_path" > "${DEST_BASE}.gz" 2>/dev/null; then
                echo "      OK → ${DEST_BASE}.gz"
                if [ -f "${db_path}-wal" ]; then
                    gzip -c "${db_path}-wal" > "${DEST_BASE}-wal.gz"
                    echo "      OK → ${DEST_BASE}-wal.gz"
                fi
                if [ -f "${db_path}-shm" ]; then
                    gzip -c "${db_path}-shm" > "${DEST_BASE}-shm.gz"
                    echo "      OK → ${DEST_BASE}-shm.gz"
                fi
                ROW_COLOR="#d4edda"
                ROW_ICON="✅"
                ROW_STATUS="OK"
                ((COUNT_OK++))
            else
                echo "      ERROR: failed to compress $db_path"
                rm -f "${DEST_BASE}.gz"
                ROW_COLOR="#f8d7da"
                ROW_ICON="❌"
                ROW_STATUS="ERROR"
                GLOBAL_STATUS="ERROR"
                ((COUNT_ERR++))
            fi
        else
            ROW_COLOR="#fff3cd"
            ROW_ICON="⚠️"
            ROW_STATUS="DRY-RUN"
            ((COUNT_DRY++))
        fi

        TABLE_ROWS+="
        <tr style='background-color: ${ROW_COLOR};'>
            <td style='padding: 8px; border: 1px solid #ddd;'>$SERVICE_NAME</td>
            <td style='padding: 8px; border: 1px solid #ddd;'>$DB_NAME</td>
            <td style='padding: 8px; border: 1px solid #ddd;'>$DB_SIZE</td>
            <td style='padding: 8px; border: 1px solid #ddd; text-align:center;'>${ROW_ICON} ${ROW_STATUS}</td>
        </tr>"
    done

    if [ "$DRY_RUN" == "off" ]; then
        echo "    Starting $SERVICE_NAME..."
        docker compose -f "$cf" start "$SERVICE_NAME"
    fi
done

# ==============================================================================
# RETENTION — safe cleanup
# Only touches .gz files inside BACKUP_ROOT, never rm -rf on directories.
# -mtime +N-1 matches files older than N days, keeping exactly RETENTION_DAYS days.
# ==============================================================================
echo ""
echo "[*] Removing backups older than $RETENTION_DAYS days..."

DELETED_COUNT=0
while IFS= read -r -d '' old_file; do
    echo "    Removing: $old_file"
    rm -f "$old_file"
    ((DELETED_COUNT++))
done < <(
    find "$BACKUP_ROOT" \
        -type f -name "*.gz" \
        -not -path "*/log/*" \
        -mtime +"$((RETENTION_DAYS - 1))" \
        -print0
)

echo "    Removed $DELETED_COUNT file(s)."

# Remove empty service directories left after retention (safe — not recursive rm -rf)
find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -not -name "log" -empty -delete

# Log retention
echo "[*] Removing logs older than $RETENTION_DAYS days..."

DELETED_LOGS=0
while IFS= read -r -d '' old_log; do
    echo "    Removing log: $old_log"
    rm -f "$old_log"
    ((DELETED_LOGS++))
done < <(
    find "$LOG_DIR" \
        -type f -name "*.log" \
        -mtime +"$((RETENTION_DAYS - 1))" \
        -print0
)

echo "    Removed $DELETED_LOGS log(s)."

# ==============================================================================
# BUILD EMAIL
# ==============================================================================
case "$GLOBAL_STATUS" in
    OK)    STATUS_ICON="✅" ;;
    ERROR) STATUS_ICON="❌" ;;
    *)     STATUS_ICON="⚠️" ;;
esac

if [ "$DRY_RUN" == "on" ]; then
    EMAIL_SUBJECT="[DRY-RUN ⚠️] ${EMAIL_SUBJECT_PREFIX} | ${HOSTNAME} | ${DATE_LABEL}"
else
    EMAIL_SUBJECT="[${STATUS_ICON} ${GLOBAL_STATUS}] ${EMAIL_SUBJECT_PREFIX} | ${HOSTNAME} | ${DATE_LABEL}"
fi

if [ "$DRY_RUN" == "off" ]; then
    TOTAL=$((COUNT_OK + COUNT_ERR))
    SUMMARY_LINE="Databases processed: <b>${TOTAL}</b> &nbsp;|&nbsp; ✅ OK: <b>${COUNT_OK}</b> &nbsp;|&nbsp; ❌ Errors: <b>${COUNT_ERR}</b>"
    [ $DELETED_COUNT -gt 0 ] && SUMMARY_LINE+="<br>Backups removed by retention: <b>${DELETED_COUNT}</b>"
    [ $DELETED_LOGS -gt 0 ]  && SUMMARY_LINE+="<br>Logs removed by retention: <b>${DELETED_LOGS}</b>"
else
    SUMMARY_LINE="Mode: <b>DRY-RUN</b> — <b>${COUNT_DRY}</b> database(s) found. No backup written, no filesystem changes."
fi

EXCLUSIONS_LINE=""
if [ ${#EXCLUDED_SERVICES[@]} -gt 0 ]; then
    EXCLUSIONS_LINE="<br><strong>Excluded services:</strong> ${EXCLUDED_SERVICES[*]}"
fi

if [ -z "$TABLE_ROWS" ]; then
    TABLE_ROWS="<tr><td colspan='4' style='padding: 12px; text-align:center; color:#888;'>No SQLite databases found associated with running containers.</td></tr>"
fi

HTML_BODY="<html>
<body style='font-family: Arial, sans-serif; color: #333; max-width: 700px; margin: 0 auto;'>

<h2 style='border-bottom: 2px solid #eee; padding-bottom: 8px;'>${EMAIL_SUBJECT_PREFIX}</h2>

<p style='font-size: 14px;'>
    <strong>Server:</strong> ${HOSTNAME}<br>
    <strong>Date:</strong> ${DATE_LABEL}<br>
    <strong>Global status:</strong> ${STATUS_ICON} <b>${GLOBAL_STATUS}</b>${EXCLUSIONS_LINE}
</p>

<p style='background: #f9f9f9; border-left: 4px solid #ccc; padding: 10px 14px; font-size: 13px;'>
    ${SUMMARY_LINE}
</p>

<table style='width: 100%; border-collapse: collapse; margin-top: 16px; font-size: 13px;'>
    <thead>
        <tr style='background-color: #f2f2f2;'>
            <th style='padding: 9px 8px; border: 1px solid #ddd; text-align:left;'>Service</th>
            <th style='padding: 9px 8px; border: 1px solid #ddd; text-align:left;'>Database</th>
            <th style='padding: 9px 8px; border: 1px solid #ddd; text-align:left;'>Size</th>
            <th style='padding: 9px 8px; border: 1px solid #ddd; text-align:center;'>Status</th>
        </tr>
    </thead>
    <tbody>
        ${TABLE_ROWS}
    </tbody>
</table>

<p style='font-size: 11px; color: #aaa; margin-top: 24px;'>
    Log: ${LOG_FILE}<br>
    Retention: ${RETENTION_DAYS} days &nbsp;|&nbsp; Backups at: ${BACKUP_ROOT}
</p>

</body>
</html>"

# ==============================================================================
# SEND EMAIL VIA SWAKS
# TLS selected automatically by port:
#   465 → --tls-on-connect (SMTPS)
#   587 → --tls (STARTTLS)
#   other → no TLS flag
# ==============================================================================
case "$SMTP_PORT" in
    465) SWAKS_TLS="--tls-on-connect" ;;
    587) SWAKS_TLS="--tls" ;;
    *)   SWAKS_TLS="" ;;
esac

SWAKS_AUTH=()
if [[ -n "$SMTP_USER" ]]; then
    SWAKS_AUTH=(--auth-user "$SMTP_USER" --auth-password "$SMTP_PASS")
fi

echo ""
echo "[*] Sending report to $EMAIL_TO..."

swaks \
    --to      "$EMAIL_TO" \
    --from    "$EMAIL_FROM" \
    --server  "$SMTP_SERVER" \
    --port    "$SMTP_PORT" \
    $SWAKS_TLS \
    "${SWAKS_AUTH[@]}" \
    --header  "Subject: $EMAIL_SUBJECT" \
    --header  "Content-Type: text/html; charset=UTF-8" \
    --body    "$HTML_BODY" \
    > /dev/null 2>&1 \
    && echo "    Report sent." \
    || echo "    WARNING: email delivery failed (check SMTP settings)."

echo ""
echo "============================================================"
echo "END SQLite Backup: $(date)"
echo "============================================================"