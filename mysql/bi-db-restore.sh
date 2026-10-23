#!/usr/bin/env bash
# bi: Restore a Laravel Docker project from a backup archive
# bi-arg: -a=@file  Backup archive (required)
# bi-arg: -p=@dir   Target project root
# bi-arg: -c=       DB container (auto-detected)
# bi-arg: -C=@file  Config file
# bi-arg: -s        Skip database
# bi-arg: -V        Skip Docker volumes
# bi-arg: -f        Skip project files
# bi-arg: -F        Force, no confirmation prompts
# bi-arg: -v        Verbose
# bi-arg: -h        Show help
# =============================================================================
#  Laravel Docker Project — Full Restore Script
#  Compatible with Ubuntu 24.04
#
#  Usage: sudo bash laravel_docker_restore.sh [OPTIONS] -a <backup_archive>
#
#  Config file (loaded automatically if present):
#    ~/.laravel-docker.conf
#
#  Options (override config file values):
#    -a  <archive.tar.gz>       Backup archive to restore (REQUIRED)
#    -p  /path/to/laravel       Target project root
#    -c  <db_container>         DB container name (auto-detected if omitted)
#    -s                         Skip database restore
#    -V                         Skip Docker volumes restore
#    -f                         Skip project files restore
#    -F                         Force restore (no confirmation prompts)
#    -v                         Verbose output
#    -C  /path/to/config        Use a custom config file path
#    -h                         Show this help
#
#  Examples:
#    sudo bash laravel_docker_restore.sh -a /backups/host_laravel_backup_20240101_120000.tar.gz
#    sudo bash laravel_docker_restore.sh -a /backups/host_laravel_backup_20240101_120000.tar.gz -p /var/www/myapp
#    sudo bash laravel_docker_restore.sh -a /backups/host_laravel_backup_20240101_120000.tar.gz -C /etc/myapp/backup.conf
#    sudo bash laravel_docker_restore.sh -a /backups/host_laravel_backup_20240101_120000.tar.gz -F  # no prompts
# =============================================================================

set -euo pipefail

# ─── Colours (defined early — used by config loader messages) ─────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
verbose() { ${VERBOSE:-false} && echo -e "        $*" || true; }
step()    { echo -e "\n${BOLD}── $* ──${RESET}"; }
log()     { [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" || true; }

# ─── Built-in defaults (lowest priority) ─────────────────────────────────────
ARCHIVE=""
PROJECT_PATH="$(pwd)"
DB_CONTAINER=""
SKIP_DB=false
SKIP_VOLUMES=false
SKIP_FILES=false
FORCE_RESTORE=false
NOTIFY_EMAIL=""
SLACK_WEBHOOK=""
LOG_FILE=""
VERBOSE=false
WORK_DIR=""

# ─── Config file path (can be overridden with -C before other flags) ──────────
CONFIG_FILE="${HOME}/.midx-backup.conf"

for i in "$@"; do
    if [[ "${PREV_ARG:-}" == "-C" ]]; then
        CONFIG_FILE="$i"
    fi
    PREV_ARG="$i"
done

# ─── Load config file ─────────────────────────────────────────────────────────
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        if grep -qvE '^\s*(#|$|[A-Z_]+=)' "$CONFIG_FILE" 2>/dev/null; then
            warn "Config file contains unexpected lines — loading with caution."
        fi
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        info "Config loaded: $CONFIG_FILE"
    else
        verbose "No config file found at $CONFIG_FILE — using defaults."
    fi
}

# ─── Usage ───────────────────────────────────────────────────────────────────
usage() {
    sed -n '3,25p' "$0" | sed 's/^#  \{0,2\}//'
    exit 0
}

# ─── CLI flags (highest priority — override config values) ───────────────────
parse_args() {
    while getopts ":a:p:c:C:sVfFvh" opt; do
        case $opt in
            a) ARCHIVE="$OPTARG" ;;
            p) PROJECT_PATH="$OPTARG" ;;
            c) DB_CONTAINER="$OPTARG" ;;
            C) : ;; # already handled in pre-scan
            s) SKIP_DB=true ;;
            V) SKIP_VOLUMES=true ;;
            f) SKIP_FILES=true ;;
            F) FORCE_RESTORE=true ;;
            v) VERBOSE=true ;;
            h) usage ;;
            :) error "Option -$OPTARG requires an argument."; exit 1 ;;
            \?) error "Unknown option: -$OPTARG"; exit 1 ;;
        esac
    done
}

# ─── Pre-flight checks ───────────────────────────────────────────────────────
preflight() {
    echo -e "\n${BOLD}══ Laravel Docker Restore ══${RESET}\n"

    if [[ $EUID -ne 0 ]]; then
        warn "Not running as root — Docker volume operations may fail."
        warn "Re-run with sudo for a complete restore."
    fi

    if [[ -z "$ARCHIVE" ]]; then
        error "No backup archive specified. Use -a <archive.tar.gz>"
        echo ""; usage
    fi

    if [[ ! -f "$ARCHIVE" ]]; then
        error "Archive not found: $ARCHIVE"
        exit 1
    fi

    if ! command -v docker &>/dev/null; then
        error "docker is not installed or not in PATH."
        exit 1
    fi

    if ! docker info &>/dev/null; then
        error "Docker daemon is not running."
        exit 1
    fi

    for cmd in tar gzip rsync; do
        if ! command -v "$cmd" &>/dev/null; then
            error "'$cmd' is required but not installed. Run: apt install $cmd"
            exit 1
        fi
    done

    info "Archive    : $ARCHIVE"
    info "Target dir : $PROJECT_PATH"
    info "Config     : $CONFIG_FILE"
    [[ -n "$LOG_FILE" ]] && info "Log file   : $LOG_FILE"
    echo ""

    log "=== Restore started ==="
    log "Archive: $ARCHIVE | Target: $PROJECT_PATH"

    # Ensure log directory exists
    if [[ -n "$LOG_FILE" ]]; then
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || \
            warn "Cannot create log directory — file logging disabled."
    fi
}

# ─── Detect docker compose binary ────────────────────────────────────────────
detect_compose() {
    if docker compose version &>/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
    else
        COMPOSE_CMD=""
        warn "docker compose not found — containers will NOT be stopped/started automatically."
    fi
    verbose "Compose command: ${COMPOSE_CMD:-none}"
}

# ─── Confirm destructive action ───────────────────────────────────────────────
confirm() {
    local msg="$1"
    if $FORCE_RESTORE; then
        warn "$msg — auto-confirmed (FORCE_RESTORE=true)."
        return 0
    fi
    echo -e "${YELLOW}⚠  $msg${RESET}"
    read -rp "   Type YES to continue: " answer
    if [[ "$answer" != "YES" ]]; then
        info "Aborted by user."
        exit 0
    fi
}

# ─── Extract archive ─────────────────────────────────────────────────────────
extract_archive() {
    step "Extracting archive"
    WORK_DIR="$(mktemp -d /tmp/laravel_restore_XXXXXX)"
    info "Extracting to $WORK_DIR …"
    tar -xzf "$ARCHIVE" -C "$WORK_DIR"

    BACKUP_DIR="$(find "$WORK_DIR" -maxdepth 1 -mindepth 1 -type d | head -1)"
    if [[ -z "$BACKUP_DIR" ]]; then
        error "Archive appears to be empty or has unexpected structure."
        exit 1
    fi

    success "Extracted: $(basename "$BACKUP_DIR")"
    verbose "Contents:\n$(find "$BACKUP_DIR" -type f | sed "s|$BACKUP_DIR/||" | sed 's/^/  /')"
}

# ─── Verify manifest ─────────────────────────────────────────────────────────
verify_manifest() {
    step "Verifying manifest"
    MANIFEST="$BACKUP_DIR/MANIFEST.txt"

    if [[ ! -f "$MANIFEST" ]]; then
        warn "MANIFEST.txt not found — skipping integrity check."
        return
    fi

    info "Backup manifest:"
    echo ""
    grep -E "^(Date|Host|Project|OS|Docker|Config)" "$MANIFEST" | sed 's/^/  /'
    echo ""

    info "Verifying SHA-256 checksums…"
    CHECKSUM_ERRORS=0
    while IFS= read -r line; do
        HASH=$(echo "$line" | awk '{print $1}')
        REL_PATH=$(echo "$line" | awk '{print $2}')
        FULL_PATH="$BACKUP_DIR/$REL_PATH"
        if [[ -f "$FULL_PATH" ]]; then
            ACTUAL=$(sha256sum "$FULL_PATH" | awk '{print $1}')
            if [[ "$ACTUAL" != "$HASH" ]]; then
                error "Checksum mismatch: $REL_PATH"
                (( CHECKSUM_ERRORS++ )) || true
            else
                verbose "  ✔ $REL_PATH"
            fi
        fi
    done < <(sed -n '/── Checksums/,$ p' "$MANIFEST" | tail -n +2 | grep -v '^$' || true)

    if [[ "$CHECKSUM_ERRORS" -gt 0 ]]; then
        error "$CHECKSUM_ERRORS checksum error(s) detected. Archive may be corrupt."
        confirm "Continue restore despite checksum failures?"
    else
        success "All checksums verified."
    fi
}

# ─── Detect DB container ─────────────────────────────────────────────────────
detect_db_container() {
    if $SKIP_DB; then return; fi

    if [[ -n "$DB_CONTAINER" ]]; then
        if ! docker ps --format "{{.Names}}" | grep -q "^${DB_CONTAINER}$"; then
            warn "Specified DB container '$DB_CONTAINER' is not running. Skipping DB restore."
            SKIP_DB=true
        fi
        return
    fi

    DB_CONTAINER=$(docker ps --format "{{.Names}}\t{{.Image}}" \
        | grep -Ei "mysql|mariadb|postgres|pgsql" \
        | awk '{print $1}' | head -1 || true)

    if [[ -z "$DB_CONTAINER" ]]; then
        warn "No database container detected. Skipping DB restore."
        warn "Set DB_CONTAINER in config or use -c <name>."
        SKIP_DB=true
    else
        info "Auto-detected DB container: $DB_CONTAINER"
    fi
}

# ─── Read .env ───────────────────────────────────────────────────────────────
read_env() {
    ENV_FILE="$PROJECT_PATH/.env"
    [[ ! -f "$ENV_FILE" ]] && ENV_FILE="$PROJECT_PATH/.env.production"
    [[ ! -f "$ENV_FILE" ]] && ENV_FILE="$BACKUP_DIR/files/.env"

    if [[ -f "$ENV_FILE" ]]; then
        verbose "Reading credentials from $ENV_FILE"
        DB_CONNECTION=$(grep -E '^DB_CONNECTION=' "$ENV_FILE" | cut -d= -f2 | tr -d '\r"' || echo "mysql")
        DB_DATABASE=$(grep -E  '^DB_DATABASE='  "$ENV_FILE" | cut -d= -f2 | tr -d '\r"' || echo "")
        DB_USERNAME=$(grep -E  '^DB_USERNAME='  "$ENV_FILE" | cut -d= -f2 | tr -d '\r"' || echo "")
        DB_PASSWORD=$(grep -E  '^DB_PASSWORD='  "$ENV_FILE" | cut -d= -f2 | tr -d '\r"' || echo "")
    else
        warn ".env not found. DB restore will rely on container environment variables."
        DB_CONNECTION="mysql"; DB_DATABASE=""; DB_USERNAME=""; DB_PASSWORD=""
    fi
}

# ─── Stop / start containers ─────────────────────────────────────────────────
stop_containers() {
    if [[ -z "$COMPOSE_CMD" ]]; then return; fi
    COMPOSE_FILE=""
    for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        [[ -f "$PROJECT_PATH/$f" ]] && COMPOSE_FILE="$PROJECT_PATH/$f" && break
    done
    [[ -z "$COMPOSE_FILE" ]] && { verbose "No compose file found — skipping container stop."; return; }

    info "Stopping containers for safe restore…"
    (cd "$PROJECT_PATH" && $COMPOSE_CMD stop) && CONTAINERS_STOPPED=true || {
        warn "Could not stop containers — continuing anyway."
        CONTAINERS_STOPPED=false
    }
}

start_containers() {
    if [[ "${CONTAINERS_STOPPED:-false}" == true && -n "$COMPOSE_CMD" ]]; then
        info "Starting containers…"
        (cd "$PROJECT_PATH" && $COMPOSE_CMD up -d) || \
            warn "Could not start containers — start them manually."
    fi
}

# ─── 1. Restore project files ─────────────────────────────────────────────────
restore_files() {
    step "Restoring project files"

    if $SKIP_FILES; then
        info "Skipping project files restore (SKIP_FILES=true)."
        return
    fi

    FILES_ARCHIVE=$(find "$BACKUP_DIR/files" -maxdepth 1 -name "files_*.tar.gz" 2>/dev/null | head -1 || true)
    if [[ -z "$FILES_ARCHIVE" ]]; then
        warn "No project files archive found in backup. Skipping."
        return
    fi

    confirm "This will OVERWRITE files in $PROJECT_PATH — continue?"
    mkdir -p "$PROJECT_PATH"

    info "Restoring files to $PROJECT_PATH …"
    tar -xzf "$FILES_ARCHIVE" -C "$PROJECT_PATH"
    success "Project files restored."

    STORAGE_ARCHIVE=$(find "$BACKUP_DIR/files" -maxdepth 1 -name "storage_*.tar.gz" 2>/dev/null | head -1 || true)
    if [[ -n "$STORAGE_ARCHIVE" ]]; then
        info "Restoring storage directory…"
        mkdir -p "$PROJECT_PATH/storage"
        tar -xzf "$STORAGE_ARCHIVE" -C "$PROJECT_PATH/storage"
        success "Storage directory restored."
    fi

    info "Fixing storage/bootstrap permissions…"
    chown -R www-data:www-data "$PROJECT_PATH/storage" 2>/dev/null || \
        chown -R 1000:1000 "$PROJECT_PATH/storage" 2>/dev/null || \
        warn "Could not set storage ownership — fix manually."
    chmod -R 775 "$PROJECT_PATH/storage" "$PROJECT_PATH/bootstrap/cache" 2>/dev/null || true
    success "File permissions updated."
}

# ─── 2. Restore database ─────────────────────────────────────────────────────
restore_database() {
    step "Restoring database"

    if $SKIP_DB; then
        info "Skipping database restore (SKIP_DB=true)."
        return
    fi

    DUMP_FILE=$(find "$BACKUP_DIR/database" -maxdepth 1 -name "db_*.sql.gz" 2>/dev/null | head -1 || true)
    if [[ -z "$DUMP_FILE" ]]; then
        warn "No database dump found in backup. Skipping."
        return
    fi

    info "Dump file: $(basename "$DUMP_FILE")  ($(du -sh "$DUMP_FILE" | cut -f1))"
    DB_IMAGE=$(docker inspect --format='{{.Config.Image}}' "$DB_CONTAINER" 2>/dev/null || echo "")
    if echo "$DB_IMAGE" | grep -qiE "postgres|pgsql"; then restore_postgres "$DUMP_FILE"; else restore_mysql "$DUMP_FILE"; fi
}

restore_mysql() {
    local dump_file="$1"
    DB_USER="${DB_USERNAME:-root}"; DB_PASS="${DB_PASSWORD:-}"; DB_NAME="${DB_DATABASE:-}"

    if [[ -z "$DB_NAME" ]]; then
        DB_NAME=$(docker exec "$DB_CONTAINER" printenv MYSQL_DATABASE 2>/dev/null || \
                  docker exec "$DB_CONTAINER" printenv MARIADB_DATABASE 2>/dev/null || echo "")
    fi
    if [[ -z "$DB_USER" || "$DB_USER" == "root" ]]; then
        ROOT_PW=$(docker exec "$DB_CONTAINER" printenv MYSQL_ROOT_PASSWORD 2>/dev/null || \
                  docker exec "$DB_CONTAINER" printenv MARIADB_ROOT_PASSWORD 2>/dev/null || echo "")
        [[ -n "$ROOT_PW" ]] && DB_USER="root" && DB_PASS="$ROOT_PW"
    fi

    confirm "This will DROP and recreate database '$DB_NAME' in container '$DB_CONTAINER' — continue?"

    PASS_OPT=""; [[ -n "$DB_PASS" ]] && PASS_OPT="-p${DB_PASS}"

    info "Dropping and recreating database '$DB_NAME'…"
    docker exec "$DB_CONTAINER" \
        mysql -u"${DB_USER}" ${PASS_OPT} \
        -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`; CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
        2>/dev/null || { error "Failed to recreate database."; return 1; }

    info "Importing dump (this may take a while)…"
    zcat "$dump_file" | docker exec -i "$DB_CONTAINER" \
        mysql -u"${DB_USER}" ${PASS_OPT} "${DB_NAME}" && \
        success "MySQL/MariaDB database restored successfully." || { error "Database import failed."; return 1; }
}

restore_postgres() {
    local dump_file="$1"
    DB_USER="${DB_USERNAME:-postgres}"; DB_NAME="${DB_DATABASE:-postgres}"
    [[ -z "$DB_NAME" ]] && DB_NAME=$(docker exec "$DB_CONTAINER" printenv POSTGRES_DB 2>/dev/null || echo "postgres")
    [[ -z "$DB_USER" ]] && DB_USER=$(docker exec "$DB_CONTAINER" printenv POSTGRES_USER 2>/dev/null || echo "postgres")

    confirm "This will DROP and recreate PostgreSQL database '$DB_NAME' in container '$DB_CONTAINER' — continue?"

    docker exec "$DB_CONTAINER" psql -U "$DB_USER" -c "DROP DATABASE IF EXISTS \"${DB_NAME}\";" postgres 2>/dev/null || true
    docker exec "$DB_CONTAINER" psql -U "$DB_USER" -c "CREATE DATABASE \"${DB_NAME}\";" postgres 2>/dev/null || \
        { error "Failed to recreate PostgreSQL database."; return 1; }

    info "Importing dump…"
    zcat "$dump_file" | docker exec -i "$DB_CONTAINER" \
        psql -U "$DB_USER" "$DB_NAME" && \
        success "PostgreSQL database restored successfully." || { error "PostgreSQL import failed."; return 1; }
}

# ─── 3. Restore Docker volumes ───────────────────────────────────────────────
restore_volumes() {
    step "Restoring Docker volumes"

    if $SKIP_VOLUMES; then
        info "Skipping volumes restore (SKIP_VOLUMES=true)."
        return
    fi

    VOLUME_ARCHIVES=$(find "$BACKUP_DIR/volumes" -maxdepth 1 -name "vol_*.tar.gz" 2>/dev/null || true)
    if [[ -z "$VOLUME_ARCHIVES" ]]; then
        verbose "No volume archives found in backup. Skipping."
        return
    fi

    for VOL_ARCHIVE in $VOLUME_ARCHIVES; do
        FILENAME="$(basename "$VOL_ARCHIVE")"
        VOL_NAME=$(echo "$FILENAME" | sed 's/^vol_//' | sed 's/_[0-9]\{8\}_[0-9]\{6\}\.tar\.gz$//')
        info "Restoring volume: $VOL_NAME"

        if ! docker volume inspect "$VOL_NAME" &>/dev/null; then
            warn "Volume '$VOL_NAME' does not exist. Creating it…"
            docker volume create "$VOL_NAME" || { warn "Could not create volume '$VOL_NAME'. Skipping."; continue; }
        fi

        confirm "Overwrite all data in Docker volume '$VOL_NAME'?"

        docker run --rm \
            -v "${VOL_NAME}:/volume_data" \
            -v "$BACKUP_DIR/volumes:/backup:ro" \
            alpine \
            sh -c "rm -rf /volume_data/* /volume_data/..?* /volume_data/.[!.]* 2>/dev/null; \
                   tar -xzf /backup/${FILENAME} -C /volume_data" && \
            success "Volume '$VOL_NAME' restored." || \
            warn "Failed to restore volume '$VOL_NAME'. Check manually."
    done
}

# ─── 4. Restore Docker config files ──────────────────────────────────────────
restore_compose_config() {
    step "Restoring Docker config files"
    CONFIG_DIR="$BACKUP_DIR/config"

    if [[ ! -d "$CONFIG_DIR" ]] || [[ -z "$(ls -A "$CONFIG_DIR" 2>/dev/null)" ]]; then
        verbose "No Docker config files found in backup. Skipping."
        return
    fi

    info "Available Docker config files in backup:"
    ls "$CONFIG_DIR" | grep -v containers_inspect.json | sed 's/^/  /'

    if ! $FORCE_RESTORE; then
        echo ""
        read -rp "   Restore these config files to $PROJECT_PATH? [y/N]: " answer
        [[ "${answer,,}" != "y" ]] && { info "Skipping config restore."; return; }
    fi

    for f in "$CONFIG_DIR"/*; do
        FNAME="$(basename "$f")"
        [[ "$FNAME" == "containers_inspect.json" ]] && continue
        cp "$f" "$PROJECT_PATH/$FNAME" && verbose "Restored: $FNAME" || warn "Could not restore: $FNAME"
    done

    success "Docker config files restored."
}

# ─── 5. Post-restore Laravel steps ───────────────────────────────────────────
post_restore() {
    step "Post-restore Laravel steps"

    if [[ ! -f "$PROJECT_PATH/artisan" ]]; then
        verbose "No artisan file found. Skipping Laravel post-restore commands."
        return
    fi

    APP_CONTAINER=$(docker ps --format "{{.Names}}\t{{.Image}}" \
        | grep -Ev "mysql|mariadb|postgres|redis|nginx|node" \
        | awk '{print $1}' | head -1 || true)

    if [[ -z "$APP_CONTAINER" ]]; then
        warn "No app container detected. Run the following manually inside your container:"
        echo ""
        echo "  php artisan config:clear && php artisan config:cache"
        echo "  php artisan route:cache"
        echo "  php artisan view:cache"
        echo "  php artisan migrate --force"
        echo "  php artisan storage:link"
        echo "  php artisan queue:restart"
        echo ""
        return
    fi

    info "Detected app container: $APP_CONTAINER"
    run_artisan() {
        local cmd="$1"
        info "  Running: php artisan $cmd"
        docker exec "$APP_CONTAINER" php artisan $cmd 2>/dev/null && verbose "    → done" || warn "    → failed (non-fatal)"
    }

    run_artisan "config:clear"
    run_artisan "config:cache"
    run_artisan "route:cache"
    run_artisan "view:cache"
    run_artisan "migrate --force"
    run_artisan "storage:link"
    run_artisan "queue:restart"

    success "Laravel post-restore commands completed."
}

# ─── Notifications ────────────────────────────────────────────────────────────
notify() {
    local status="$1" msg="$2"
    HOSTNAME="$(hostname -s)"

    if [[ -n "$NOTIFY_EMAIL" ]] && command -v mail &>/dev/null; then
        echo "$msg" | mail -s "[Laravel Restore] $status — $HOSTNAME $(date '+%Y-%m-%d')" "$NOTIFY_EMAIL" && \
            verbose "Email sent to $NOTIFY_EMAIL" || warn "Email notification failed."
    fi

    if [[ -n "$SLACK_WEBHOOK" ]] && command -v curl &>/dev/null; then
        local emoji="✅"; [[ "$status" == "FAILED" ]] && emoji="❌"
        curl -s -X POST "$SLACK_WEBHOOK" \
            -H 'Content-type: application/json' \
            --data "{\"text\":\"${emoji} *Laravel Restore ${status}* on \`${HOSTNAME}\`\n${msg}\"}" \
            >/dev/null && verbose "Slack notification sent." || warn "Slack notification failed."
    fi
}

# ─── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${BOLD}══ Restore Summary ══${RESET}"
    echo ""
    echo -e "  Archive   : $ARCHIVE"
    echo -e "  Project   : $PROJECT_PATH"
    echo -e "  DB        : ${DB_CONTAINER:-skipped}"
    echo -e "  Config    : $CONFIG_FILE"
    echo ""
    echo -e "${GREEN}${BOLD}✔  Restore completed successfully.${RESET}"
    echo ""
    echo -e "  ${YELLOW}Next steps if not done automatically:${RESET}"
    echo "    1. Verify your .env file is correct"
    echo "    2. Run: composer install --no-dev --optimize-autoloader"
    echo "    3. Run: npm ci && npm run build   (if applicable)"
    echo "    4. Run: php artisan migrate --force"
    echo "    5. Run: docker compose up -d"
    echo ""
}

# ─── Trap for cleanup on error ───────────────────────────────────────────────
cleanup_on_error() {
    echo ""
    error "Restore interrupted. Starting containers back up if they were stopped…"
    start_containers 2>/dev/null || true
    [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR:-}" ]] && rm -rf "$WORK_DIR"
    log "=== Restore FAILED ==="
    notify "FAILED" "Restore of $PROJECT_PATH from $ARCHIVE failed at $(date '+%Y-%m-%d %H:%M:%S')."
    exit 1
}
trap cleanup_on_error INT TERM ERR

# ─── Cleanup temp dir on exit ─────────────────────────────────────────────────
cleanup() {
    [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR:-}" ]] && {
        verbose "Removing temporary work directory $WORK_DIR"
        rm -rf "$WORK_DIR"
    }
}
trap cleanup EXIT

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    load_config       # 1. Load ~/.laravel-docker.conf (or -C path)
    parse_args "$@"   # 2. CLI flags override config values

    preflight
    detect_compose
    extract_archive
    verify_manifest
    detect_db_container
    read_env

    stop_containers

    restore_files
    restore_database
    restore_volumes
    restore_compose_config

    start_containers

    post_restore

    log "=== Restore completed successfully ==="
    notify "SUCCESS" "Restore of $PROJECT_PATH from $ARCHIVE completed at $(date '+%Y-%m-%d %H:%M:%S')."

    print_summary
}

main "$@"