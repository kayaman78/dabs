#!/usr/bin/env bash
# ==============================================================================
# DABS — Docker Automated Backup for SQLite
# Version: 1.2
# Platform: Debian / Ubuntu
# https://github.com/kayaman78/dabs
# ==============================================================================

# --- GENERAL SETTINGS ---
DRY_RUN="off"                              # [on/off] — set to "on" to simulate without writing anything
BASE_DIR="/srv/docker"                     # Root directory to scan for compose files
BACKUP_ROOT="/srv/docker/dabs/backups"     # Root directory where backups will be stored
RETENTION_DAYS=7                           # How many days to keep backups and logs
STOP_TIMEOUT=60                            # Seconds to wait for container stop before proceeding
SIZE_DROP_WARN=20                          # % size drop vs previous backup that triggers a warning

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
EMAIL_SUBJECT_PREFIX="SQLite Backup"

# Telegram (optional)
TELEGRAM_ENABLED="false"
TELEGRAM_TOKEN=""
TELEGRAM_CHAT_ID=""

# ntfy (optional)
NTFY_ENABLED="false"
NTFY_URL=""           # e.g. https://ntfy.sh or your self-hosted instance
NTFY_TOPIC=""         # e.g. dabs-backups

# Attach log to push notifications
NOTIFY_ATTACH_LOG="false"

# ==============================================================================
# INITIAL CHECKS
# ==============================================================================
[[ $EUID -ne 0 ]] && echo "Error: run as root or with sudo." && exit 1

LOG_DIR="$BACKUP_ROOT/log"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/backup-sqlite_$(date +%Y%m%d).log"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

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
    [sqlite3]="sqlite3"
    [curl]="curl"
)

MISSING_PKGS=()
for cmd in "${!DEP_MAP[@]}"; do
    command -v "$cmd" &>/dev/null || MISSING_PKGS+=("${DEP_MAP[$cmd]}")
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "⚙️  Installing missing dependencies: ${MISSING_PKGS[*]}"
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
declare -A SEEN_DBS
COUNT_OK=0
COUNT_ERR=0
COUNT_DRY=0
COUNT_VERIFY_OK=0
COUNT_VERIFY_WARN=0
COUNT_VERIFY_ERR=0

echo "============================================================"
echo "🚀 START SQLite Backup: $(date) — Host: $HOSTNAME"
echo "Mode: $([ "$DRY_RUN" == "on" ] && echo "DRY-RUN (no backup will be written)" || echo "PRODUCTION")"
[ ${#EXCLUDED_SERVICES[@]} -gt 0 ] && echo "Excluded services: ${EXCLUDED_SERVICES[*]}"
echo "============================================================"

# ==============================================================================
# VERIFY FUNCTION
# Checks a freshly created .gz backup:
#   1. gzip integrity
#   2. SQLite PRAGMA integrity_check (decompress to tmp)
#   3. Size comparison vs previous backup (warn if drop > SIZE_DROP_WARN%)
#
# Outputs: "OK" | "WARN:<reason>" | "FAIL:<reason>"
# ==============================================================================
verify_sqlite_backup() {
    local gz_file="$1"
    local dest_dir="$2"
    local db_name="$3"
    local warn_msg=""

    # Check 1 — gzip integrity
    if ! gzip -t "$gz_file" 2>/dev/null; then
        echo "FAIL:gzip corrupt"
        return 1
    fi

    # Check 2 — SQLite integrity_check
    local tmp_db
    tmp_db=$(mktemp /tmp/dabs_verify_XXXXXX.db)
    if ! zcat "$gz_file" > "$tmp_db" 2>/dev/null; then
        rm -f "$tmp_db"
        echo "FAIL:decompress error"
        return 1
    fi

    local integrity
    integrity=$(sqlite3 "$tmp_db" "PRAGMA integrity_check;" 2>/dev/null)
    rm -f "$tmp_db"

    if [ "$integrity" != "ok" ]; then
        echo "FAIL:integrity_check failed"
        return 1
    fi

    # Check 3 — size drop vs previous backup
    local curr_size
    curr_size=$(stat -c%s "$gz_file" 2>/dev/null || echo 0)

    # Find the most recent previous backup for this db (exclude current file)
    local prev_backup
    prev_backup=$(find "$dest_dir" -name "${db_name}_*.gz" \
        ! -newer "$gz_file" ! -samefile "$gz_file" \
        -not -name "*-wal*" -not -name "*-shm*" \
        2>/dev/null | sort | tail -1)

    if [ -n "$prev_backup" ]; then
        local prev_size
        prev_size=$(stat -c%s "$prev_backup" 2>/dev/null || echo 0)
        if [ "$prev_size" -gt 0 ]; then
            local threshold=$(( prev_size * (100 - SIZE_DROP_WARN) / 100 ))
            if [ "$curr_size" -lt "$threshold" ]; then
                local prev_h curr_h
                prev_h=$(du -h "$prev_backup" | cut -f1)
                curr_h=$(du -h "$gz_file" | cut -f1)
                echo "WARN:size drop ${prev_h}→${curr_h}"
                return 0
            fi
        fi
    fi

    echo "OK"
    return 0
}

# ==============================================================================
# NOTIFICATION FUNCTIONS
# Each channel is fully independent. All use the same compact text summary.
# ==============================================================================

build_text_summary() {
    local icon="✅"
    [ $COUNT_ERR -gt 0 ] && icon="❌"
    [ $COUNT_ERR -eq 0 ] && [ $COUNT_VERIFY_WARN -gt 0 ] && icon="⚠️"
    [ $COUNT_VERIFY_ERR -gt 0 ] && icon="❌"

    local total=$((COUNT_OK + COUNT_ERR))
    printf "%s DABS Backup — %s | %s\nSQLite %s✅ %s❌ (total: %s)\nVerify %s✅ %s⚠️ %s❌" \
        "$icon" "$HOSTNAME" "$DATE_LABEL" \
        "$COUNT_OK" "$COUNT_ERR" "$total" \
        "$COUNT_VERIFY_OK" "$COUNT_VERIFY_WARN" "$COUNT_VERIFY_ERR"
}

send_telegram() {
    [ "$TELEGRAM_ENABLED" != "true" ] && return 0
    if [ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        echo "⚠️  WARNING: Telegram enabled but TOKEN or CHAT_ID missing — skipping"
        return 1
    fi

    local text api
    text=$(build_text_summary)
    api="https://api.telegram.org/bot${TELEGRAM_TOKEN}"

    if [ "$NOTIFY_ATTACH_LOG" = "true" ] && [ -f "$LOG_FILE" ]; then
        curl -sf -X POST "${api}/sendDocument" \
            -F "chat_id=${TELEGRAM_CHAT_ID}" \
            -F "caption=${text}" \
            -F "document=@${LOG_FILE}" \
            > /dev/null 2>&1 \
            && echo "    📨 Telegram: sent with log attachment." \
            || echo "    ⚠️  WARNING: Telegram delivery failed."
    else
        curl -sf -X POST "${api}/sendMessage" \
            -H "Content-Type: application/json" \
            -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"${text}\"}" \
            > /dev/null 2>&1 \
            && echo "    📨 Telegram: sent." \
            || echo "    ⚠️  WARNING: Telegram delivery failed."
    fi
}

send_ntfy() {
    [ "$NTFY_ENABLED" != "true" ] && return 0
    if [ -z "$NTFY_URL" ] || [ -z "$NTFY_TOPIC" ]; then
        echo "⚠️  WARNING: ntfy enabled but URL or TOPIC missing — skipping"
        return 1
    fi

    local text priority=3
    text=$(build_text_summary)
    { [ $COUNT_ERR -gt 0 ] || [ $COUNT_VERIFY_ERR -gt 0 ]; } && priority=5

    if [ "$NOTIFY_ATTACH_LOG" = "true" ] && [ -f "$LOG_FILE" ]; then
        curl -sf -X PUT "${NTFY_URL}/${NTFY_TOPIC}" \
            -H "Title: DABS Backup — ${HOSTNAME}" \
            -H "Priority: ${priority}" \
            -H "Filename: $(basename "$LOG_FILE")" \
            --data-binary "@${LOG_FILE}" \
            > /dev/null 2>&1 \
            && echo "    📨 ntfy: sent with log attachment." \
            || echo "    ⚠️  WARNING: ntfy delivery failed."
    else
        curl -sf -X POST "${NTFY_URL}/${NTFY_TOPIC}" \
            -H "Title: DABS Backup — ${HOSTNAME}" \
            -H "Priority: ${priority}" \
            -d "$text" \
            > /dev/null 2>&1 \
            && echo "    📨 ntfy: sent." \
            || echo "    ⚠️  WARNING: ntfy delivery failed."
    fi
}

# ==============================================================================
# PHASE 1 — SCAN
# ==============================================================================
declare -A SERVICE_DBS
declare -A SERVICE_CF

mapfile -t COMPOSE_FILES < <(
    find "$BASE_DIR" -type f \( -name "compose.y*ml" -o -name "docker-compose.y*ml" \) \
    -not -path "$BACKUP_ROOT/*"
)

[ ${#COMPOSE_FILES[@]} -eq 0 ] && echo "[!] No compose files found under $BASE_DIR"

declare -A CID_SVC
declare -A CID_MOUNTS
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

        if ! file "$db_path" | grep -q "SQLite 3.x database"; then
            echo "[~] ⏭️  Skipped (not SQLite): $db_path"
            continue
        fi

        if [ ${#CID_SVC[@]} -eq 0 ]; then
            echo "[~] ⏭️  Skipped (no running containers): $db_path"
            continue
        fi

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
            echo "[~] ⏭️  Skipped (no active container mounts this path): $db_path"
            continue
        fi

        if [ ${#EXCLUDED_SERVICES[@]} -gt 0 ] && printf '%s\n' "${EXCLUDED_SERVICES[@]}" | grep -qx "$SERVICE_NAME"; then
            echo "[~] ⏭️  Skipped (excluded): $SERVICE_NAME → $(basename "$db_path")"
            continue
        fi

        SERVICE_DBS[$SERVICE_NAME]+="$db_path"$'\n'
        SERVICE_CF[$SERVICE_NAME]="$cf"
    done
done

# ==============================================================================
# PHASE 2 — BACKUP + VERIFY
# ==============================================================================
for SERVICE_NAME in "${!SERVICE_DBS[@]}"; do
    cf="${SERVICE_CF[$SERVICE_NAME]}"

    mapfile -t DB_LIST < <(printf '%s' "${SERVICE_DBS[$SERVICE_NAME]}" | grep -v '^$')

    DB_COUNT=${#DB_LIST[@]}
    echo ""
    echo "[*] 🗄️  Service: $SERVICE_NAME — $DB_COUNT database(s) to back up"

    if [ "$DRY_RUN" == "off" ]; then
        echo "    ⏸️  Stopping $SERVICE_NAME..."
        docker compose -f "$cf" stop -t "$STOP_TIMEOUT" "$SERVICE_NAME"
    fi

    DEST_DIR="$BACKUP_ROOT/$SERVICE_NAME"
    [ "$DRY_RUN" == "off" ] && mkdir -p "$DEST_DIR"

    for db_path in "${DB_LIST[@]}"; do
        DB_NAME=$(basename "$db_path")
        DB_SIZE=$(du -h "$db_path" | cut -f1)

        echo "    → $DB_NAME ($DB_SIZE)"

        ROW_BACKUP_COLOR="#d4edda"
        ROW_BACKUP_ICON="✅"
        ROW_BACKUP_STATUS="OK"
        ROW_VERIFY_COLOR="#d4edda"
        ROW_VERIFY_ICON="✅"
        ROW_VERIFY_STATUS="OK"

        if [ "$DRY_RUN" == "off" ]; then
            DEST_BASE="$DEST_DIR/${DB_NAME}_${DATE_ID}"

            if gzip -c "$db_path" > "${DEST_BASE}.gz" 2>/dev/null; then
                echo "      ✅ Backup OK → ${DEST_BASE}.gz"
                if [ -f "${db_path}-wal" ]; then
                    if gzip -c "${db_path}-wal" > "${DEST_BASE}-wal.gz" 2>/dev/null; then
                        echo "      Backup OK → ${DEST_BASE}-wal.gz"
                    else
                        echo "      ⚠️  WARNING: failed to compress WAL file, removing partial"
                        rm -f "${DEST_BASE}-wal.gz"
                    fi
                fi
                if [ -f "${db_path}-shm" ]; then
                    if gzip -c "${db_path}-shm" > "${DEST_BASE}-shm.gz" 2>/dev/null; then
                        echo "      Backup OK → ${DEST_BASE}-shm.gz"
                    else
                        echo "      ⚠️  WARNING: failed to compress SHM file, removing partial"
                        rm -f "${DEST_BASE}-shm.gz"
                    fi
                fi
                ((COUNT_OK++))

                # --- VERIFY ---
                echo "      🔍 Verifying ${DB_NAME}..."
                VERIFY_RESULT=$(verify_sqlite_backup "${DEST_BASE}.gz" "$DEST_DIR" "$DB_NAME")
                VERIFY_CODE="${VERIFY_RESULT%%:*}"
                VERIFY_DETAIL="${VERIFY_RESULT#*:}"

                case "$VERIFY_CODE" in
                    OK)
                        echo "      ✅ Verify OK"
                        ((COUNT_VERIFY_OK++))
                        ROW_VERIFY_COLOR="#d4edda"; ROW_VERIFY_ICON="✅"; ROW_VERIFY_STATUS="OK"
                        ;;
                    WARN)
                        echo "      ⚠️  Verify WARN: $VERIFY_DETAIL"
                        ((COUNT_VERIFY_WARN++))
                        ROW_VERIFY_COLOR="#fff3cd"; ROW_VERIFY_ICON="⚠️"; ROW_VERIFY_STATUS="WARN: $VERIFY_DETAIL"
                        [ "$GLOBAL_STATUS" == "OK" ] && GLOBAL_STATUS="WARN"
                        ;;
                    FAIL)
                        echo "      ❌ Verify FAIL: $VERIFY_DETAIL"
                        ((COUNT_VERIFY_ERR++))
                        ROW_VERIFY_COLOR="#f8d7da"; ROW_VERIFY_ICON="❌"; ROW_VERIFY_STATUS="FAIL: $VERIFY_DETAIL"
                        GLOBAL_STATUS="ERROR"
                        ;;
                esac

            else
                echo "      ❌ ERROR: failed to compress $db_path"
                rm -f "${DEST_BASE}.gz"
                ROW_BACKUP_COLOR="#f8d7da"; ROW_BACKUP_ICON="❌"; ROW_BACKUP_STATUS="ERROR"
                ROW_VERIFY_COLOR="#f2f2f2"; ROW_VERIFY_ICON="—"; ROW_VERIFY_STATUS="skipped"
                GLOBAL_STATUS="ERROR"
                ((COUNT_ERR++))
            fi
        else
            ROW_BACKUP_COLOR="#fff3cd"; ROW_BACKUP_ICON="⚠️"; ROW_BACKUP_STATUS="DRY-RUN"
            ROW_VERIFY_COLOR="#fff3cd"; ROW_VERIFY_ICON="⚠️"; ROW_VERIFY_STATUS="DRY-RUN"
            ((COUNT_DRY++))
        fi

        TABLE_ROWS+="
        <tr>
            <td style='padding: 8px; border: 1px solid #ddd;'>$SERVICE_NAME</td>
            <td style='padding: 8px; border: 1px solid #ddd;'>$DB_NAME</td>
            <td style='padding: 8px; border: 1px solid #ddd;'>$DB_SIZE</td>
            <td style='padding: 8px; border: 1px solid #ddd; text-align:center; background-color:${ROW_BACKUP_COLOR};'>${ROW_BACKUP_ICON} ${ROW_BACKUP_STATUS}</td>
            <td style='padding: 8px; border: 1px solid #ddd; text-align:center; background-color:${ROW_VERIFY_COLOR};'>${ROW_VERIFY_ICON} ${ROW_VERIFY_STATUS}</td>
        </tr>"
    done

    if [ "$DRY_RUN" == "off" ]; then
        echo "    ▶️  Starting $SERVICE_NAME..."
        docker compose -f "$cf" start "$SERVICE_NAME"
    fi
done

# ==============================================================================
# RETENTION
# ==============================================================================
echo ""
echo "[*] Removing backups older than $RETENTION_DAYS days..."

DELETED_COUNT=0
while IFS= read -r -d '' old_file; do
    echo "    Removing: $old_file"
    rm -f "$old_file"
    ((DELETED_COUNT++))
done < <(
    find "$BACKUP_ROOT" -type f -name "*.gz" \
        -not -path "*/log/*" \
        -mtime +"$((RETENTION_DAYS - 1))" -print0
)
echo "    Removed $DELETED_COUNT file(s)."

find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -not -name "log" -empty -delete

echo "[*] Removing logs older than $RETENTION_DAYS days..."
DELETED_LOGS=0
while IFS= read -r -d '' old_log; do
    echo "    Removing log: $old_log"
    rm -f "$old_log"
    ((DELETED_LOGS++))
done < <(
    find "$LOG_DIR" -type f -name "*.log" \
        -mtime +"$((RETENTION_DAYS - 1))" -print0
)
echo "    Removed $DELETED_LOGS log(s)."

# ==============================================================================
# BUILD EMAIL
# ==============================================================================
case "$GLOBAL_STATUS" in
    OK)    STATUS_ICON="✅" ;;
    WARN)  STATUS_ICON="⚠️" ;;
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
    SUMMARY_LINE="Databases: <b>${TOTAL}</b> &nbsp;|&nbsp; Backup ✅ <b>${COUNT_OK}</b> ❌ <b>${COUNT_ERR}</b>"
    SUMMARY_LINE+="<br>Verify ✅ <b>${COUNT_VERIFY_OK}</b> ⚠️ <b>${COUNT_VERIFY_WARN}</b> ❌ <b>${COUNT_VERIFY_ERR}</b>"
    [ $DELETED_COUNT -gt 0 ] && SUMMARY_LINE+="<br>Backups removed by retention: <b>${DELETED_COUNT}</b>"
    [ $DELETED_LOGS -gt 0 ]  && SUMMARY_LINE+="<br>Logs removed by retention: <b>${DELETED_LOGS}</b>"
else
    SUMMARY_LINE="Mode: <b>DRY-RUN</b> — <b>${COUNT_DRY}</b> database(s) found. No backup written, no filesystem changes."
fi

EXCLUSIONS_LINE=""
[ ${#EXCLUDED_SERVICES[@]} -gt 0 ] && EXCLUSIONS_LINE="<br><strong>Excluded services:</strong> ${EXCLUDED_SERVICES[*]}"

if [ -z "$TABLE_ROWS" ]; then
    TABLE_ROWS="<tr><td colspan='5' style='padding: 12px; text-align:center; color:#888;'>No SQLite databases found associated with running containers.</td></tr>"
fi

HTML_BODY="<html>
<body style='font-family: Arial, sans-serif; color: #333; max-width: 750px; margin: 0 auto;'>

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
            <th style='padding: 9px 8px; border: 1px solid #ddd; text-align:center;'>Backup</th>
            <th style='padding: 9px 8px; border: 1px solid #ddd; text-align:center;'>Verify</th>
        </tr>
    </thead>
    <tbody>
        ${TABLE_ROWS}
    </tbody>
</table>

<p style='font-size: 11px; color: #aaa; margin-top: 24px;'>
    Log: ${LOG_FILE}<br>
    Retention: ${RETENTION_DAYS} days &nbsp;|&nbsp; Backups at: ${BACKUP_ROOT}<br>
    Verify: gzip integrity + PRAGMA integrity_check + size trend (warn if drop &gt; ${SIZE_DROP_WARN}%)
</p>

</body>
</html>"

# ==============================================================================
# SEND EMAIL VIA SWAKS
# ==============================================================================
case "$SMTP_PORT" in
    465) SWAKS_TLS="--tls-on-connect" ;;
    587) SWAKS_TLS="--tls" ;;
    *)   SWAKS_TLS="" ;;
esac

SWAKS_AUTH=()
[[ -n "$SMTP_USER" ]] && SWAKS_AUTH=(--auth-user "$SMTP_USER" --auth-password "$SMTP_PASS")

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
echo "[*] 📣 Sending push notifications..."
send_telegram
send_ntfy

echo ""
echo "============================================================"
echo "END SQLite Backup: $(date)"
echo "============================================================"