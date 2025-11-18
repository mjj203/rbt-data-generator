#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

CONFIG_FILE="${PROJECT_ROOT}/config/rbt.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
else
    echo "ERROR: Missing configuration file at $CONFIG_FILE" >&2
    exit 1
fi

: "${DATABASE_HOST:=${PG_HOST:-localhost}}"
: "${DATABASE_PORT:=${PG_PORT:-5432}}"
: "${DATABASE_NAME:=${PG_DATABASE:-rbt}}"
: "${DATABASE_USER:=${PG_USR:-postgres}}"
: "${DATABASE_PASSWORD:=${PG_PASS:-}}"

LOG_DIR="${SHARED_LOG_DIR:-${PROJECT_ROOT}/output/logs}"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/smoke_test_$(date +%Y%m%d_%H%M%S).log"

source "${PROJECT_ROOT}/scripts/lib/logging.sh"
rbt_log_init "${LOG_FILE}"

log() {
    rbt_log "$@"
}

log "INFO" "=== RBT Smoke Test Starting ==="

log "INFO" "Step 1: Validating environment"
./tools/validate-environment.sh >/dev/null

log "INFO" "Step 2: Ensuring database and extensions exist"
./setup/init-database.sh --setup-database >/dev/null

log "INFO" "Step 3: Running schema processing sanity check"
./setup/init-database.sh --process-schemas --physical >/dev/null

log "INFO" "Step 4: Tile generation dry runs"
./production/generate-tiles.sh --layer-type physical --projection 3857 --water --dry-run >/dev/null
./production/generate-tiles.sh --layer-type cultural --projection 4326 --building --dry-run >/dev/null

log "INFO" "Step 5: Verifying database connectivity"
PSQL_CONN="host=${DATABASE_HOST} port=${DATABASE_PORT} dbname=${DATABASE_NAME} user=${DATABASE_USER} password=${DATABASE_PASSWORD}"
psql "$PSQL_CONN" -c "SELECT NOW();" >/dev/null

log "INFO" "=== RBT Smoke Test Completed Successfully ==="

