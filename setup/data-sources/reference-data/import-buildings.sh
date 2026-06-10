#!/bin/bash
set -euo pipefail

# =============================================================================
# CONTRACT — bash leaf script, invoked via `rbt import buildings` / `rbt setup`
# =============================================================================
# Inputs:  Overture Maps buildings from S3 (aws CLI); env DATABASE_*/PG_*
#          (provided by the rbt CLI).
# Outputs: overture schema tables in the target database; logs under
#          $SHARED_LOG_DIR.
# Exit:    0 on success, non-zero on any failed stage. Do not invoke directly
#          — only through the rbt CLI, which resolves and exports the
#          environment this script expects.
# =============================================================================

# =============================================================================
# OVERTURE BUILDINGS DATA INGESTION SCRIPT
# =============================================================================
#
# This script is specifically designed for downloading and ingesting Overture
# building data into a PostgreSQL database. It follows the same patterns and
# robustness features as the main database setup script including:
# - Structured logging with timestamps and progress tracking
# - Comprehensive error handling with cleanup and retry mechanisms
# - CI/CD specific features like health checks and resource management
# - Container-friendly signal handling and non-interactive operations
# - Environment validation and dependency checking
# - Automatic spatial index creation via ogr2ogr during ingestion
#
# DEBUGGING AND VERBOSITY OPTIONS:
# - Set DEBUG=true for maximum verbosity and error details
# - Set VERBOSE=true for progress indicators and additional logging
# - Set CLEAN_TEMP_FILES=false to preserve temp files for inspection
# 
# Example usage:
#   DEBUG=true VERBOSE=true ./setup_overture_buildings.sh
#   CLEAN_TEMP_FILES=false ./setup_overture_buildings.sh
#
# =============================================================================

# Global configuration
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source configuration file if available
CONFIG_DIR="${SCRIPT_DIR}/../../../config"
if [[ -f "${CONFIG_DIR}/rbt.conf" ]]; then
    echo "Loading configuration from ${CONFIG_DIR}/rbt.conf"
    # shellcheck source=/dev/null
    source "${CONFIG_DIR}/rbt.conf"
fi

# Configuration with fallbacks
readonly LOG_DIR="${SHARED_LOG_DIR:-${SCRIPT_DIR}/logs}"
readonly TEMP_DIR="${SHARED_TEMP_DIR:-${SCRIPT_DIR}/temp}"
readonly LOG_FILE="${LOG_DIR}/overture_buildings_$(date +%Y%m%d_%H%M%S).log"
readonly RETRY_COUNT="${SCRIPT_RETRY_COUNT:-3}"
readonly RETRY_DELAY="${SCRIPT_RETRY_DELAY:-30}"
readonly CONNECTION_TIMEOUT="${SCRIPT_CONNECTION_TIMEOUT:-300}"
readonly DEBUG="${SCRIPT_DEBUG:-false}"
readonly VERBOSE="${SCRIPT_VERBOSE:-false}"
readonly CLEAN_TEMP_FILES="${SCRIPT_CLEAN_TEMP_FILES:-false}"

# Database connection (built once)
readonly PG_CONNECTION="host=${PG_HOST} port=5432 dbname=rbt user=${PG_USR} password=${PG_PASS}"

# Check if output is to terminal for color support
if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly PURPLE='\033[0;35m'
    readonly CYAN='\033[0;36m'
    readonly NC='\033[0m' # No Color
else
    # No colors if not terminal
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly PURPLE=''
    readonly CYAN=''
    readonly NC=''
fi

# =============================================================================
# LOGGING AND UTILITY FUNCTIONS
# =============================================================================

# Initialize logging
init_logging() {
    mkdir -p "$LOG_DIR" "$TEMP_DIR"
    
    # Redirect all output to log file while preserving console output
    exec 1> >(tee -a "$LOG_FILE")
    exec 2> >(tee -a "$LOG_FILE" >&2)
    
    log_info "Logging initialized. Log file: $LOG_FILE"
    log_info "Temporary directory: $TEMP_DIR"
}

# Logging functions with structured format
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') [$$] $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') [$$] $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') [$$] $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') [$$] $*" >&2
}

log_progress() {
    echo -e "${PURPLE}[PROGRESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') [$$] $*"
}

log_debug() {
    if [[ "$DEBUG" == "true" || "$VERBOSE" == "true" ]]; then
        echo -e "${PURPLE}[DEBUG]${NC} $(date '+%Y-%m-%d %H:%M:%S') [$$] $*"
    fi
}

# Progress bar function (only show if terminal)
show_progress() {
    # Skip progress bar if not in terminal
    [[ ! -t 1 ]] && return 0
    
    local current=$1
    local total=$2
    local message=${3:-"Processing"}
    local bar_length=50
    local percentage=$((current * 100 / total))
    local filled=$((current * bar_length / total))
    
    printf "\r${CYAN}[PROGRESS]${NC} %s [" "$message"
    printf "%*s" $filled | tr ' ' '='
    printf "%*s" $((bar_length - filled)) "" | tr ' ' '-'
    printf "] %d%% (%d/%d)" $percentage $current $total
    
    if [ $current -eq $total ]; then
        echo ""
    fi
}

# Safe directory change
safe_cd() {
    local target_dir="$1"
    cd "$target_dir" || {
        log_error "Failed to change directory to: $target_dir"
        return 1
    }
}

# =============================================================================
# ENVIRONMENT AND DEPENDENCY VALIDATION
# =============================================================================

# Validate required environment variables
validate_environment() {
    log_info "Validating environment variables..."
    
    local required_vars=("PG_HOST" "PG_USR" "PG_PASS")
    local missing_vars=()
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required environment variables: ${missing_vars[*]}"
        log_error "Please set: ${missing_vars[*]}"
        exit 1
    fi
    
    # Validate database connection
    if ! validate_db_connection; then
        log_error "Database connection validation failed"
        exit 1
    fi
    
    log_success "Environment validation completed"
}

# Validate database connection
validate_db_connection() {
    log_info "Testing database connection..."
    
    if timeout "$CONNECTION_TIMEOUT" psql "$PG_CONNECTION" -c "SELECT version();" >/dev/null 2>&1; then
        log_success "Database connection successful"
        return 0
    else
        log_error "Failed to connect to database"
        return 1
    fi
}

# Check required system dependencies
check_dependencies() {
    log_info "Checking system dependencies..."
    
    local required_tools=("ogr2ogr" "aws" "psql" "timeout")
    local missing_tools=()
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_error "Required for Overture buildings processing:"
        log_error "  - ogr2ogr: GDAL/OGR for data processing"
        log_error "  - aws: AWS CLI for S3 data access"
        log_error "  - psql: PostgreSQL client"
        log_error "  - timeout: Command timeout utility"
        exit 1
    fi
    
    # Check GDAL version
    local gdal_version
    gdal_version=$(ogr2ogr --version 2>&1 | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
    log_info "GDAL version: $gdal_version"
    
    # Check AWS CLI configuration
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        log_warning "AWS CLI not configured with credentials, will use --no-sign-request for public data"
    fi
    
    log_success "All dependencies satisfied"
}

# =============================================================================
# DATABASE HELPER FUNCTIONS
# =============================================================================

# Create required database schemas
create_database_schemas() {
    log_info "Creating required database schemas..."
    
    local schemas=("overture")
    
    for schema in "${schemas[@]}"; do
        if execute_sql "CREATE SCHEMA IF NOT EXISTS ${schema};" "Create schema: ${schema}"; then
            log_success "Schema '${schema}' created successfully"
        else
            log_error "Failed to create schema: ${schema}"
            return 1
        fi
    done
    
    log_success "All database schemas created successfully"
    return 0
}

# Build PostgreSQL connection string for ogr2ogr
build_pg_connection() {
    local schema="${1:-public}"
    echo "PG:host=${PG_HOST} port=5432 dbname=rbt password=${PG_PASS} active_schema=${schema} user=${PG_USR}"
}

# Execute SQL command with error handling
execute_sql() {
    local sql_command="$1"
    local description="${2:-SQL command}"
    
    log_info "Executing: $description"
    
    if psql "$PG_CONNECTION" -c "$sql_command" >/dev/null 2>&1; then
        log_success "$description completed"
        return 0
    else
        log_error "$description failed"
        return 1
    fi
}

# Check if a table exists in the database
table_exists() {
    local schema="$1"
    local table="$2"
    
    log_debug "Checking if table ${schema}.${table} exists"
    
    # Use shell variable substitution with proper SQL escaping
    local result
    result=$(psql "$PG_CONNECTION" -t -A -c "
        SELECT EXISTS (
            SELECT 1 
            FROM information_schema.tables 
            WHERE table_schema = '${schema}'
            AND table_name = '${table}'
        );" 2>&1)
    
    # Check if the query succeeded
    if [[ $? -ne 0 ]]; then
        log_error "Failed to check if table ${schema}.${table} exists: $result"
        return 1
    fi
    
    # Trim whitespace and check result
    result=$(echo "$result" | tr -d '[:space:]')
    
    if [[ "$result" == "t" ]]; then
        log_info "Table ${schema}.${table} already exists, skipping ingestion"
        return 0
    else
        log_debug "Table ${schema}.${table} does not exist, proceeding with ingestion"
        return 1
    fi
}

# =============================================================================
# OVERTURE BUILDINGS DATA INGESTION
# =============================================================================

# Overture buildings data ingestion with retry logic
ingest_overture_buildings() {
    local retry_count=0
    
    log_info "Starting Overture buildings data ingestion..."
    
    while [[ $retry_count -lt $RETRY_COUNT ]]; do
        log_info "Attempt $((retry_count + 1))/$RETRY_COUNT for Overture buildings ingestion"
        
        if ingest_overture_buildings_impl; then
            log_success "Overture buildings ingestion completed successfully"
            return 0
        else
            local exit_code=$?
            log_warning "Attempt $((retry_count + 1)) failed with exit code $exit_code"
            
            if [[ $retry_count -lt $((RETRY_COUNT - 1)) ]]; then
                log_info "Retrying in ${RETRY_DELAY} seconds..."
                sleep "$RETRY_DELAY"
            fi
            
            ((retry_count++))
        fi
    done
    
    log_error "Overture buildings ingestion failed after $RETRY_COUNT attempts"
    return 1
}

# Implementation of Overture buildings ingestion
ingest_overture_buildings_impl() {
    log_info "Downloading and ingesting Overture buildings data..."
    
    # Check if table already exists
    if table_exists "overture" "building"; then
        log_info "Overture buildings data already exists, skipping ingestion"
        return 0
    fi
    
    safe_cd "$TEMP_DIR" || return 1
    
    # Download Overture buildings data (aws s3 sync handles incremental downloads automatically)
    log_info "Synchronizing Overture buildings data from S3..."
    log_progress "This may take a significant amount of time due to data size..."
    
    if ! aws s3 sync --no-sign-request \
        "s3://overturemaps-us-west-2/release/2025-05-21.0/theme=buildings/" \
        . \
        --only-show-errors \
        --cli-read-timeout 0 \
        --cli-connect-timeout 0; then
        log_error "Failed to download Overture buildings data from S3"
        return 1
    fi
    
    log_success "Overture buildings data synchronization completed"
    
    # Ingest building data
    if [[ -d "type=building" || -d "building" ]]; then
        local building_dir="building"
        [[ -d "type=building" ]] && building_dir="type=building"
        
        log_info "Ingesting Overture buildings..."
        log_progress "Processing building geometries and attributes..."
        
        if ! ogr2ogr -progress \
            -f "PostgreSQL" \
            --config PG_USE_COPY YES \
            "PG:dbname=rbt host=${PG_HOST} user=${PG_USR} password=${PG_PASS}" \
            -nln overture.building \
            -lco GEOMETRY_NAME=geometry \
            -lco DIM=2 \
            -lco UNLOGGED=ON \
            -skipfailures \
            "$building_dir" "$building_dir"; then
            log_error "Failed to ingest Overture buildings"
            return 1
        fi
        
        log_success "Overture buildings ingested successfully"
    else
        log_error "No building directory found after download"
        return 1
    fi
    
    # Ingest building part data if available
    if [[ -d "type=building_part" || -d "building_part" ]]; then
        local building_part_dir="building_part"
        [[ -d "type=building_part" ]] && building_part_dir="type=building_part"
        
        log_info "Ingesting Overture building parts..."
        log_progress "Processing building part geometries and attributes..."
        
        if ogr2ogr -progress \
            -f "PostgreSQL" \
            --config PG_USE_COPY YES \
            "PG:dbname=rbt host=${PG_HOST} user=${PG_USR} password=${PG_PASS}" \
            -nln overture.buildingpart \
            -lco GEOMETRY_NAME=geometry \
            -lco DIM=2 \
            -lco UNLOGGED=ON \
            -skipfailures \
            "$building_part_dir" "$building_part_dir"; then
            log_success "Overture building parts ingested successfully"
        else
            log_warning "Failed to ingest Overture building parts, but continuing (building parts are optional)"
        fi
    else
        log_info "No building parts data found, skipping building parts ingestion"
    fi
    
    return 0
}

# Analyze tables for query optimization
analyze_tables() {
    log_info "Analyzing Overture buildings tables for query optimization..."
    
    if table_exists "overture" "building"; then
        execute_sql "ANALYZE overture.building;" "Analyze overture.building table"
    fi
    
    if table_exists "overture" "buildingpart"; then
        execute_sql "ANALYZE overture.buildingpart;" "Analyze overture.buildingpart table"
    fi
}

# =============================================================================
# CLEANUP AND SIGNAL HANDLING
# =============================================================================

# Cleanup function
cleanup() {
    local exit_code=$?
    
    log_info "Cleaning up..."
    
    # Clean up temporary files (optional, for debugging leave them)
    if [[ "${CLEAN_TEMP_FILES}" == "true" ]]; then
        log_info "Removing temporary files..."
        rm -rf "$TEMP_DIR"
    else
        log_info "Temporary files preserved in: $TEMP_DIR"
        log_info "Set CLEAN_TEMP_FILES=true to automatically remove temp files"
    fi
    
    # Final status report
    if [[ $exit_code -eq 0 ]]; then
        log_success "Overture buildings processing completed successfully!"
    else
        log_error "Overture buildings processing failed with exit code: $exit_code"
    fi
    
    exit $exit_code
}

# Signal handlers for graceful shutdown in containers
trap cleanup EXIT
trap 'log_warning "Received SIGTERM, initiating graceful shutdown..."; exit 143' TERM
trap 'log_warning "Received SIGINT, initiating graceful shutdown..."; exit 130' INT

# =============================================================================
# MAIN EXECUTION FLOW
# =============================================================================

main() {
    local start_time
    start_time=$(date +%s)
    
    log_info "=== STARTING OVERTURE BUILDINGS DATA INGESTION ==="
    log_info "Script: $SCRIPT_NAME"
    log_info "Version: Extracted from main database setup script"
    log_info "Retry count: $RETRY_COUNT"
    log_info "Connection timeout: ${CONNECTION_TIMEOUT}s"
    log_info "Debug mode: $DEBUG"
    log_info "Verbose mode: $VERBOSE"
    
    # Initialize logging and validate environment
    init_logging
    validate_environment
    check_dependencies
    
    # Create required database schemas
    log_info "=== SCHEMA CREATION ==="
    if ! create_database_schemas; then
        log_error "Failed to create required database schemas"
        exit 1
    fi
    
    # Main data ingestion
    log_info "=== OVERTURE BUILDINGS DATA INGESTION ==="
    log_progress "Starting Overture buildings data processing..."
    
    if ! ingest_overture_buildings; then
        log_error "Overture buildings ingestion failed"
        exit 1
    fi
    
    # Post-processing optimizations
    log_info "=== POST-PROCESSING OPTIMIZATIONS ==="
    log_progress "Analyzing tables for query optimization..."
    
    analyze_tables
    
    # Final summary
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))
    
    log_success "=== OVERTURE BUILDINGS PROCESSING COMPLETED ==="
    log_success "Total execution time: ${hours}h ${minutes}m ${seconds}s"
    
    # Display table information
    if table_exists "overture" "building"; then
        local building_count
        building_count=$(psql "$PG_CONNECTION" -t -A -c "SELECT COUNT(*) FROM overture.building;" 2>/dev/null || echo "unknown")
        log_success "Buildings ingested: $building_count"
    fi
    
    if table_exists "overture" "buildingpart"; then
        local buildingpart_count
        buildingpart_count=$(psql "$PG_CONNECTION" -t -A -c "SELECT COUNT(*) FROM overture.buildingpart;" 2>/dev/null || echo "unknown")
        log_success "Building parts ingested: $buildingpart_count"
    fi
    
    log_success "Overture buildings processing finished successfully!"
}

# Execute main function with all arguments
main "$@"
