#!/usr/bin/env bash
# bi: Full backup of a Laravel Docker project (DB, volumes, files)
# bi-arg: -p=@dir   Project root
# bi-arg: -o=@dir   Output directory
# bi-arg: -r=       Retention in days
# bi-arg: -c=       DB container (auto-detected)
# bi-arg: -C=@file  Config file
# bi-arg: -s        Skip database
# bi-arg: -V        Skip Docker volumes
# bi-arg: -f        Skip project files
# bi-arg: -v        Verbose
# bi-arg: -h        Show help
# =============================================================================
#  Laravel Docker Project — Full Backup Script
#  Compatible with Ubuntu 24.04
#
#  Usage: sudo bash laravel_docker_backup.sh [OPTIONS]
#
#  Config file (loaded automatically if present):
#    ~/.laravel-docker.conf
#
#  Options (override config file values):
#    -p  /path/to/laravel       Project root
#    -o  /path/to/backup/dir    Output directory
#    -r  <days>                 Retention period in days
#    -c  <db_container>         DB container name (auto-detected if omitted)
#    -s                         Skip database backup
#    -V                         Skip Docker volumes backup
#    -f                         Skip project files backup
#    -v                         Verbose output
#    -C  /path/to/config        Use a custom config file path
#    -h                         Show this help
#
#  Examples:
#    sudo bash laravel_docker_backup.sh
#    sudo bash laravel_docker_backup.sh -p /var/www/myapp -o /backups -r 14
#    sudo bash laravel_docker_backup.sh -C /etc/myapp/backup.conf
#    sudo bash laravel_docker_backup.sh -s   # skip DB (overrides config)
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
log()     { [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" || true; }

# ─── Built-in defaults (lowest priority) ─────────────────────────────────────
PROJECT_PATH="$(pwd)"
BACKUP_BASE="$HOME/laravel-backups"
RETENTION_DAYS=30
DB_CONTAINER=""
SKIP_DB=false
SKIP_VOLUMES=false
SKIP_FILES=false
EXTRA_EXCLUDES=""
NOTIFY_EMAIL=""
SLACK_WEBHOOK=""
LOG_FILE=""
VERBOSE=false

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
HOSTNAME="$(hostname -s)"

# ─── Config file path (can be overridden with -C before other flags) ──────────
CONFIG_FILE="${HOME}/.config/midx-backup.conf"

# Pre-scan argv for -C so config is loaded before other flag parsing
for i in "$@"; do
    if [[ "${PREV_ARG:-}" == "-C" ]]; then
        CONFIG_FILE="$i"
    fi
    PREV_ARG="$i"
done

# ─── Load config file ─────────────────────────────────────────────────────────
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # Validate: only allow safe KEY=VALUE lines and comments
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
    sed -n '3,23p' "$0" | sed 's/^#  \{0,2\}//'
    exit 0
}

# ─── CLI flags (highest priority — override config values) ───────────────────
parse_args() {
    while getopts ":p:o:r:c:C:sVfvh" opt; do
        case $opt in
            p) PROJECT_PATH="$OPTARG" ;;
            o) BACKUP_BASE="$OPTARG" ;;
            r) RETENTION_DAYS="$OPTARG" ;;
            c) DB_CONTAINER="$OPTARG" ;;
            C) : ;; # already handled in pre-scan above
            s) SKIP_DB=true ;;
            V) SKIP_VOLUMES=true ;;
            f) SKIP_FILES=true ;;
            v) VERBOSE=true ;;
            h) usage ;;
            :) error "Option -$OPTARG requires an argument."; exit 1 ;;
            \?) error "Unknown option: -$OPTARG"; exit 1 ;;
        esac
    done
}

# ─── Pre-flight checks ───────────────────────────────────────────────────────
preflight() {
    echo -e "\n${BOLD}══ Laravel Docker Backup ══${RESET}"
    info "Timestamp  : $TIMESTAMP"
    info "Project    : $PROJECT_PATH"
    info "Output     : $BACKUP_BASE"
    info "Retention  : ${RETENTION_DAYS} days"
    info "Config     : ${CONFIG_FILE}"
    [[ -n "$LOG_FILE" ]] && info "Log file   : $LOG_FILE"
    echo ""

    log "=== Backup started ==="
    log "Project: $PROJECT_PATH | Output: $BACKUP_BASE | Retention: ${RETENTION_DAYS}d"

    if [[ $EUID -ne 0 ]]; then
        warn "Not running as root — some Docker volumes may be unreadable."
        warn "Re-run with sudo for a complete backup."
    fi

    if [[ ! -d "$PROJECT_PATH" ]]; then
        error "Project path '$PROJECT_PATH' does not exist."
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
        warn "docker compose not found — containers will NOT be paused during backup."
    fi
    verbose "Compose command: ${COMPOSE_CMD:-none}"
}

# ─── Detect running containers for the project ───────────────────────────────
detect_containers() {
    info "Detecting Docker containers…"
    PROJECT_NAME="$(basename "$PROJECT_PATH" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')"
    RUNNING_CONTAINERS=$(docker ps --filter "name=${PROJECT_NAME}" --format "{{.Names}}" 2>/dev/null || true)

    if [[ -z "$RUNNING_CONTAINERS" ]]; then
        RUNNING_CONTAINERS=$(docker ps --format "{{.Names}}" 2>/dev/null || true)
        verbose "Fallback: listing all containers."
    fi

    verbose "Found containers:\n$(echo "$RUNNING_CONTAINERS" | sed 's/^/  /')"
}

# ─── Detect database container ───────────────────────────────────────────────
detect_db_container() {
    if $SKIP_DB; then return; fi

    if [[ -n "$DB_CONTAINER" ]]; then
        if ! docker ps --format "{{.Names}}" | grep -q "^${DB_CONTAINER}$"; then
            warn "Specified DB container '$DB_CONTAINER' is not running. Skipping DB backup."
            SKIP_DB=true
        fi
        return
    fi

    DB_CONTAINER=$(docker ps --format "{{.Names}}\t{{.Image}}" \
        | grep -Ei "mysql|mariadb|postgres|pgsql" \
        | awk '{print $1}' | head -1 || true)

    if [[ -z "$DB_CONTAINER" ]]; then
        warn "No database container detected. Skipping DB backup."
        warn "Set DB_CONTAINER in config or use -c <name>."
        SKIP_DB=true
    else
        info "Auto-detected DB container: $DB_CONTAINER"
    fi
}

# ─── Read Laravel .env for DB credentials ────────────────────────────────────
read_env() {
    ENV_FILE="$PROJECT_PATH/.env"
    [[ ! -f "$ENV_FILE" ]] && ENV_FILE="$PROJECT_PATH/.env.production"

    if [[ -f "$ENV_FILE" ]]; then
        verbose "Reading .env from $ENV_FILE"
        DB_CONNECTION=$(grep -E '^DB_CONNECTION=' "$ENV_FILE" | cut -d= -f2 | tr -d '\r"' || echo "mysql")
        DB_DATABASE=$(grep -E  '^DB_DATABASE='  "$ENV_FILE" | cut -d= -f2 | tr -d '\r"' || echo "")
        DB_USERNAME=$(grep -E  '^DB_USERNAME='  "$ENV_FILE" | cut -d= -f2 | tr -d '\r"' || echo "")
        DB_PASSWORD=$(grep -E  '^DB_PASSWORD='  "$ENV_FILE" | cut -d= -f2 | tr -d '\r"' || echo "")
    else
        warn ".env file not found. DB backup will use container environment variables."
        DB_CONNECTION="mysql"; DB_DATABASE=""; DB_USERNAME=""; DB_PASSWORD=""
    fi
}

# ─── Pause / resume containers ───────────────────────────────────────────────
pause_containers() {
    if [[ -z "$COMPOSE_CMD" ]]; then return; fi
    COMPOSE_FILE=""
    for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        [[ -f "$PROJECT_PATH/$f" ]] && COMPOSE_FILE="$PROJECT_PATH/$f" && break
    done
    [[ -z "$COMPOSE_FILE" ]] && { verbose "No compose file — skipping pause."; return; }

    info "Pausing containers for a consistent snapshot…"
    (cd "$PROJECT_PATH" && $COMPOSE_CMD pause) && CONTAINERS_PAUSED=true || {
        warn "Could not pause containers. Continuing with live backup."
        CONTAINERS_PAUSED=false
    }
}

resume_containers() {
    if [[ "${CONTAINERS_PAUSED:-false}" == true && -n "$COMPOSE_CMD" ]]; then
        info "Resuming containers…"
        (cd "$PROJECT_PATH" && $COMPOSE_CMD unpause) || warn "Could not unpause containers — check manually."
    fi
}

# ─── Create backup directory structure ───────────────────────────────────────
prepare_dirs() {
    BACKUP_DIR="$BACKUP_BASE/${HOSTNAME}_${TIMESTAMP}"
    mkdir -p "$BACKUP_DIR"/{files,database,volumes,config}
    info "Backup directory: $BACKUP_DIR"
}

# ─── 1. Project files ────────────────────────────────────────────────────────
backup_files() {
    if $SKIP_FILES; then
        info "Skipping project files backup (SKIP_FILES=true)."
        return
    fi

    info "Backing up project files…"

    EXCLUDE_OPTS=(
        --exclude="node_modules"
        --exclude="vendor"
        --exclude=".git"
        --exclude=".env"
        --exclude="storage/logs"
        --exclude="storage/framework/cache"
        --exclude="storage/framework/sessions"
        --exclude="storage/framework/views"
        --exclude="*.log"
    )

    # Append EXTRA_EXCLUDES from config
    if [[ -n "$EXTRA_EXCLUDES" ]]; then
        for pattern in $EXTRA_EXCLUDES; do
            EXCLUDE_OPTS+=(--exclude="$pattern")
            verbose "  Extra exclude: $pattern"
        done
    fi

    tar -czf "$BACKUP_DIR/files/files_${TIMESTAMP}.tar.gz" \
        "${EXCLUDE_OPTS[@]}" \
        -C "$(dirname "$PROJECT_PATH")" \
        "$(basename "$PROJECT_PATH")" && \
        success "Project files archived: $(du -sh "$BACKUP_DIR/files/files_${TIMESTAMP}.tar.gz" | cut -f1)" || \
        warn "Project files archive had warnings (non-fatal)."

    # Storage directory separately (may be large)
    if [[ -d "$PROJECT_PATH/storage" ]]; then
        info "  Archiving storage directory separately…"
        tar -czf "$BACKUP_DIR/files/storage_${TIMESTAMP}.tar.gz" \
            --exclude="*.log" \
            -C "$PROJECT_PATH" storage && \
            success "  Storage archived: $(du -sh "$BACKUP_DIR/files/storage_${TIMESTAMP}.tar.gz" | cut -f1)" || \
            warn "  Storage archive had warnings."
    fi
}

# ─── 2. Database ─────────────────────────────────────────────────────────────
backup_database() {
    $SKIP_DB && return
    info "Backing up database (container: $DB_CONTAINER)…"
    DB_IMAGE=$(docker inspect --format='{{.Config.Image}}' "$DB_CONTAINER" 2>/dev/null || echo "")
    if echo "$DB_IMAGE" | grep -qiE "postgres|pgsql"; then backup_postgres; else backup_mysql; fi
}

backup_mysql() {
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
    DUMP_FILE="$BACKUP_DIR/database/db_${TIMESTAMP}.sql.gz"
    PASS_OPT=""; [[ -n "$DB_PASS" ]] && PASS_OPT="-p${DB_PASS}"
    DUMP_CMD="mysqldump -u${DB_USER} ${PASS_OPT} --single-transaction --routines --triggers --events"
    [[ -n "$DB_NAME" ]] && DUMP_CMD+=" $DB_NAME" || DUMP_CMD+=" --all-databases"

    if docker exec "$DB_CONTAINER" bash -c "$DUMP_CMD" 2>/dev/null | gzip > "$DUMP_FILE"; then
        success "MySQL/MariaDB dump: $(du -sh "$DUMP_FILE" | cut -f1)"
    else
        error "Database dump failed."; rm -f "$DUMP_FILE"
    fi
}

backup_postgres() {
    DB_USER="${DB_USERNAME:-postgres}"; DB_NAME="${DB_DATABASE:-postgres}"
    [[ -z "$DB_NAME" ]] && DB_NAME=$(docker exec "$DB_CONTAINER" printenv POSTGRES_DB 2>/dev/null || echo "postgres")
    [[ -z "$DB_USER" ]] && DB_USER=$(docker exec "$DB_CONTAINER" printenv POSTGRES_USER 2>/dev/null || echo "postgres")
    DUMP_FILE="$BACKUP_DIR/database/db_${TIMESTAMP}.sql.gz"

    if docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" "$DB_NAME" 2>/dev/null | gzip > "$DUMP_FILE"; then
        success "PostgreSQL dump: $(du -sh "$DUMP_FILE" | cut -f1)"
    else
        error "PostgreSQL dump failed."
    fi
}

# ─── 3. Docker Volumes ────────────────────────────────────────────────────────
backup_volumes() {
    if $SKIP_VOLUMES; then
        info "Skipping volumes backup (SKIP_VOLUMES=true)."
        return
    fi

    info "Discovering Docker volumes for this project…"
    VOLUME_NAMES=$(docker ps --format "{{.Names}}" \
        | grep -i "$(basename "$PROJECT_PATH" | tr '[:upper:]' '[:lower:]')" \
        | xargs -I{} docker inspect --format='{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' {} \
        2>/dev/null | tr ' ' '\n' | sort -u | grep -v '^$' || true)

    if [[ -z "$VOLUME_NAMES" ]]; then
        verbose "No named volumes detected for project containers."
        return
    fi

    for VOL in $VOLUME_NAMES; do
        info "  Backing up volume: $VOL"
        docker run --rm \
            -v "${VOL}:/volume_data:ro" \
            -v "$BACKUP_DIR/volumes:/backup" \
            alpine \
            tar -czf "/backup/vol_${VOL}_${TIMESTAMP}.tar.gz" -C /volume_data . \
            2>/dev/null && \
            success "  Volume $VOL archived." || \
            warn "  Could not backup volume $VOL."
    done
}

# ─── 4. Docker config files ───────────────────────────────────────────────────
backup_compose() {
    info "Backing up Docker configuration files…"
    for f in \
        docker-compose.yml docker-compose.yaml compose.yml compose.yaml \
        docker-compose.override.yml Dockerfile Dockerfile.prod \
        .dockerignore nginx.conf nginx/*.conf php.ini php/local.ini supervisord.conf; do
        for match in $PROJECT_PATH/$f; do
            [[ -f "$match" ]] && cp "$match" "$BACKUP_DIR/config/" && verbose "Copied $(basename "$match")"
        done
    done

    if [[ -n "$RUNNING_CONTAINERS" ]]; then
        echo "$RUNNING_CONTAINERS" | xargs docker inspect \
            > "$BACKUP_DIR/config/containers_inspect.json" 2>/dev/null || true
        verbose "Container inspect saved."
    fi
    success "Docker config files backed up."
}

# ─── 5. Manifest ─────────────────────────────────────────────────────────────
write_manifest() {
    MANIFEST="$BACKUP_DIR/MANIFEST.txt"
    {
        echo "========================================"
        echo "  Laravel Docker Backup Manifest"
        echo "========================================"
        echo "Date       : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "Host       : $HOSTNAME"
        echo "Project    : $PROJECT_PATH"
        echo "Backup dir : $BACKUP_DIR"
        echo "Config     : $CONFIG_FILE"
        echo ""
        echo "── System ───────────────────────────────"
        echo "OS         : $(lsb_release -ds 2>/dev/null || uname -r)"
        echo "Docker     : $(docker --version)"
        echo ""
        echo "── Running containers ───────────────────"
        docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" 2>/dev/null || echo "N/A"
        echo ""
        echo "── Backup contents ──────────────────────"
        find "$BACKUP_DIR" -type f | sort | while read -r f; do
            SIZE=$(du -sh "$f" | cut -f1)
            echo "  [$SIZE]  ${f#$BACKUP_DIR/}"
        done
        echo ""
        echo "── Checksums (SHA-256) ──────────────────"
        find "$BACKUP_DIR" -type f ! -name "MANIFEST.txt" | sort | xargs sha256sum 2>/dev/null | \
            sed "s|$BACKUP_DIR/||"
    } > "$MANIFEST"
    success "Manifest written."
}

# ─── 6. Compress ─────────────────────────────────────────────────────────────
compress_backup() {
    info "Compressing final backup archive…"
    ARCHIVE="${BACKUP_BASE}/${HOSTNAME}_laravel_backup_${TIMESTAMP}.tar.gz"
    tar -czf "$ARCHIVE" -C "$BACKUP_BASE" "$(basename "$BACKUP_DIR")"
    rm -rf "$BACKUP_DIR"
    BACKUP_SIZE=$(du -sh "$ARCHIVE" | cut -f1)
    success "Archive created: $ARCHIVE  (${BACKUP_SIZE})"
    echo ""
    echo -e "  ${BOLD}Final backup:${RESET} $ARCHIVE"
    echo -e "  ${BOLD}Size:${RESET}         $BACKUP_SIZE"
    log "Archive created: $ARCHIVE ($BACKUP_SIZE)"
}

# ─── 7. Prune old backups ────────────────────────────────────────────────────
prune_old_backups() {
    info "Pruning backups older than ${RETENTION_DAYS} days…"
    COUNT=$(find "$BACKUP_BASE" -maxdepth 1 -name "*_laravel_backup_*.tar.gz" \
        -mtime +"$RETENTION_DAYS" 2>/dev/null | wc -l)
    if [[ "$COUNT" -gt 0 ]]; then
        find "$BACKUP_BASE" -maxdepth 1 -name "*_laravel_backup_*.tar.gz" \
            -mtime +"$RETENTION_DAYS" -delete
        success "Removed $COUNT old backup(s)."
        log "Pruned $COUNT backup(s) older than ${RETENTION_DAYS} days."
    else
        verbose "No backups older than ${RETENTION_DAYS} days found."
    fi
}

# ─── 8. Notifications ────────────────────────────────────────────────────────
notify() {
    local status="$1" msg="$2"

    # Email
    if [[ -n "$NOTIFY_EMAIL" ]] && command -v mail &>/dev/null; then
        echo "$msg" | mail -s "[Laravel Backup] $status — $HOSTNAME $(date '+%Y-%m-%d')" "$NOTIFY_EMAIL" && \
            verbose "Email sent to $NOTIFY_EMAIL" || warn "Email notification failed."
    fi

    # Slack
    if [[ -n "$SLACK_WEBHOOK" ]] && command -v curl &>/dev/null; then
        local emoji="✅"; [[ "$status" == "FAILED" ]] && emoji="❌"
        curl -s -X POST "$SLACK_WEBHOOK" \
            -H 'Content-type: application/json' \
            --data "{\"text\":\"${emoji} *Laravel Backup ${status}* on \`${HOSTNAME}\`\n${msg}\"}" \
            >/dev/null && verbose "Slack notification sent." || warn "Slack notification failed."
    fi
}

# ─── Trap for cleanup on error ───────────────────────────────────────────────
cleanup_on_error() {
    echo ""
    error "Backup interrupted. Cleaning up…"
    resume_containers
    [[ -n "${BACKUP_DIR:-}" && -d "${BACKUP_DIR:-}" ]] && rm -rf "$BACKUP_DIR"
    log "=== Backup FAILED ==="
    notify "FAILED" "Backup of $PROJECT_PATH failed at $(date '+%Y-%m-%d %H:%M:%S')."
    exit 1
}
trap cleanup_on_error INT TERM ERR

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    load_config       # 1. Load ~/.laravel-docker.conf (or -C path)
    parse_args "$@"   # 2. CLI flags override config values

    preflight
    detect_compose
    detect_containers
    detect_db_container
    read_env
    prepare_dirs

    pause_containers

    backup_files
    backup_database
    backup_volumes
    backup_compose

    resume_containers

    write_manifest
    compress_backup
    prune_old_backups

    log "=== Backup completed successfully ==="
    notify "SUCCESS" "Backup of $PROJECT_PATH completed.\nArchive: ${ARCHIVE:-unknown}\nSize: ${BACKUP_SIZE:-unknown}"

    echo ""
    echo -e "${GREEN}${BOLD}✔  Backup completed successfully.${RESET}"
    echo ""
}

main "$@"