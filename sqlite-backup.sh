#!/usr/bin/env bash
# ==============================================================================
# DABS — Docker Automated Backup for SQLite
# Version: 1.7
# Platform: Debian / Ubuntu
# https://github.com/kayaman78/dabs
# ==============================================================================

# --- GENERAL SETTINGS ---
DRY_RUN="off"                              # [on/off] — set to "on" to simulate without writing anything
BASE_DIR="/srv/docker"                     # Root directory to scan for compose files
BACKUP_ROOT="/srv/docker/dabs/backups"     # Root directory where backups will be stored
RETENTION_DAYS=7                           # Number of most recent dumps to keep per database (calendar-independent)
STOP_TIMEOUT=60                            # Seconds to wait for container stop before proceeding
SIZE_DROP_WARN=20                          # % size drop vs previous backup that triggers a warning

# Services to skip — exact compose service names (com.docker.compose.service label)
# Example: EXCLUDED_SERVICES=("homeassistant" "pihole")
EXCLUDED_SERVICES=()

# --- NAMED VOLUME SCAN ---
SCAN_VOLUMES="on"                                    # [on/off] — also look inside named volumes
VOLUMES_CONFIG_FILE="/srv/docker/dabs/volumes.conf"  # written by --setup; absent = scan them all

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
# KNOWN DATABASE IMAGES — their named volumes are skipped during the volume scan
# Same list as DABV, on purpose: the two tools must agree on what a database is.
# Data inside these volumes is KDD's job (logical dumps), not DABS's — and
# copying it here would mean stopping the database engine to grab a temp file.
# ==============================================================================
DB_IMAGE_PATTERNS=(
    "postgres"
    "mysql"
    "mariadb"
    "mongo"
    "redis"
    "timescaledb"
    "postgis"
)

is_db_image() {
    local image="${1,,}"
    for pattern in "${DB_IMAGE_PATTERNS[@]}"; do
        [[ "$image" == *"$pattern"* ]] && return 0
    done
    return 1
}

# ==============================================================================
# VOLUME CONFIG
# The nightly run must never ask anything: it is started by cron or KCR, and a
# prompt there would hang the job until the timeout. So the choice is made once,
# interactively, with --setup — and the run only reads the answer.
#
# No config file = scan every named volume except database ones. That is the
# safe default: a database that is found and backed up is better than one that
# is silently skipped.
# ==============================================================================
declare -A VOL_CHOICE

load_volume_config() {
    [ -f "$VOLUMES_CONFIG_FILE" ] || return 0
    local line vol choice
    while IFS= read -r line; do
        line="${line%%#*}"
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        vol="${line%%:*}"; choice="${line#*:}"
        vol="$(echo "$vol" | xargs)"; choice="$(echo "$choice" | xargs)"
        [ -n "$vol" ] && VOL_CHOICE["$vol"]="$choice"
    done < "$VOLUMES_CONFIG_FILE"
}

# Returns 0 if this volume should be scanned.
volume_wanted() {
    local vol="$1"
    [ ${#VOL_CHOICE[@]} -eq 0 ] && return 0          # no config: scan everything
    [ "${VOL_CHOICE[$vol]:-include}" = "exclude" ] && return 1
    return 0
}

# ==============================================================================
# --setup MODE
# Scans named volumes, shows the SQLite databases inside each one, asks, and
# writes the config file. Runs before logging is redirected, so the prompts
# stay readable.
# ==============================================================================
run_setup() {
    echo "============================================================"
    echo "🛠️  DABS Setup — named volume discovery"
    echo "============================================================"
    echo ""
    echo "Scans the named volumes of running containers for SQLite"
    echo "databases and writes your choices to:"
    echo "    $VOLUMES_CONFIG_FILE"
    echo ""
    echo "Volumes belonging to database images (postgres, mysql,"
    echo "mariadb, mongo, redis, timescaledb, postgis) are not offered:"
    echo "their data is KDD's job, and opening them here would mean"
    echo "stopping the database engine to copy a temporary file."
    echo ""

    # `done < <(...)` redirects stdin for the WHOLE while block, so a read
    # inside it would consume the process substitution instead of the user's
    # answers — returning an empty line, which every prompt would read as "yes".
    # fd 3 keeps a handle on the real stdin, before any loop takes it over.
    exec 3<&0

    command -v docker &>/dev/null || { echo "FATAL: docker not found." >&2; exit 1; }
    command -v file   &>/dev/null || { echo "FATAL: 'file' not found — install it first." >&2; exit 1; }

    read -u 3 -r -p "Press Enter to start scanning..."
    echo ""

    local tmp_conf found_any=0
    tmp_conf=$(mktemp)
    {
        echo "# DABS volume config — generated $(date '+%Y-%m-%d %H:%M')"
        echo "# Re-run: bash sqlite-backup.sh --setup"
        echo "# Format:  <volume name>: include | exclude"
        echo "# A volume not listed here is included."
    } > "$tmp_conf"

    local cid img svc cname vol vol_src answer
    while IFS= read -r cid; do
        img=$(docker inspect "$cid" --format '{{.Config.Image}}' 2>/dev/null)
        cname=$(docker inspect "$cid" --format '{{.Name}}' 2>/dev/null | sed 's|/||')
        svc=$(docker inspect "$cid" --format '{{index .Config.Labels "com.docker.compose.service"}}' 2>/dev/null)

        is_db_image "$img" && continue

        while IFS=$'\t' read -r vol vol_src; do
            [ -z "$vol" ] && continue
            [ -d "$vol_src" ] || continue

            mapfile -t FOUND < <(
                find "$vol_src" -type f \( -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite3" \) \
                -size +10k 2>/dev/null
            )
            [ ${#FOUND[@]} -eq 0 ] && continue

            local real=()
            for f in "${FOUND[@]}"; do
                file "$f" | grep -q "SQLite 3.x database" && real+=("$f")
            done
            [ ${#real[@]} -eq 0 ] && continue

            found_any=1
            echo "------------------------------------------------------------"
            echo "Volume:    $vol"
            echo "Container: $cname   (service: ${svc:-<none>}, image: $img)"
            echo "Databases:"
            for f in "${real[@]}"; do
                echo "    $(du -h "$f" | cut -f1)  ${f#"$vol_src"}"
            done
            echo ""
            echo "⚠️  Backing these up stops '${svc:-$cname}' for the duration of the copy."
            # A failed read must never fall through to "yes": with no answer
            # available, defaulting to include would silently sign the user up
            # for stopping a service every night.
            if ! read -u 3 -r -p "Include this volume? [Y/n] " answer; then
                echo ""
                echo "FATAL: no answer available on stdin — setup needs a terminal." >&2
                echo "Nothing was written. Run --setup interactively." >&2
                rm -f "$tmp_conf"
                exit 1
            fi
            case "${answer,,}" in
                n|no) echo "$vol: exclude" >> "$tmp_conf"; echo "    → excluded" ;;
                *)    echo "$vol: include" >> "$tmp_conf"; echo "    → included" ;;
            esac
            echo ""
        done < <(docker inspect "$cid" \
                   --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\t"}}{{.Source}}{{"\n"}}{{end}}{{end}}' 2>/dev/null)
    done < <(docker ps -q)

    echo "============================================================"
    if [ "$found_any" -eq 0 ]; then
        echo "No SQLite databases found in any named volume."
        echo "Nothing to configure — the nightly run will find nothing here either."
        rm -f "$tmp_conf"
        exit 0
    fi

    mkdir -p "$(dirname "$VOLUMES_CONFIG_FILE")"
    mv "$tmp_conf" "$VOLUMES_CONFIG_FILE"
    echo "Written: $VOLUMES_CONFIG_FILE"
    echo ""
    cat "$VOLUMES_CONFIG_FILE"
    echo ""
    echo "Edit that file anytime — no need to re-run --setup."
    exit 0
}

# ==============================================================================
# INITIAL CHECKS
# ==============================================================================
[[ $EUID -ne 0 ]] && echo "Error: run as root or with sudo." && exit 1

[[ "${1:-}" == "--setup" ]] && run_setup

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
    if [ "$DRY_RUN" == "on" ]; then
        printf "🔍 DABS DRY-RUN — %s | %s\n%d database(s) found. No backups written." \
            "$HOSTNAME" "$DATE_LABEL" "$COUNT_DRY"
        return
    fi

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
declare -A CID_IMG
declare -A CID_CF
declare -A CID_VOLS
while IFS= read -r cid; do
    SVC=$(docker inspect "$cid" --format '{{index .Config.Labels "com.docker.compose.service"}}' 2>/dev/null)
    [ -z "$SVC" ] && continue
    CID_SVC[$cid]="$SVC"
    CID_MOUNTS[$cid]=$(docker inspect "$cid" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' 2>/dev/null)
    CID_IMG[$cid]=$(docker inspect "$cid" --format '{{.Config.Image}}' 2>/dev/null)
    # Compose file(s) this container came from — needed to stop/start a service
    # whose databases live in a named volume, i.e. outside any BASE_DIR tree.
    CID_CF[$cid]=$(docker inspect "$cid" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null)
    # Only named volumes: bind mounts are already covered by the compose scan.
    # Name and Source both needed: the name is what the config file talks about,
    # the source is where the files actually are.
    CID_VOLS[$cid]=$(docker inspect "$cid" --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\t"}}{{.Source}}{{"\n"}}{{end}}{{end}}' 2>/dev/null)
done < <(docker ps -q)

# Registers one candidate database file: dedup, SQLite check, owning service
# lookup, exclusion list. $2 is the compose file used to stop/start the service.
# Shared by both scan phases so they can never drift apart.
register_db() {
    local db_path="$1"
    local cf="$2"

    [[ -n "${SEEN_DBS[$db_path]}" ]] && return 0
    SEEN_DBS[$db_path]=1

    if ! file "$db_path" | grep -q "SQLite 3.x database"; then
        echo "[~] ⏭️  Skipped (not SQLite): $db_path"
        return 0
    fi

    if [ ${#CID_SVC[@]} -eq 0 ]; then
        echo "[~] ⏭️  Skipped (no running containers): $db_path"
        return 0
    fi

    local SERVICE_NAME="" BEST_LEN=0 cid SVC src
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
        return 0
    fi

    if [ ${#EXCLUDED_SERVICES[@]} -gt 0 ] && printf '%s\n' "${EXCLUDED_SERVICES[@]}" | grep -qx "$SERVICE_NAME"; then
        echo "[~] ⏭️  Skipped (excluded): $SERVICE_NAME → $(basename "$db_path")"
        return 0
    fi

    SERVICE_DBS[$SERVICE_NAME]+="$db_path"$'\n'
    SERVICE_CF[$SERVICE_NAME]="$cf"
}

# --- 1a. Bind mounts and loose files, found next to the compose files ---
for cf in "${COMPOSE_FILES[@]}"; do
    STACK_DIR=$(dirname "$cf")

    mapfile -t SQL_FILES < <(
        find "$STACK_DIR" -type f \( -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite3" \) \
        -not -path "$BACKUP_ROOT/*" -size +10k
    )

    for db_path in "${SQL_FILES[@]}"; do
        register_db "$db_path" "$cf"
    done
done

# --- 1b. Named volumes ---
# A database living in a named volume has no path under BASE_DIR, so phase 1a
# can never reach it — it reports nothing and looks like a clean run. The mount
# Source of a named volume is a real host path, which is why the service lookup
# in register_db() already works for these once they are found.
if [ "$SCAN_VOLUMES" != "on" ]; then
    echo "[~] ⏭️  Named volume scan disabled (SCAN_VOLUMES=$SCAN_VOLUMES)"
else
load_volume_config
[ ${#VOL_CHOICE[@]} -gt 0 ] && echo "[*] Volume config loaded: $VOLUMES_CONFIG_FILE"

for cid in "${!CID_SVC[@]}"; do
    [ -z "${CID_VOLS[$cid]}" ] && continue

    if is_db_image "${CID_IMG[$cid]}"; then
        echo "[~] ⏭️  Skipped volumes (database image, KDD's job): ${CID_SVC[$cid]} (${CID_IMG[$cid]})"
        continue
    fi

    while IFS=$'\t' read -r vol_name vol_src; do
        [ -z "$vol_src" ] && continue
        [ -d "$vol_src" ] || continue

        if ! volume_wanted "$vol_name"; then
            echo "[~] ⏭️  Skipped volume (excluded in config): $vol_name"
            continue
        fi

        mapfile -t VOL_FILES < <(
            find "$vol_src" -type f \( -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite3" \) \
            -not -path "$BACKUP_ROOT/*" -size +10k
        )

        for db_path in "${VOL_FILES[@]}"; do
            register_db "$db_path" "${CID_CF[$cid]}"
        done
    done <<< "${CID_VOLS[$cid]}"
done
fi

# ==============================================================================
# PHASE 2 — BACKUP + VERIFY
# ==============================================================================
for SERVICE_NAME in "${!SERVICE_DBS[@]}"; do
    cf="${SERVICE_CF[$SERVICE_NAME]}"

    # A compose project can be built from several files (base + override), and
    # the container label lists them comma-separated. Each one needs its own -f:
    # passing the whole string as a single path makes docker compose fail, and
    # the service would never be stopped before the copy.
    # printf '%s\n', not '%s': `while read` drops a final line that has no
    # trailing newline, which left COMPOSE_ARGS empty for single-file projects —
    # the common case. `docker compose stop` then ran with no -f at all, found
    # no project, and every service was copied while still running.
    COMPOSE_ARGS=()
    while IFS= read -r one_cf; do
        [ -z "$one_cf" ] && continue
        COMPOSE_ARGS+=(-f "$one_cf")
    done < <(printf '%s\n' "$cf" | tr ',' '\n')

    mapfile -t DB_LIST < <(printf '%s' "${SERVICE_DBS[$SERVICE_NAME]}" | grep -v '^$')

    DB_COUNT=${#DB_LIST[@]}
    echo ""
    echo "[*] 🗄️  Service: $SERVICE_NAME — $DB_COUNT database(s) to back up"

    if [ "$DRY_RUN" == "off" ]; then
        echo "    ⏸️  Stopping $SERVICE_NAME..."
        docker compose "${COMPOSE_ARGS[@]}" stop -t "$STOP_TIMEOUT" "$SERVICE_NAME"

        # Trusting the stop command is not enough: it fails whenever the compose
        # file has moved or been renamed since the containers were created — the
        # label still points at the old path. Without this check the databases
        # would be copied hot and the report would call it a clean backup.
        STILL_UP=$(docker ps -q --filter "label=com.docker.compose.service=$SERVICE_NAME" | wc -l)
        if [ "$STILL_UP" -gt 0 ]; then
            HOT_COPY="yes"
            echo "    ⚠️  WARNING: $SERVICE_NAME is still running — copying HOT."
            echo "        A hot SQLite copy may be inconsistent. Check that the compose"
            echo "        file below still exists and matches the running containers:"
            printf '        %s\n' "${COMPOSE_ARGS[@]}"
            [ "$GLOBAL_STATUS" == "OK" ] && GLOBAL_STATUS="WARN"
        else
            HOT_COPY="no"
        fi
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

        # The service refused to stop: the copy still happens — a doubtful backup
        # beats no backup — but the report must say so instead of showing green.
        if [ "${HOT_COPY:-no}" == "yes" ]; then
            ROW_BACKUP_COLOR="#fff3cd"
            ROW_BACKUP_ICON="⚠️"
            ROW_BACKUP_STATUS="OK (HOT — service did not stop)"
        fi

        if [ "$DRY_RUN" == "off" ]; then
            DEST_BASE="$DEST_DIR/${DB_NAME}_${DATE_ID}"

            err_file=$(mktemp)
            if gzip -c "$db_path" > "${DEST_BASE}.gz" 2>"$err_file"; then
                rm -f "$err_file"
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
                if [ -s "$err_file" ]; then
                    while IFS= read -r errline; do
                        echo "      $errline"
                    done < "$err_file"
                fi
                rm -f "$err_file"
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
        docker compose "${COMPOSE_ARGS[@]}" start "$SERVICE_NAME"
    fi
done

# ==============================================================================
# RETENTION
# ==============================================================================
# Lists files in $1 matching $2 that are BEYOND the RETENTION_DAYS most recent
# (deletion candidates). Calendar-independent: protects against mass-delete
# when backups have been paused longer than RETENTION_DAYS — existing archives
# survive until newer ones replace them.
_files_to_rotate() {
    local target="$1"
    local pattern="$2"
    [ -d "$target" ] || return 0
    find "$target" -maxdepth 1 -type f -name "$pattern" -printf '%T@\t%p\n' 2>/dev/null \
        | sort -rn \
        | tail -n +$((RETENTION_DAYS + 1)) \
        | cut -f2-
}

echo ""
echo "[*] Removing backups beyond the $RETENTION_DAYS most recent per database..."

DELETED_COUNT=0
for db_dir in "$BACKUP_ROOT"/*/; do
    [ -d "$db_dir" ] || continue
    [ "$(basename "$db_dir")" = "log" ] && continue
    while IFS= read -r old_file; do
        if [ "$DRY_RUN" == "off" ]; then
            echo "    Removing: $old_file"
            rm -f -- "$old_file"
        else
            echo "    [DRY-RUN] Would remove: $old_file"
        fi
        ((DELETED_COUNT++))
    done < <(_files_to_rotate "$db_dir" "*.gz")
done
[ "$DRY_RUN" == "off" ] \
    && echo "    Removed $DELETED_COUNT file(s)." \
    || echo "    Would remove $DELETED_COUNT file(s) (dry-run)."

[ "$DRY_RUN" == "off" ] && \
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -not -name "log" -empty -delete

echo "[*] Removing logs beyond the $RETENTION_DAYS most recent..."
DELETED_LOGS=0
while IFS= read -r old_log; do
    if [ "$DRY_RUN" == "off" ]; then
        echo "    Removing log: $old_log"
        rm -f -- "$old_log"
    else
        echo "    [DRY-RUN] Would remove: $old_log"
    fi
    ((DELETED_LOGS++))
done < <(_files_to_rotate "$LOG_DIR" "*.log")
[ "$DRY_RUN" == "off" ] \
    && echo "    Removed $DELETED_LOGS log(s)." \
    || echo "    Would remove $DELETED_LOGS log(s) (dry-run)."

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
    [ $DELETED_COUNT -gt 0 ] && SUMMARY_LINE+="<br>Retention preview: <b>${DELETED_COUNT}</b> backup(s) and <b>${DELETED_LOGS}</b> log(s) would be removed."
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
    Retention: ${RETENTION_DAYS} most recent dumps per database &nbsp;|&nbsp; Backups at: ${BACKUP_ROOT}<br>
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

[ $COUNT_ERR -gt 0 ] && exit 1
exit 0