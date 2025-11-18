#!/bin/bash
set -euo pipefail

# =============================================================================
# RBT OSM Continuous Updates Script
# =============================================================================
# This script runs continuous OSM updates using Imposm3.
# It should be run as a background service to keep OSM data current.
# =============================================================================

# Script metadata
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source configuration
readonly CONFIG_FILE="${PROJECT_ROOT}/config/rbt.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Configuration file not found: $CONFIG_FILE" >&2
    exit 1
fi

# Resolve database configuration (config first, env overrides second)
: "${DATABASE_HOST:=${PG_HOST:-localhost}}"
: "${DATABASE_PORT:=${PG_PORT:-5432}}"
: "${DATABASE_NAME:=${PG_DATABASE:-rbt}}"
: "${DATABASE_USER:=${PG_USR:-postgres}}"
: "${DATABASE_PASSWORD:=${PG_PASS:-}}"

# Backward-compatible exports for scripts/tools expecting PG_* names
export PG_HOST="${PG_HOST:-${DATABASE_HOST}}"
export PG_PORT="${PG_PORT:-${DATABASE_PORT}}"
export PG_USR="${PG_USR:-${DATABASE_USER}}"
export PG_PASS="${PG_PASS:-${DATABASE_PASSWORD}}"

readonly RBT_DB_CONN="host=${DATABASE_HOST} port=${DATABASE_PORT} dbname=${DATABASE_NAME} user=${DATABASE_USER} password=${DATABASE_PASSWORD}"

readonly LOG_DIR="${SHARED_LOG_DIR:-${PROJECT_ROOT}/output/logs}"
readonly LOG_FILE="${LOG_DIR}/osm_updates_$(date +%Y%m%d_%H%M%S).log"

# Ensure log directory exists
mkdir -p "${LOG_DIR}"

source "${PROJECT_ROOT}/scripts/lib/logging.sh"
rbt_log_init "${LOG_FILE}"

# =============================================================================
# Logging Functions
# =============================================================================

log() {
    rbt_log "$@"
}

# =============================================================================
# Validation Functions
# =============================================================================

validate_environment() {
    log "INFO" "Validating environment for OSM updates..."
    
    # Check required configuration variables
    local required_vars=("DATABASE_HOST" "DATABASE_USER" "DATABASE_PASSWORD" "DATABASE_NAME")
    local missing_vars=()
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log "ERROR" "Missing required configuration variables: ${missing_vars[*]}"
        log "ERROR" "Please check ${CONFIG_FILE}"
        exit 1
    fi
    
    # Test database connection
    if ! psql "${RBT_DB_CONN}" -c "SELECT 1" >/dev/null 2>&1; then
        log "ERROR" "Cannot connect to RBT database"
        exit 1
    fi
    
    # Check if imposm is available
    if ! command -v imposm >/dev/null 2>&1; then
        log "ERROR" "imposm command not found"
        exit 1
    fi
    
    log "INFO" "Environment validation passed"
}

# =============================================================================
# Signal Handling
# =============================================================================

cleanup() {
    log "INFO" "Received shutdown signal, cleaning up..."
    # Kill any running imposm processes
    pkill -f "imposm.*run" || true
    log "INFO" "Cleanup completed"
    exit 0
}

trap cleanup SIGINT SIGTERM

# =============================================================================
# Main Functions
# =============================================================================

run_continuous_updates() {
    log "INFO" "🔄 Starting continuous OSM updates"
    log "INFO" "This process will run indefinitely until stopped"
    log "INFO" "Log file: ${LOG_FILE}"
    log "INFO" "To stop: kill $$ or Ctrl+C"
    
    # Change to OSM data directory
    cd "${PROJECT_ROOT}/setup/data-sources/osm"
    
    # Run imposm in continuous mode
    log "INFO" "Starting imposm run with configuration: imposm-config.json"
    
    # This will run until interrupted
    imposm run -config imposm-config.json 2>&1 | while IFS= read -r line; do
        log "INFO" "[IMPOSM] $line"
    done
}

show_status() {
    log "INFO" "📊 OSM Update Status"
    
    # Check if imposm is running
    if pgrep -f "imposm.*run" >/dev/null; then
        log "INFO" "✅ OSM updates are currently running"
        log "INFO" "PID: $(pgrep -f 'imposm.*run')"
    else
        log "INFO" "❌ OSM updates are not running"
    fi
    
    # Show last update time from database
    local last_update
    last_update=$(psql "${RBT_DB_CONN}" \
                  -t -A -c "SELECT MAX(last_modified) FROM imposm3_log;" 2>/dev/null || echo "unknown")
    log "INFO" "Last OSM update: $last_update"
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
    case "${1:-run}" in
        run)
            validate_environment
            run_continuous_updates
            ;;
        status)
            validate_environment
            show_status
            ;;
        stop)
            log "INFO" "Stopping OSM updates..."
            pkill -f "imposm.*run" || log "WARN" "No running imposm processes found"
            log "INFO" "OSM updates stopped"
            ;;
        --help|-h)
            show_usage
            ;;
        *)
            log "ERROR" "Unknown command: $1"
            show_usage
            exit 1
            ;;
    esac
}

# Show usage if called with --help
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat << EOF
RBT OSM Continuous Updates Script

USAGE:
    $SCRIPT_NAME [COMMAND]

COMMANDS:
    run       Start continuous OSM updates (default)
    status    Show current update status
    stop      Stop running OSM updates
    --help    Show this help message

EXAMPLES:
    # Start continuous updates (runs indefinitely)
    $SCRIPT_NAME run

    # Check if updates are running
    $SCRIPT_NAME status

    # Stop updates
    $SCRIPT_NAME stop

    # Run in background
    nohup $SCRIPT_NAME run &

EOF
    exit 0
fi

# Execute main function
main "$@"
