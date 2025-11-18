#!/bin/bash
set -euo pipefail

# =============================================================================
# RBT Vector Tiles Database Initialization Script
# =============================================================================
# This script performs one-time initialization of the RBT database including:
# - OSM data import using Imposm3
# - Reference data import (FieldMaps, Natural Earth, etc.)
# - GeoNames data import
# - Overture buildings import  
# - Database schema processing for physical and cultural features
#
# CLI Usage:
# - Run all: ./init-database.sh --all (or no arguments for backward compatibility)
# - Individual functions: ./init-database.sh --import-osm-data [osm-flags]
# - Pass-through args: ./init-database.sh --import-osm-data --download-planet
# =============================================================================

# Script metadata
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly START_TIME=$(date +%s)
readonly TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Source configuration file if available
CONFIG_DIR="${PROJECT_ROOT}/config"
if [[ -f "${CONFIG_DIR}/rbt.conf" ]]; then
    echo "Loading configuration from ${CONFIG_DIR}/rbt.conf"
    # shellcheck source=/dev/null
    source "${CONFIG_DIR}/rbt.conf"
fi

# Resolve database configuration (config first, then environment overrides)
: "${DATABASE_HOST:=${PG_HOST:-localhost}}"
: "${DATABASE_PORT:=${PG_PORT:-5432}}"
: "${DATABASE_NAME:=${PG_DATABASE:-rbt}}"
: "${DATABASE_USER:=${PG_USR:-postgres}}"
: "${DATABASE_PASSWORD:=${PG_PASS:-}}"

# Maintain backward-compatible environment variables for scripts that still
# expect PG_* names while ensuring everything defaults to the centralized config.
export PG_HOST="${PG_HOST:-${DATABASE_HOST}}"
export PG_PORT="${PG_PORT:-${DATABASE_PORT}}"
export PG_USR="${PG_USR:-${DATABASE_USER}}"
export PG_PASS="${PG_PASS:-${DATABASE_PASSWORD}}"

# Connection strings reused throughout the script
readonly ADMIN_DB_CONN="host=${DATABASE_HOST} port=${DATABASE_PORT} dbname=postgres user=${DATABASE_USER} password=${DATABASE_PASSWORD}"
readonly RBT_DB_CONN="host=${DATABASE_HOST} port=${DATABASE_PORT} dbname=${DATABASE_NAME} user=${DATABASE_USER} password=${DATABASE_PASSWORD}"

set_database_env() {
    export PGHOST="${DATABASE_HOST}"
    export PGPORT="${DATABASE_PORT}"
    export PGUSER="${DATABASE_USER}"
    export PGDATABASE="${DATABASE_NAME}"
    export PGPASSWORD="${DATABASE_PASSWORD}"
    export PG_USR="${DATABASE_USER}"
    export PG_PASS="${DATABASE_PASSWORD}"
}

# Configuration
readonly LOG_DIR="${SHARED_LOG_DIR:-${PROJECT_ROOT}/output/logs}"
readonly LOG_FILE="${LOG_DIR}/database_init_${TIMESTAMP}.log"

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

# Progress indicator wrapper
show_progress() {
    rbt_log_progress "$@"
}

# =============================================================================
# Validation Functions
# =============================================================================

validate_environment() {
    log "INFO" "Validating environment..."
    
    # Check required configuration variables
    local required_vars=("DATABASE_HOST" "DATABASE_USER" "DATABASE_NAME")
    local missing_vars=()
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log "ERROR" "Missing required configuration values: ${missing_vars[*]}"
        log "ERROR" "Update config/rbt.conf or provide environment overrides before running this script."
        exit 1
    fi
    
    # Test database connection
    if ! psql "${ADMIN_DB_CONN}" -c "SELECT 1" >/dev/null 2>&1; then
        log "ERROR" "Cannot connect to database. Please check your credentials."
        exit 1
    fi
    
    log "INFO" "Environment validation passed"
}

validate_dependencies() {
    log "INFO" "Checking system dependencies..."
    
    local required_tools=("ogr2ogr" "psql" "wget" "imposm" "tippecanoe" "tile-join")
    local missing_tools=()
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log "ERROR" "Missing required tools: ${missing_tools[*]}"
        log "ERROR" "Please install missing dependencies"
        exit 1
    fi
    
    log "INFO" "All dependencies satisfied"
}

# =============================================================================
# Database Setup Functions
# =============================================================================

setup_database() {
    log "STEP" "Setting up database and extensions..."
    
    # Create database if it doesn't exist
    if ! psql "${ADMIN_DB_CONN}" \
         -c "SELECT 1 FROM pg_database WHERE datname='${DATABASE_NAME}'" | grep -q 1; then
        log "INFO" "Creating database '${DATABASE_NAME}'..."
        psql "${ADMIN_DB_CONN}" \
             -c "CREATE DATABASE ${DATABASE_NAME};"
    fi
    
    # Create extensions
    log "INFO" "Creating required extensions..."
    psql "${RBT_DB_CONN}" << EOF
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_raster;
CREATE EXTENSION IF NOT EXISTS hstore;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
EOF
    
    log "INFO" "Database setup completed"
}

# =============================================================================
# Data Import Functions
# =============================================================================

import_osm_data() {
    log "STEP" "Importing OSM data (this may take several hours)..."
    
    # Set environment for OSM import
    set_database_env
    
    cd "${PROJECT_ROOT}/setup/data-sources/osm"
    if ! ./import-osm-data.sh; then
        log "ERROR" "OSM data import failed"
        return 1
    fi
    
    log "INFO" "OSM data import completed"
}

import_reference_data() {
    log "STEP" "Importing reference datasets..."
    
    # Set environment for reference data import
    set_database_env
    
    cd "${PROJECT_ROOT}/setup/data-sources/reference-data"
    
    # Import base reference data
    if ! ./import-reference-data.sh; then
        log "ERROR" "Reference data import failed"
        return 1
    fi
    
    # Import GeoNames data
    if ! ./import-geonames.sh; then
        log "ERROR" "GeoNames import failed"
        return 1
    fi
    
    # Import building data
    if ! ./import-buildings.sh; then
        log "ERROR" "Buildings import failed"
        return 1
    fi
    
    log "INFO" "Reference data import completed"
}

process_schemas() {
    log "STEP" "Processing database schemas..."
    
    # Set database environment variables that the schema scripts expect
    set_database_env
    
    # Process physical schemas using wrapper script
    log "INFO" "Processing physical feature schemas..."
    cd "${PROJECT_ROOT}/setup/data-sources/schemas/physical"
    if ! ./process-physical-schemas.sh --all; then
        log "ERROR" "Physical schema processing failed"
        return 1
    fi
    
    # Process cultural schemas using wrapper script  
    log "INFO" "Processing cultural feature schemas..."
    cd "${PROJECT_ROOT}/setup/data-sources/schemas/cultural"
    if ! ./process-cultural-schemas.sh --all; then
        log "ERROR" "Cultural schema processing failed"
        return 1
    fi
    
    log "INFO" "Schema processing completed"
}

# =============================================================================
# Usage and Help Functions
# =============================================================================

show_usage() {
    echo "Usage: $0 [OPTION] [SUB-OPTIONS]"
    echo "Initialize RBT Vector Tiles database with flexible processing options."
    echo ""
    echo "Main Options:"
    echo "  --all                     Run complete database initialization (default)"
    echo "  --setup-database          Setup database and extensions only"
    echo "  --import-osm-data         Import OSM data using Imposm3"
    echo "  --import-reference-data   Import reference datasets (FieldMaps, Natural Earth, etc.)"
    echo "  --import-geonames         Import GeoNames data only"
    echo "  --import-buildings        Import Overture buildings data only"
    echo "  --process-schemas         Process database schemas (physical and cultural)"
    echo "  --process-cultural        Process cultural schemas only"
    echo "  --process-physical        Process physical schemas only"
    echo "  --help                    Show this help message"
    echo ""
    echo "OSM Data Import Sub-options (use with --import-osm-data):"
    echo "  --all                     Run all OSM processes (default)"
    echo "  --download-planet         Download planet file only"
    echo "  --download-diffs START END Download diff files only (requires start and end sequence)"
    echo "  --merge-diffs             Merge diff files only"
    echo "  --apply-changes           Apply changes to planet file only"
    echo "  --import                  Import data with imposm only"
    echo "  --run-imposm              Run imposm for continuous updates only"
    echo ""
    echo "Schema Processing Sub-options:"
    echo "  Cultural schemas (use with --process-cultural):"
    echo "    --all                   Process all cultural schemas (default)"
    echo "    --cultural              Process only cultural-core.sql"
    echo "    --highway               Process only transportation.sql"
    echo "    --railway               Process only transportation-railway.sql"
    echo "    --aero                  Process only infrastructure.sql"
    echo ""
    echo "  Physical schemas (use with --process-physical):"
    echo "    --all                   Process all physical schemas (default)"
    echo "    --physical              Process only physical-core.sql"
    echo "    --landcover             Process only landcover.sql"
    echo "    --water                 Process only water-features.sql"
    echo "    --contour               Process only terrain.sql"
    echo ""
    echo "Configuration:"
    echo "  Preferred: edit config/rbt.conf (DATABASE_HOST, DATABASE_USER, DATABASE_PASSWORD)"
    echo "  Overrides: set PG_HOST / PG_USR / PG_PASS environment variables if needed"
    echo ""
    echo "Examples:"
    echo "  $0                                           # Run complete initialization"
    echo "  $0 --all                                     # Same as above"
    echo "  $0 --import-osm-data                         # Import OSM data (all processes)"
    echo "  $0 --import-osm-data --download-planet       # Only download planet file"
    echo "  $0 --import-osm-data --download-diffs 713 730 # Download specific diff range"
    echo "  $0 --import-reference-data                   # Import reference data only"
    echo "  $0 --process-schemas                         # Process all schemas"
    echo "  $0 --process-cultural --highway              # Process highway schemas only"
    echo "  $0 --process-physical --water                # Process water schemas only"
}

# =============================================================================
# Individual Processing Functions
# =============================================================================

run_setup_database() {
    log "STEP" "Setting up database and extensions only..."
    validate_environment
    validate_dependencies
    setup_database
    log "INFO" "✅ Database setup completed successfully!"
}

run_import_osm_data() {
    local osm_args=("$@")
    
    log "STEP" "Running OSM data import with arguments: ${osm_args[*]:-"--all"}"
    validate_environment
    validate_dependencies
    
    # If no arguments provided, default to --all
    if [[ ${#osm_args[@]} -eq 0 ]]; then
        osm_args=("--all")
    fi
    
    # Set environment for OSM import
    set_database_env
    
    cd "${PROJECT_ROOT}/setup/data-sources/osm"
    if ! ./import-osm-data.sh "${osm_args[@]}"; then
        log "ERROR" "OSM data import failed"
        exit 1
    fi
    
    log "INFO" "✅ OSM data import completed successfully!"
}

run_import_reference_data() {
    log "STEP" "Running reference data import..."
    validate_environment
    validate_dependencies
    
    # Set environment for reference data import
    set_database_env
    
    cd "${PROJECT_ROOT}/setup/data-sources/reference-data"
    
    # Import base reference data
    if ! ./import-reference-data.sh; then
        log "ERROR" "Reference data import failed"
        exit 1
    fi
    
    log "INFO" "✅ Reference data import completed successfully!"
}

run_import_geonames() {
    log "STEP" "Running GeoNames data import..."
    validate_environment
    validate_dependencies
    
    # Set environment for GeoNames import
    set_database_env
    
    cd "${PROJECT_ROOT}/setup/data-sources/reference-data"
    
    # Import GeoNames data
    if ! ./import-geonames.sh; then
        log "ERROR" "GeoNames import failed"
        exit 1
    fi
    
    log "INFO" "✅ GeoNames data import completed successfully!"
}

run_import_buildings() {
    log "STEP" "Running Overture buildings data import..."
    validate_environment
    validate_dependencies
    
    # Set environment for buildings import
    set_database_env
    
    cd "${PROJECT_ROOT}/setup/data-sources/reference-data"
    
    # Import building data
    if ! ./import-buildings.sh; then
        log "ERROR" "Buildings import failed"
        exit 1
    fi
    
    log "INFO" "✅ Overture buildings import completed successfully!"
}

run_process_schemas() {
    local schema_args=("$@")
    
    log "STEP" "Running schema processing with arguments: ${schema_args[*]:-"--all"}"
    validate_environment
    validate_dependencies
    
    # If no arguments provided, default to processing both cultural and physical
    if [[ ${#schema_args[@]} -eq 0 ]]; then
        schema_args=("--all")
    fi
    
    # Set database environment variables that the schema scripts expect
    set_database_env
    
    # Process physical schemas using wrapper script
    log "INFO" "Processing physical feature schemas..."
    cd "${PROJECT_ROOT}/setup/data-sources/schemas/physical"
    if ! ./process-physical-schemas.sh "${schema_args[@]}"; then
        log "ERROR" "Physical schema processing failed"
        exit 1
    fi
    
    # Process cultural schemas using wrapper script  
    log "INFO" "Processing cultural feature schemas..."
    cd "${PROJECT_ROOT}/setup/data-sources/schemas/cultural"
    if ! ./process-cultural-schemas.sh "${schema_args[@]}"; then
        log "ERROR" "Cultural schema processing failed"
        exit 1
    fi
    
    log "INFO" "✅ Schema processing completed successfully!"
}

run_process_cultural() {
    local cultural_args=("$@")
    
    log "STEP" "Running cultural schema processing with arguments: ${cultural_args[*]:-"--all"}"
    validate_environment
    validate_dependencies
    
    # If no arguments provided, default to --all
    if [[ ${#cultural_args[@]} -eq 0 ]]; then
        cultural_args=("--all")
    fi
    
    # Set database environment variables
    set_database_env
    
    cd "${PROJECT_ROOT}/setup/data-sources/schemas/cultural"
    if ! ./process-cultural-schemas.sh "${cultural_args[@]}"; then
        log "ERROR" "Cultural schema processing failed"
        exit 1
    fi
    
    log "INFO" "✅ Cultural schema processing completed successfully!"
}

run_process_physical() {
    local physical_args=("$@")
    
    log "STEP" "Running physical schema processing with arguments: ${physical_args[*]:-"--all"}"
    validate_environment
    validate_dependencies
    
    # If no arguments provided, default to --all
    if [[ ${#physical_args[@]} -eq 0 ]]; then
        physical_args=("--all")
    fi
    
    # Set database environment variables
    set_database_env
    
    cd "${PROJECT_ROOT}/setup/data-sources/schemas/physical"
    if ! ./process-physical-schemas.sh "${physical_args[@]}"; then
        log "ERROR" "Physical schema processing failed"
        exit 1
    fi
    
    log "INFO" "✅ Physical schema processing completed successfully!"
}

# =============================================================================
# Complete Initialization (Original main function)
# =============================================================================

run_all() {
    log "INFO" "🚀 Starting RBT Vector Tiles Database Initialization"
    log "INFO" "This is a one-time setup process that may take several hours"
    log "INFO" "Log file: ${LOG_FILE}"
    
    # Validation
    validate_environment
    validate_dependencies
    
    # Database setup
    setup_database
    
    # Data import (the heavy lifting)
    show_progress 1 4 "Database setup completed"
    import_osm_data
    show_progress 2 4 "OSM data imported"
    import_reference_data
    show_progress 3 4 "Reference data imported"
    process_schemas
    show_progress 4 4 "Schema processing completed"
    
    # Final summary
    local end_time=$(date +%s)
    local total_duration=$((end_time - START_TIME))
    local hours=$((total_duration / 3600))
    local minutes=$(((total_duration % 3600) / 60))
    
    log "INFO" "✅ Database initialization completed successfully!"
    log "INFO" "Total time: ${hours}h ${minutes}m"
    log "INFO" "Next steps:"
    log "INFO" "  1. Start OSM updates: ./production/update-osm.sh"
    log "INFO" "  2. Generate tiles: ./production/generate-tiles.sh --all"
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
    # If no arguments provided, run complete initialization for backward compatibility
    if [[ $# -eq 0 ]]; then
        run_all
        return 0
    fi
    
    # Parse command line arguments
    case "$1" in
        --help|-h)
            show_usage
            exit 0
            ;;
        --all)
            run_all
            ;;
        --setup-database)
            run_setup_database
            ;;
        --import-osm-data)
            shift  # Remove the main option
            run_import_osm_data "$@"  # Pass remaining arguments to OSM import
            ;;
        --import-reference-data)
            run_import_reference_data
            ;;
        --import-geonames)
            run_import_geonames
            ;;
        --import-buildings)
            run_import_buildings
            ;;
        --process-schemas)
            shift  # Remove the main option
            run_process_schemas "$@"  # Pass remaining arguments to schema processing
            ;;
        --process-cultural)
            shift  # Remove the main option
            run_process_cultural "$@"  # Pass remaining arguments to cultural processing
            ;;
        --process-physical)
            shift  # Remove the main option
            run_process_physical "$@"  # Pass remaining arguments to physical processing
            ;;
        *)
            echo "Error: Unknown option '$1'" >&2
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

# Execute main function
main "$@"
