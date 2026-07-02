#!/bin/bash
set -euo pipefail

# =============================================================================
# CONTRACT — bash leaf script, invoked via `rbt import reference` / `rbt setup`
# =============================================================================
# Inputs:  FieldMaps, Natural Earth, OurAirports, OSM water/coastline, and
#          MIRTA downloads; env DATABASE_*/PG_* (provided by the rbt CLI).
# Outputs: fieldmap/naturalearth/ourairports/mirta (and related) schemas in
#          the target database; logs under $SHARED_LOG_DIR.
# Exit:    0 on success, non-zero on any failed stage. Do not invoke directly
#          — only through the rbt CLI, which resolves and exports the
#          environment this script expects.
# =============================================================================

# =============================================================================
# OPTIMIZED FRESH DATABASE SETUP SCRIPT FOR CI/CD PIPELINES - NO GEONAMES
# =============================================================================
#
# This script handles all data ingestion EXCEPT GeoNames data, which has been
# extracted to a separate setup_geonames.sh script. It features:
# - Parallel processing of independent data ingestion operations
# - FieldMaps administrative boundaries and labels
# - Natural Earth, OurAirports, OSM Ocean, Coastline, Antarctica, and MIRTA data
# - Structured logging with timestamps and progress tracking
# - Comprehensive error handling with cleanup and retry mechanisms
# - CI/CD specific features like health checks and resource management
# - Container-friendly signal handling and non-interactive operations
# - Optional full parallel ingestion mode (set PARALLEL_INGESTION=true)
#
# NOTE: For GeoNames data ingestion, run setup_geonames.sh separately
#
# DEBUGGING AND VERBOSITY OPTIONS:
# - Set DEBUG=true for maximum verbosity and error details
# - Set VERBOSE=true for progress indicators and additional logging
# - Set CLEAN_TEMP_FILES=false to preserve temp files for inspection
# 
# Example usage with enhanced logging:
#   DEBUG=true VERBOSE=true ./setup_fresh_database.sh
#   PARALLEL_INGESTION=true DEBUG=true ./setup_fresh_database.sh
#
# =============================================================================

# Global configuration
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# Single source of truth for config/rbt.conf loading + DATABASE_*/PG_*
# resolution (see scripts/lib/README.md).
source "${PROJECT_ROOT}/scripts/lib/config.sh"
rbt_config_load

# Configuration with fallbacks
readonly LOG_DIR="${SHARED_LOG_DIR:-${SCRIPT_DIR}/logs}"
readonly TEMP_DIR="${SHARED_TEMP_DIR:-${SCRIPT_DIR}/temp}"
readonly LOG_FILE="${LOG_DIR}/database_setup_$(date +%Y%m%d_%H%M%S).log"
readonly MAX_PARALLEL_JOBS="${SCRIPT_MAX_PARALLEL_JOBS:-4}"
readonly RETRY_COUNT="${SCRIPT_RETRY_COUNT:-3}"
readonly RETRY_DELAY="${SCRIPT_RETRY_DELAY:-30}"
readonly CONNECTION_TIMEOUT="${SCRIPT_CONNECTION_TIMEOUT:-300}"
readonly PARALLEL_INGESTION="${SCRIPT_PARALLEL_INGESTION:-false}"
readonly DEBUG="${SCRIPT_DEBUG:-false}"
readonly VERBOSE="${SCRIPT_VERBOSE:-false}"
readonly CLEAN_TEMP_FILES="${SCRIPT_CLEAN_TEMP_FILES:-false}"

# Database connection (built once)
readonly DB_CONNECTION="host=${DATABASE_HOST} port=${DATABASE_PORT} dbname=${DATABASE_NAME} user=${DATABASE_USER} password=${DATABASE_PASSWORD}"

# Check if output is to terminal for color support
source "${PROJECT_ROOT}/scripts/lib/logging.sh"
export RBT_FORCE_COLOR=1

# Job tracking arrays (global declaration)
declare -g -a RUNNING_JOBS=()
declare -g -a FAILED_JOBS=()
declare -g -a COMPLETED_JOBS=()

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

# Logging functions with structured format (fixed to avoid duplicate tee)
log_info() {
    rbt_log "INFO" "$@"
}

log_success() {
    rbt_log "SUCCESS" "$@"
}

log_warning() {
    rbt_log "WARN" "$@"
}

log_error() {
    rbt_log "ERROR" "$@"
}

log_progress() {
    rbt_log "STEP" "$@"
}

log_job() {
    rbt_log "JOB" "$@"
}

log_debug() {
    if [[ "$DEBUG" == "true" || "$VERBOSE" == "true" ]]; then
        rbt_log "DEBUG" "$@"
    fi
}

# Display last few lines of a job log when it fails
show_job_error() {
    local job_name="$1"
    local job_log="${TEMP_DIR}/${job_name}.log"
    
    if [[ -f "$job_log" ]]; then
        log_error "[$job_name] Last 10 lines of job output:"
        echo -e "${RBT_COLOR_RED}--- BEGIN JOB LOG EXCERPT ---${RBT_COLOR_RESET}"
        tail -n 10 "$job_log"
        echo -e "${RBT_COLOR_RED}--- END JOB LOG EXCERPT ---${RBT_COLOR_RESET}"
        
        if [[ "$DEBUG" == "true" ]]; then
            log_debug "[$job_name] Full job log available at: $job_log"
        fi
    else
        log_error "[$job_name] Job log file not found: $job_log"
    fi
}

show_progress() {
    rbt_log_progress "$@"
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
    
    local required_vars=("DATABASE_HOST" "DATABASE_USER" "DATABASE_NAME")
    local missing_vars=()
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required configuration values: ${missing_vars[*]}"
        log_error "Update config/rbt.conf or provide overrides via environment variables."
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
    
    if timeout "$CONNECTION_TIMEOUT" psql "$DB_CONNECTION" -c "SELECT version();" >/dev/null 2>&1; then
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
    
    local required_tools=("ogr2ogr" "wget" "7z" "aws" "unzip" "psql" "timeout")
    local missing_tools=()
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi
    
    # Check GDAL version
    local gdal_version
    gdal_version=$(ogr2ogr --version 2>&1 | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
    log_info "GDAL version: $gdal_version"
    
    log_success "All dependencies satisfied"
}

# Create required database extensions
create_database_extensions() {
    log_info "Creating required database extensions..."
    
    local extensions=("postgis" "postgis_raster" "hstore" "pg_trgm")
    local created_extensions=()
    local failed_extensions=()
    
    for extension in "${extensions[@]}"; do
        log_info "Checking extension: ${extension}"
        
        # Check if extension already exists
        local result
        result=$(psql "$DB_CONNECTION" -t -A -c "SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname = '${extension}');" 2>&1)
        
        # Check if the query succeeded
        if [[ $? -ne 0 ]]; then
            log_error "Failed to check extension ${extension}: $result"
            failed_extensions+=("$extension")
            continue
        fi
        
        # Trim whitespace and check result
        result=$(echo "$result" | tr -d '[:space:]')
        
        if [[ "$result" == "t" ]]; then
            log_info "Extension '${extension}' already exists"
        else
            log_info "Creating extension: ${extension}"
            if execute_sql "CREATE EXTENSION IF NOT EXISTS ${extension};" "Create extension: ${extension}"; then
                created_extensions+=("$extension")
                log_success "Extension '${extension}' created successfully"
            else
                failed_extensions+=("$extension")
                log_error "Failed to create extension: ${extension}"
            fi
        fi
    done
    
    # Report results
    if [[ ${#created_extensions[@]} -gt 0 ]]; then
        log_success "Created extensions: ${created_extensions[*]}"
    fi
    
    if [[ ${#failed_extensions[@]} -gt 0 ]]; then
        log_error "Failed to create extensions: ${failed_extensions[*]}"
        log_error "Some spatial operations may not work properly"
        return 1
    fi
    
    log_success "All required database extensions are available"
    return 0
}

# =============================================================================
# JOB MANAGEMENT AND PARALLEL EXECUTION
# =============================================================================

# Job wrapper with error handling and retry logic
run_job() {
    local job_name="$1"
    local job_function="$2"
    shift 2
    local job_args=("$@")
    
    local job_log="${TEMP_DIR}/${job_name}.log"
    local job_error_log="${TEMP_DIR}/${job_name}.error"
    local job_pid_file="${TEMP_DIR}/${job_name}.pid"
    local retry_count=0
    
    log_job "Starting job: $job_name"
    log_debug "[$job_name] Job log: $job_log"
    
    while [[ $retry_count -lt $RETRY_COUNT ]]; do
        {
            echo $$ > "$job_pid_file"
            echo "=== ATTEMPT $((retry_count + 1)) AT $(date) ===" >> "$job_log"
            log_job "[$job_name] Attempt $((retry_count + 1))/$RETRY_COUNT"
            
            # Redirect stderr to both the job log and a separate error log
            if "$job_function" "${job_args[@]}" 2> >(tee -a "$job_error_log" >&2); then
                log_job "[$job_name] Completed successfully"
                echo "SUCCESS" > "${TEMP_DIR}/${job_name}.status"
                rm -f "$job_pid_file"
                exit 0
            else
                local exit_code=$?
                log_warning "[$job_name] Attempt $((retry_count + 1)) failed with exit code $exit_code"
                
                # Show error details immediately if in debug mode
                if [[ "$DEBUG" == "true" && -f "$job_error_log" && -s "$job_error_log" ]]; then
                    echo -e "${RED}[$job_name] Error output:${NC}" >> "$job_log"
                    tail -n 20 "$job_error_log" >> "$job_log"
                fi
                
                if [[ $retry_count -lt $((RETRY_COUNT - 1)) ]]; then
                    log_info "[$job_name] Retrying in ${RETRY_DELAY} seconds..."
                    echo "--- RETRY DELAY ---" >> "$job_log"
                    sleep "$RETRY_DELAY"
                fi
                
                ((retry_count++))
            fi
        } >> "$job_log" 2>&1
    done
    
    log_error "[$job_name] Failed after $RETRY_COUNT attempts"
    echo "FAILED" > "${TEMP_DIR}/${job_name}.status"
    echo "=== FINAL FAILURE AT $(date) ===" >> "$job_log"
    rm -f "$job_pid_file"
    exit 1
}

# Start a background job
start_job() {
    local job_name="$1"
    local job_function="$2"
    shift 2
    local job_args=("$@")
    
    # Wait if we've reached max parallel jobs
    while [[ ${#RUNNING_JOBS[@]} -ge $MAX_PARALLEL_JOBS ]]; do
        check_running_jobs
        sleep 1
    done
    
    run_job "$job_name" "$job_function" "${job_args[@]}" &
    local job_pid=$!
    
    RUNNING_JOBS+=("$job_name:$job_pid")
    log_info "Started background job: $job_name (PID: $job_pid)"
}

# Check status of running jobs
check_running_jobs() {
    local new_running_jobs=()
    
    for job_entry in "${RUNNING_JOBS[@]}"; do
        local job_name="${job_entry%:*}"
        local job_pid="${job_entry#*:}"
        
        if kill -0 "$job_pid" 2>/dev/null; then
            new_running_jobs+=("$job_entry")
        else
            wait "$job_pid"
            local exit_code=$?
            
            if [[ $exit_code -eq 0 ]]; then
                COMPLETED_JOBS+=("$job_name")
                log_success "Job completed: $job_name"
            else
                FAILED_JOBS+=("$job_name")
                log_error "Job failed: $job_name (exit code: $exit_code)"
                
                # Show error details for failed jobs
                show_job_error "$job_name"
            fi
        fi
    done
    
    # Safely update the array
    RUNNING_JOBS=()
    if [[ ${#new_running_jobs[@]} -gt 0 ]]; then
        RUNNING_JOBS=("${new_running_jobs[@]}")
    fi
}

# Wait for all jobs to complete
wait_for_all_jobs() {
    local continue_on_failure="${1:-true}"  # Default to continuing on failure
    
    log_info "Waiting for all background jobs to complete..."
    
    while [[ ${#RUNNING_JOBS[@]} -gt 0 ]]; do
        check_running_jobs
        
        if [[ ${#RUNNING_JOBS[@]} -gt 0 ]]; then
            show_progress $((${#COMPLETED_JOBS[@]} + ${#FAILED_JOBS[@]})) \
                         $((${#COMPLETED_JOBS[@]} + ${#FAILED_JOBS[@]} + ${#RUNNING_JOBS[@]})) \
                         "Jobs progress"
            sleep 2
        fi
    done
    
    # Final status report
    log_info "Job completion summary:"
    log_success "Completed jobs: ${#COMPLETED_JOBS[@]}"
    
    if [[ ${#FAILED_JOBS[@]} -gt 0 ]]; then
        log_warning "Failed jobs: ${#FAILED_JOBS[@]} - ${FAILED_JOBS[*]}"
        
        if [[ "$continue_on_failure" == "false" ]]; then
            log_error "Stopping execution due to job failures"
            return 1
        else
            log_info "Continuing execution despite job failures"
        fi
    fi
    
    if [[ ${#COMPLETED_JOBS[@]} -gt 0 ]]; then
        log_success "Jobs completed successfully: ${#COMPLETED_JOBS[@]}"
    fi
    
    return 0
}

# Launch dataset jobs based on manifest groups (fieldmaps, independent, all)
launch_dataset_jobs() {
    local target_group="${1:-all}"
    for dataset_entry in "${DATASET_MANIFEST[@]}"; do
        IFS=':' read -r dataset_name dataset_function dataset_group <<< "${dataset_entry}"
        if [[ "${target_group}" != "all" && "${dataset_group}" != "${target_group}" ]]; then
            continue
        fi
        start_job "${dataset_name}" "${dataset_function}"
    done
}

# =============================================================================
# DATABASE HELPER FUNCTIONS
# =============================================================================

# Create required database schemas
create_database_schemas() {
    log_info "Creating required database schemas..."
    
    local schemas=("fieldmap" "mirta" "naturalearth" "ourairports" "rbt")
    
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
    echo "PG:host=${DATABASE_HOST} port=${DATABASE_PORT} dbname=${DATABASE_NAME} password=${DATABASE_PASSWORD} active_schema=${schema} user=${DATABASE_USER}"
}

# Execute SQL command with error handling (fixed for safety)
execute_sql() {
    local sql_command="$1"
    local description="${2:-SQL command}"
    
    log_info "Executing: $description"
    
    if psql "$DB_CONNECTION" -c "$sql_command" >/dev/null 2>&1; then
        log_success "$description completed"
        return 0
    else
        log_error "$description failed"
        return 1
    fi
}

# Check if a table exists in the database (SQL injection safe)
table_exists() {
    local schema="$1"
    local table="$2"
    
    log_debug "Checking if table ${schema}.${table} exists"
    
    # Use shell variable substitution with proper SQL escaping
    local result
    result=$(psql "$DB_CONNECTION" -t -A -c "
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
# GENERIC DATA INGESTION FUNCTIONS (DRY Principle)
# =============================================================================



# Generic FieldMaps ingestion function
ingest_fieldmaps_generic() {
    local layer_name="$1"
    local table_name="$2"
    local geometry_type="$3"
    local url="$4"
    
    log_info "Ingesting FieldMaps ${layer_name}..."
    
    # Check if table already exists
    if table_exists "fieldmap" "$table_name"; then
        return 0
    fi
    
    ogr2ogr -progress \
        --config PG_USE_COPY YES \
        -f PostgreSQL \
        --config GDAL_DISABLE_READDIR_ON_OPEN EMPTY_DIR \
        --config CPL_VSIL_CURL_ALLOWED_EXTENSIONS .parquet \
        --config GDAL_HTTP_TIMEOUT 300 \
        --config GDAL_HTTP_CONNECTTIMEOUT 60 \
        --config VSI_CACHE TRUE \
        --config VSI_CACHE_SIZE 2500000000 \
        "$(build_pg_connection fieldmap)" \
        -lco DIM=2 \
        -nlt "$geometry_type" \
        -lco GEOMETRY_NAME=geometry \
        -lco UNLOGGED=ON \
        -nln "fieldmap.${table_name}" \
        -skipfailures \
        "/vsicurl/${url}"
}

# Wrapper functions for FieldMaps data
ingest_fieldmaps_adm0() {
    ingest_fieldmaps_generic "ADM0 polygons" "adm0" "MULTIPOLYGON" \
        "https://data.fieldmaps.io/adm0/osm/all/adm0_polygons.parquet"
}

ingest_fieldmaps_adm1() {
    ingest_fieldmaps_generic "ADM1 polygons" "adm1" "MULTIPOLYGON" \
        "https://data.fieldmaps.io/edge-matched/humanitarian/intl/adm1_polygons.parquet"
}

ingest_fieldmaps_adm2() {
    ingest_fieldmaps_generic "ADM2 polygons" "adm2" "MULTIPOLYGON" \
        "https://data.fieldmaps.io/edge-matched/humanitarian/intl/adm2_polygons.parquet"
}

ingest_fieldmaps_adm0_lines() {
    ingest_fieldmaps_generic "ADM0 lines" "adm0_lines" "MULTILINESTRING" \
        "https://data.fieldmaps.io/adm0/osm/all/adm0_lines.parquet"
}

ingest_fieldmaps_adm1_lines() {
    ingest_fieldmaps_generic "ADM1 lines" "adm1_lines" "MULTILINESTRING" \
        "https://data.fieldmaps.io/edge-matched/humanitarian/intl/adm1_lines.parquet"
}

ingest_fieldmaps_adm2_lines() {
    ingest_fieldmaps_generic "ADM2 lines" "adm2_lines" "MULTILINESTRING" \
        "https://data.fieldmaps.io/edge-matched/humanitarian/intl/adm2_lines.parquet"
}

ingest_fieldmaps_adm0_labels() {
    ingest_fieldmaps_generic "ADM0 labels" "adm0_labels" "POINT" \
        "https://data.fieldmaps.io/adm0/osm/all/adm0_points.parquet"
}

ingest_fieldmaps_adm1_labels() {
    ingest_fieldmaps_generic "ADM1 labels" "adm1_labels" "POINT" \
        "https://data.fieldmaps.io/edge-matched/humanitarian/intl/adm1_points.parquet"
}

ingest_fieldmaps_adm2_labels() {
    ingest_fieldmaps_generic "ADM2 labels" "adm2_labels" "POINT" \
        "https://data.fieldmaps.io/edge-matched/humanitarian/intl/adm2_points.parquet"
}

# Create USA subset from FieldMaps data
create_usa_subset() {
    log_info "Creating USA subset from FieldMaps data..."
    
    # Check if table already exists
    if table_exists "fieldmap" "usa"; then
        return 0
    fi
    
    # Create the USA subset table
    if execute_sql "CREATE TABLE fieldmap.usa AS SELECT adm0_id, 'USA' AS gid_0, (ST_Dump(ST_SimplifyPreserveTopology(ST_MakeValid(geometry, 'method=structure'),0.00001))).geom::geometry(Polygon,4326) AS geometry FROM fieldmap.adm0 WHERE iso_3 IN ('GUM', 'PRI', 'MNP', 'ASM', 'UMI', 'VIR', 'USA');" \
                    "USA subset creation"; then
        
        log_info "Creating GIST geometry index on fieldmap.usa table..."
        if execute_sql "CREATE INDEX idx_fieldmap_usa_geometry_gist ON fieldmap.usa USING GIST (geometry);" \
                        "GIST geometry index creation"; then
            
            log_info "Clustering fieldmap.usa table on geometry index..."
            if execute_sql "CLUSTER fieldmap.usa USING idx_fieldmap_usa_geometry_gist;" \
                            "Table clustering on geometry index"; then
                
                log_info "Running VACUUM FULL ANALYZE on fieldmap.usa table..."
                execute_sql "VACUUM FULL ANALYZE fieldmap.usa;" \
                            "VACUUM FULL ANALYZE fieldmap.usa"
            else
                log_warning "Failed to cluster fieldmap.usa table, continuing without clustering"
            fi
        else
            log_warning "Failed to create GIST index on fieldmap.usa table, continuing without index"
        fi
    else
        log_error "Failed to create USA subset table"
        return 1
    fi
}

# OurAirports data ingestion
ingest_ourairports_airports() {
    log_info "Ingesting OurAirports airports..."
    
    # Check if table already exists
    if table_exists "ourairports" "airport"; then
        return 0
    fi
    
    ogr2ogr -progress \
        -f "PostgreSQL" \
        --config PG_USE_COPY YES \
        "PG:dbname=${DATABASE_NAME} host=${DATABASE_HOST} port=${DATABASE_PORT} user=${DATABASE_USER} password=${DATABASE_PASSWORD}" \
        -a_srs EPSG:4326 \
        -nln ourairports.airport \
        -lco GEOMETRY_NAME=geometry \
        -nlt POINT \
        -lco PRECISION=NO \
        -lco DIM=2 \
        -lco UNLOGGED=ON \
        -oo AUTODETECT_TYPE=YES \
        -oo QUOTED_FIELDS_AS_STRING=YES \
        -oo X_POSSIBLE_NAMES=longitude_deg \
        -oo Y_POSSIBLE_NAMES=latitude_deg \
        -oo EMPTY_STRING_AS_NULL=YES \
        -skipfailures \
        "/vsicurl/https://raw.githubusercontent.com/davidmegginson/ourairports-data/refs/heads/main/airports.csv"
}

ingest_ourairports_runways() {
    log_info "Ingesting OurAirports runways..."
    
    # Check if table already exists
    if table_exists "ourairports" "runway"; then
        return 0
    fi
    
    ogr2ogr -progress \
        -f "PostgreSQL" \
        --config PG_USE_COPY YES \
        "PG:dbname=${DATABASE_NAME} host=${DATABASE_HOST} port=${DATABASE_PORT} user=${DATABASE_USER} password=${DATABASE_PASSWORD}" \
         -a_srs EPSG:4326 \
        -nln ourairports.runway \
        -lco GEOMETRY_NAME=geometry \
        -lco PRECISION=NO \
        -lco DIM=2 \
        -lco UNLOGGED=ON \
        -oo AUTODETECT_TYPE=YES \
        -oo QUOTED_FIELDS_AS_STRING=YES \
        -oo EMPTY_STRING_AS_NULL=YES \
        -oo X_POSSIBLE_NAMES=le_longitude_deg \
        -oo Y_POSSIBLE_NAMES=le_latitude_deg \
        -skipfailures \
        "/vsicurl/https://raw.githubusercontent.com/davidmegginson/ourairports-data/refs/heads/main/runways.csv"
}

# Natural Earth data ingestion
ingest_naturalearth_data() {
    log_info "Ingesting Natural Earth data..."
    
    # Check if Natural Earth data already exists (check for one of the main tables)
    if table_exists "naturalearth" "ne_10m_admin_0_countries"; then
        log_info "Natural Earth data already exists, skipping ingestion"
        return 0
    fi
    
    ogr2ogr -progress \
        --config PG_USE_COPY YES \
        -f PostgreSQL \
        -lco SCHEMA=naturalearth \
        -overwrite \
        -skipfailures \
        "$(build_pg_connection naturalearth)" \
        -lco DIM=2 \
        -lco GEOMETRY_NAME=geometry \
        -lco UNLOGGED=ON \
        -nlt PROMOTE_TO_MULTI \
        "/vsizip//vsicurl/https://naciscdn.org/naturalearth/packages/natural_earth_vector.gpkg.zip/packages/natural_earth_vector.gpkg"
}

# OSM Ocean data ingestion
ingest_osm_ocean() {
    log_info "Ingesting OSM Ocean data..."
    
    # Check if table already exists
    if table_exists "rbt" "osm_ocean"; then
        return 0
    fi
    
    ogr2ogr -progress \
        --config PG_USE_COPY YES \
        -f PostgreSQL \
        -t_srs EPSG:4326 \
        -overwrite \
        -skipfailures \
        "$(build_pg_connection rbt)" \
        -lco DIM=2 \
        -lco GEOMETRY_NAME=geometry \
        -lco UNLOGGED=ON \
        -nln rbt.osm_ocean \
        -nlt PROMOTE_TO_MULTI \
        "/vsizip//vsicurl/https://osmdata.openstreetmap.de/download/water-polygons-split-4326.zip/water-polygons-split-4326/water_polygons.shp"
}

ingest_osm_ocean_simplified() {
    log_info "Ingesting OSM Ocean simplified data..."
    
    # Check if table already exists
    if table_exists "rbt" "osm_ocean_simplified"; then
        return 0
    fi
    
    ogr2ogr -progress \
        --config PG_USE_COPY YES \
        -f PostgreSQL \
        -t_srs EPSG:4326 \
        -overwrite \
        -skipfailures \
        "$(build_pg_connection rbt)" \
        -lco DIM=2 \
        -lco GEOMETRY_NAME=geometry \
        -lco UNLOGGED=ON \
        -nln rbt.osm_ocean_simplified \
        -nlt PROMOTE_TO_MULTI \
        "/vsizip//vsicurl/https://osmdata.openstreetmap.de/download/simplified-water-polygons-split-3857.zip/simplified-water-polygons-split-3857/simplified_water_polygons.shp"
}

# OSM Antarctica data ingestion
ingest_osm_antarctica() {
    log_info "Ingesting OSM Antarctica glaciers..."
    
    # Check if table already exists
    if table_exists "rbt" "osm_antarctica_icesheet"; then
        return 0
    fi
    
    ogr2ogr -progress \
        --config PG_USE_COPY YES \
        -f PostgreSQL \
        -t_srs EPSG:4326 \
        -overwrite \
        -skipfailures \
        "$(build_pg_connection rbt)" \
        -lco DIM=2 \
        -lco GEOMETRY_NAME=geometry \
        -lco UNLOGGED=ON \
        -nln rbt.osm_antarctica_icesheet \
        -nlt PROMOTE_TO_MULTI \
        "/vsizip//vsicurl/https://osmdata.openstreetmap.de/download/antarctica-icesheet-polygons-3857.zip/antarctica-icesheet-polygons-3857/icesheet_polygons.shp"
}

# OSM Coastline data ingestion
ingest_osm_coastline() {
    log_info "Ingesting OSM Coastline data..."
    
    # Check if table already exists
    if table_exists "rbt" "coastline"; then
        return 0
    fi
    
    ogr2ogr -progress \
        --config PG_USE_COPY YES \
        -f PostgreSQL \
        -overwrite \
        -skipfailures \
        "$(build_pg_connection rbt)" \
        -lco DIM=2 \
        -lco GEOMETRY_NAME=geometry \
        -lco UNLOGGED=ON \
        -nln rbt.coastline \
        -nlt MULTILINESTRING \
        "/vsizip//vsicurl/https://osmdata.openstreetmap.de/download/coastlines-split-4326.zip/coastlines-split-4326/lines.shp"
}

# MIRTA data ingestion
ingest_mirta_data() {
    log_info "Ingesting MIRTA data..."
    
    # Check if table already exists
    if table_exists "mirta" "us_military_installations"; then
        return 0
    fi
    
    safe_cd "$TEMP_DIR" || return 1
    
    if [[ ! -f "FY23_MIRTA_Final.gdb" ]]; then
        wget https://www.acq.osd.mil/eie/imr/rpid/disdi/Downloads/installations_ranges.zip --no-check-certificate
        unzip -o installations_ranges.zip
    fi
    
    ogr2ogr -progress --config PG_USE_COPY YES \
        -f PostgreSQL \
        "$(build_pg_connection mirta)" \
        -lco DIM=2 \
        -lco UNLOGGED=ON \
        FY23_MIRTA_Final.gdb MirtaLocations_A \
        -overwrite \
        -nlt GEOMETRY \
        -lco GEOMETRY_NAME=geometry \
        -nln mirta.us_military_installations \
        -skipfailures
}

# Dataset manifest for orchestration (dataset_name:function:group)
declare -a DATASET_MANIFEST=(
    "fieldmaps_adm0:ingest_fieldmaps_adm0:fieldmaps"
    "fieldmaps_adm1:ingest_fieldmaps_adm1:fieldmaps"
    "fieldmaps_adm2:ingest_fieldmaps_adm2:fieldmaps"
    "fieldmaps_adm0_lines:ingest_fieldmaps_adm0_lines:fieldmaps"
    "fieldmaps_adm1_lines:ingest_fieldmaps_adm1_lines:fieldmaps"
    "fieldmaps_adm2_lines:ingest_fieldmaps_adm2_lines:fieldmaps"
    "fieldmaps_adm0_labels:ingest_fieldmaps_adm0_labels:fieldmaps"
    "fieldmaps_adm1_labels:ingest_fieldmaps_adm1_labels:fieldmaps"
    "fieldmaps_adm2_labels:ingest_fieldmaps_adm2_labels:fieldmaps"
    "ourairports_airports:ingest_ourairports_airports:independent"
    "ourairports_runways:ingest_ourairports_runways:independent"
    "naturalearth_data:ingest_naturalearth_data:independent"
    "osm_ocean:ingest_osm_ocean:independent"
    "osm_ocean_simplified:ingest_osm_ocean_simplified:independent"
    "osm_coastline:ingest_osm_coastline:independent"
    "osm_antarctica:ingest_osm_antarctica:independent"
    "mirta_data:ingest_mirta_data:independent"
)

# =============================================================================
# CLEANUP AND SIGNAL HANDLING
# =============================================================================

# Cleanup function
cleanup() {
    local exit_code=$?
    
    log_info "Cleaning up..."
    
    # Kill any remaining background jobs
    for job_entry in "${RUNNING_JOBS[@]}"; do
        local job_pid="${job_entry#*:}"
        if kill -0 "$job_pid" 2>/dev/null; then
            log_warning "Terminating background job: $job_pid"
            kill -TERM "$job_pid" 2>/dev/null || true
            sleep 2
            kill -KILL "$job_pid" 2>/dev/null || true
        fi
    done
    
    # Clean up temporary files (optional, for debugging leave them)
    if [[ "${CLEAN_TEMP_FILES}" == "true" ]]; then
        log_info "Removing temporary files..."
        rm -rf "$TEMP_DIR"
    else
        log_info "Temporary files preserved in: $TEMP_DIR"
    fi
    
    # Final status report
    if [[ $exit_code -eq 0 ]]; then
        log_success "Script completed successfully!"
    else
        log_error "Script failed with exit code: $exit_code"
    fi
    
    exit $exit_code
}

# Signal handlers for graceful shutdown in containers
trap cleanup EXIT
trap 'log_warning "Received SIGTERM, initiating graceful shutdown..."; exit 143' TERM
trap 'log_warning "Received SIGINT, initiating graceful shutdown..."; exit 130' INT

# Execute all data ingestion jobs in full parallel mode
execute_parallel_ingestion() {
    log_info "=== FULL PARALLEL DATA INGESTION MODE ==="
    log_progress "Starting all data ingestion jobs in parallel..."
    
    launch_dataset_jobs "all"

    # Wait for all jobs to complete (continue even if some fail)
    wait_for_all_jobs true
    
    # Create USA subset after FieldMaps ADM0 completion
    log_info "Creating USA subset..."
    if ! create_usa_subset; then
        log_warning "USA subset creation failed, continuing with other operations"
    fi
    
    return 0
}

# =============================================================================
# MAIN EXECUTION FLOW
# =============================================================================

main() {
    local start_time
    start_time=$(date +%s)
    
    log_info "=== STARTING OPTIMIZED DATABASE SETUP (NO GEONAMES) ==="
    log_info "Script: $SCRIPT_NAME"
    log_info "Version: Optimized for CI/CD pipelines - GeoNames extracted to separate script"
    log_info "Max parallel jobs: $MAX_PARALLEL_JOBS"
    log_info "Retry count: $RETRY_COUNT"
    log_info "Connection timeout: ${CONNECTION_TIMEOUT}s"
    log_info "Parallel ingestion mode: $PARALLEL_INGESTION"
    log_info "Debug mode: $DEBUG"
    log_info "Verbose mode: $VERBOSE"
    
    # Initialize logging and validate environment
    init_logging
    validate_environment
    check_dependencies
    
    # Create required database extensions
    log_info "=== DATABASE EXTENSIONS SETUP ==="
    if ! create_database_extensions; then
        log_warning "Failed to create some database extensions, continuing with available extensions"
    fi
    
    # Create required database schemas first
    log_info "=== SCHEMA CREATION ==="
    if ! create_database_schemas; then
        log_warning "Failed to create some database schemas, continuing with available schemas"
    fi
    
    # Choose execution mode based on PARALLEL_INGESTION setting
    if [[ "$PARALLEL_INGESTION" == "true" ]]; then
        # Execute all data ingestion in full parallel mode
        if ! execute_parallel_ingestion; then
            log_warning "Some parallel data ingestion jobs failed, but continuing execution"
        fi
    else
        # Execute in sequential phases (original behavior)
        # PHASE 1: FieldMaps boundary data (parallel execution)
        log_info "=== PHASE 1: FIELDMAPS BOUNDARY DATA ==="
        log_progress "Starting FieldMaps data ingestion with parallel jobs..."
        
        launch_dataset_jobs "fieldmaps"
        
        # Wait for FieldMaps jobs to complete (continue even if some fail)
        wait_for_all_jobs true
        
        # Create USA subset (depends on ADM0 completion)
        log_info "Creating USA subset..."
        create_usa_subset
        
        # Reset job arrays for next phase
        COMPLETED_JOBS=()
        FAILED_JOBS=()
        
        # PHASE 2: Independent data sources (all can run in parallel)
        log_info "=== PHASE 2: INDEPENDENT DATA SOURCES ==="
        # Reset job arrays for independent data sources
        COMPLETED_JOBS=()
        FAILED_JOBS=()
        
        log_progress "Starting independent data source ingestion..."
        launch_dataset_jobs "independent"
        
        # Wait for all remaining jobs (continue even if some fail)
        wait_for_all_jobs true
    fi
    
    # Final summary
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))
    
    log_success "=== DATABASE SETUP COMPLETED ==="
    log_success "Total execution time: ${hours}h ${minutes}m ${seconds}s"
    log_success "Completed jobs: ${#COMPLETED_JOBS[@]}"
    
    if [[ ${#FAILED_JOBS[@]} -gt 0 ]]; then
        log_error "Database setup completed with ${#FAILED_JOBS[@]} failed job(s): ${FAILED_JOBS[*]}"
        return 1
    fi

    log_success "Database setup finished successfully!"
}

# Execute main function with all arguments
main "$@"
