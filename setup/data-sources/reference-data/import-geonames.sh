#!/bin/bash
set -euo pipefail

# =============================================================================
# GEONAMES DATA INGESTION SCRIPT - EXTRACTED FROM MAIN DATABASE SETUP
# =============================================================================
#
# This script handles all GeoNames data processing including:
# - Parallel downloading of GeoNames data files
# - Ingestion into PostgreSQL database
# - Comprehensive error handling with retry mechanisms
# - Structured logging with timestamps and progress tracking
# - CI/CD specific features like health checks and resource management
#
# DEBUGGING AND VERBOSITY OPTIONS:
# - Set DEBUG=true for maximum verbosity and error details
# - Set VERBOSE=true for progress indicators and additional logging
# - Set CLEAN_TEMP_FILES=false to preserve temp files for inspection
# 
# Example usage with enhanced logging:
#   DEBUG=true VERBOSE=true ./setup_geonames.sh
#   PARALLEL_INGESTION=true DEBUG=true ./setup_geonames.sh
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
readonly LOG_FILE="${LOG_DIR}/geonames_setup_$(date +%Y%m%d_%H%M%S).log"
readonly MAX_PARALLEL_JOBS="${SCRIPT_MAX_PARALLEL_JOBS:-4}"
readonly RETRY_COUNT="${SCRIPT_RETRY_COUNT:-3}"
readonly RETRY_DELAY="${SCRIPT_RETRY_DELAY:-30}"
readonly CONNECTION_TIMEOUT="${SCRIPT_CONNECTION_TIMEOUT:-300}"
readonly PARALLEL_INGESTION="${SCRIPT_PARALLEL_INGESTION:-false}"
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

log_job() {
    echo -e "${CYAN}[JOB]${NC} $(date '+%Y-%m-%d %H:%M:%S') [$$] $*"
}

log_debug() {
    if [[ "$DEBUG" == "true" || "$VERBOSE" == "true" ]]; then
        echo -e "${PURPLE}[DEBUG]${NC} $(date '+%Y-%m-%d %H:%M:%S') [$$] $*"
    fi
}

# Display last few lines of a job log when it fails
show_job_error() {
    local job_name="$1"
    local job_log="${TEMP_DIR}/${job_name}.log"
    
    if [[ -f "$job_log" ]]; then
        log_error "[$job_name] Last 10 lines of job output:"
        echo -e "${RED}--- BEGIN JOB LOG EXCERPT ---${NC}"
        tail -n 10 "$job_log"
        echo -e "${RED}--- END JOB LOG EXCERPT ---${NC}"
        
        if [[ "$DEBUG" == "true" ]]; then
            log_debug "[$job_name] Full job log available at: $job_log"
        fi
    else
        log_error "[$job_name] Job log file not found: $job_log"
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
    printf "%*s" $((bar_length - filled)) | tr ' ' '-'
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
    
    local required_tools=("ogr2ogr" "wget" "7z" "unzip" "psql" "timeout")
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

# =============================================================================
# DATABASE HELPER FUNCTIONS
# =============================================================================

# Execute SQL command with error handling (fixed for safety)
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

# Check if a table exists in the database (SQL injection safe)
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

# Create GeoNames database schema
create_geonames_schema() {
    log_info "Creating GeoNames database schema..."
    
    if execute_sql "CREATE SCHEMA IF NOT EXISTS geonames;" "Create GeoNames schema"; then
        log_success "GeoNames schema created successfully"
        return 0
    else
        log_error "Failed to create GeoNames schema"
        return 1
    fi
}

# =============================================================================
# GEONAMES SPECIFIC DATA PROCESSING FUNCTIONS
# =============================================================================

# Validate if a GeoNames CSV file is complete and usable
validate_geonames_file() {
    local file_path="$1"
    local file_description="${2:-file}"
    
    # Check if file exists and has size
    if [[ ! -f "$file_path" ]]; then
        log_debug "[$file_description] File does not exist: $file_path"
        return 1
    fi
    
    if [[ ! -s "$file_path" ]]; then
        log_debug "[$file_description] File exists but is empty: $file_path"
        return 1
    fi
    
    # Check line count (should have at least some data)
    local line_count
    line_count=$(wc -l < "$file_path" 2>/dev/null || echo "0")
    
    if [[ "$line_count" -eq 0 ]]; then
        log_debug "[$file_description] File appears to be empty (0 lines): $file_path"
        return 1
    fi
    
    if [[ "$line_count" -lt 10 ]]; then
        log_debug "[$file_description] File may be incomplete (only $line_count lines): $file_path"
        return 1
    fi
    
    log_debug "[$file_description] File validation passed: $line_count lines"
    return 0
}

# Generic GeoNames download function
download_geonames_file() {
    local file="$1"
    local is_zip="${2:-true}"
    
    safe_cd "$TEMP_DIR" || return 1
    
    local target_file="${file}.csv"
    
    # Check if target CSV file exists and is valid
    if validate_geonames_file "$target_file" "$file"; then
        log_info "${target_file} already exists and is valid, skipping download"
        return 0
    fi
    
    # If CSV doesn't exist but zip does, try to extract it first
    if [[ "$is_zip" == "true" ]]; then
        local zip_file="${file}.zip"
        local txt_file="${file}.txt"
        
        if [[ -f "$zip_file" && -s "$zip_file" ]]; then
            log_info "Found existing zip file: $zip_file, attempting extraction..."
            
            # Try to extract the zip file
            if 7z x -y "$zip_file" 2>&1; then
                # Check if the expected text file exists
                if [[ -f "$txt_file" && -s "$txt_file" ]]; then
                    # Convert tab-separated to CSV
                    if sed 's/\t/,/g' "$txt_file" > "$target_file" 2>/dev/null && validate_geonames_file "$target_file" "$file"; then
                        log_success "Successfully extracted and converted $zip_file to $target_file"
                        rm -f "$txt_file"
                        return 0
                    else
                        log_warning "Failed to convert or validate extracted file from $zip_file"
                        rm -f "$target_file" "$txt_file"
                    fi
                else
                    log_warning "Expected file $txt_file not found in existing zip $zip_file"
                fi
            else
                log_warning "Failed to extract existing zip file: $zip_file"
            fi
        fi
    fi
    
    if [[ "$is_zip" == "true" ]]; then
        local zip_file="${file}.zip"
        local txt_file="${file}.txt"
        
        log_info "Downloading ${file}..."
        
        if wget --timeout=600 --tries=3 --progress=dot:giga \
            "https://geonames.nga.mil/geonames/GNSData/fc_files/${zip_file}"; then
            
            # Extract all files from zip (more robust than specific file extraction)
            if 7z x -y "$zip_file" 2>&1; then
                # Check if the expected text file exists
                if [[ -f "$txt_file" && -s "$txt_file" ]]; then
                    # Convert tab-separated to CSV
                    sed 's/\t/,/g' "$txt_file" > "$target_file" 2>/dev/null || {
                        log_warning "Failed to convert $txt_file to CSV, using original format"
                        cp "$txt_file" "$target_file" 2>/dev/null || true
                    }
                    rm -f "$txt_file"
                else
                    # If the expected file doesn't exist, try to find any .txt file
                    log_warning "[$file] Expected file $txt_file not found, searching for alternatives..."
                    local found_txt
                    found_txt=$(find . -maxdepth 2 -name "*.txt" -type f ! -name "disclaimer.txt" ! -name "*Guide*.txt" | head -n1)
                    
                    if [[ -n "$found_txt" && -f "$found_txt" && -s "$found_txt" ]]; then
                        log_info "[$file] Found alternative text file: $found_txt"
                        # Convert tab-separated to CSV
                        sed 's/\t/,/g' "$found_txt" > "$target_file" 2>/dev/null || {
                            log_warning "Failed to convert $found_txt to CSV, using original format"
                            cp "$found_txt" "$target_file" 2>/dev/null || true
                        }
                        rm -f "$found_txt"
                    else
                        log_error "[$file] No suitable text file found in archive"
                        return 1
                    fi
                fi
            else
                log_error "[$file] Failed to extract from $zip_file"
                return 1
            fi
        else
            log_error "[$file] Download failed"
            return 1
        fi
    else
        # Direct CSV download
        log_info "Downloading ${file}..."
        
        if ! wget --timeout=600 --tries=3 --progress=dot:giga \
            "https://geonames.nga.mil/geonames/GNSData/gns/${target_file}"; then
            log_error "[$file] Download failed"
            return 1
        fi
    fi
    
    # Validate the file
    if [[ -f "$target_file" && -s "$target_file" ]]; then
        local line_count
        line_count=$(wc -l < "$target_file" 2>/dev/null || echo "0")
        log_debug "[$file] File has $line_count lines"
        
        if [[ "$line_count" -eq 0 ]]; then
            log_error "[$file] Downloaded file appears to be empty"
            return 1
        fi
    else
        log_error "[$file] Download failed or file is empty"
        return 1
    fi
    
    return 0
}

# Wrapper functions for GeoNames downloads
download_geonames_administrative_regions() { download_geonames_file "Administrative_Regions" true; }
download_geonames_hydrographic() { download_geonames_file "Hydrographic" true; }
download_geonames_hypsographic() { download_geonames_file "Hypsographic" true; }
download_geonames_populated_places() { download_geonames_file "Populated_Places" true; }
download_geonames_areas_localities() { download_geonames_file "Areas_Localities" true; }
download_geonames_undersea() { download_geonames_file "Undersea" true; }
download_geonames_transportation_networks() { download_geonames_file "Transportation_Networks" true; }
download_geonames_spot_features() { download_geonames_file "Spot_Features" true; }
download_geonames_vegetation() { download_geonames_file "Vegetation" true; }

# Custom download functions for USGS hosted files
download_geonames_populated_places_national() {
    local file="PopulatedPlaces_National"
    local target_file="${file}.csv"
    
    safe_cd "$TEMP_DIR" || return 1
    
    # Check if target CSV file exists and is valid
    if validate_geonames_file "$target_file" "$file"; then
        log_info "${target_file} already exists and is valid, skipping download"
        return 0
    fi
    
    local zip_file="PopulatedPlaces_National_Text.zip"
    local txt_file="Text/PopulatedPlaces_National.txt"  # Fixed path
    
    # If CSV doesn't exist but zip does, try to extract it first
    if [[ -f "$zip_file" && -s "$zip_file" ]]; then
        log_info "Found existing zip file: $zip_file, attempting extraction..."
        
        # Try to extract the zip file
        if 7z x -y "$zip_file" 2>&1; then
            # Check if the file exists in the Text subdirectory
            if [[ -f "$txt_file" && -s "$txt_file" ]]; then
                # Convert tab-separated to CSV
                if sed 's/\t/,/g' "$txt_file" > "$target_file" 2>/dev/null && validate_geonames_file "$target_file" "$file"; then
                    log_success "Successfully extracted and converted $zip_file to $target_file"
                    rm -rf Text/  # Clean up the extracted directory
                    return 0
                else
                    log_warning "Failed to convert or validate extracted file from $zip_file"
                    rm -f "$target_file"
                    rm -rf Text/
                fi
            else
                log_warning "Expected file $txt_file not found in existing zip $zip_file"
            fi
        else
            log_warning "Failed to extract existing zip file: $zip_file"
        fi
    fi
    
    log_info "Downloading ${file} from USGS..."
    
    if wget --timeout=600 --tries=3 --progress=dot:giga \
        "https://prd-tnm.s3.amazonaws.com/StagedProducts/GeographicNames/Topical/PopulatedPlaces_National_Text.zip"; then
        
        # Extract all files from zip (more robust than specific file extraction)
        if 7z x -y "$zip_file" 2>&1; then
            # Check if the file exists in the Text subdirectory
            if [[ -f "$txt_file" && -s "$txt_file" ]]; then
                # Convert tab-separated to CSV
                sed 's/\t/,/g' "$txt_file" > "$target_file" 2>/dev/null || {
                    log_warning "Failed to convert $txt_file to CSV, using original format"
                    cp "$txt_file" "$target_file" 2>/dev/null || true
                }
                rm -rf Text/  # Clean up the extracted directory
            else
                log_error "[$file] Expected file not found: $txt_file"
                return 1
            fi
        else
            log_error "[$file] Failed to extract from $zip_file"
            return 1
        fi
    else
        log_error "[$file] Download failed"
        return 1
    fi
    
    # Validate the file
    if [[ -f "$target_file" && -s "$target_file" ]]; then
        local line_count
        line_count=$(wc -l < "$target_file" 2>/dev/null || echo "0")
        log_debug "[$file] File has $line_count lines"
        
        if [[ "$line_count" -eq 0 ]]; then
            log_error "[$file] Downloaded file appears to be empty"
            return 1
        fi
    else
        log_error "[$file] Download failed or file is empty"
        return 1
    fi
    
    return 0
}

download_geonames_historical_features_national() {
    local file="HistoricalFeatures_National"
    local target_file="${file}.csv"
    
    safe_cd "$TEMP_DIR" || return 1
    
    # Check if target CSV file exists and is valid
    if validate_geonames_file "$target_file" "$file"; then
        log_info "${target_file} already exists and is valid, skipping download"
        return 0
    fi
    
    local zip_file="HistoricalFeatures_National_Text.zip"
    local txt_file="Text/HistoricalFeatures_National.txt"  # Fixed path
    
    # If CSV doesn't exist but zip does, try to extract it first
    if [[ -f "$zip_file" && -s "$zip_file" ]]; then
        log_info "Found existing zip file: $zip_file, attempting extraction..."
        
        # Try to extract the zip file
        if 7z x -y "$zip_file" 2>&1; then
            # Check if the file exists in the Text subdirectory
            if [[ -f "$txt_file" && -s "$txt_file" ]]; then
                # Convert tab-separated to CSV
                if sed 's/\t/,/g' "$txt_file" > "$target_file" 2>/dev/null && validate_geonames_file "$target_file" "$file"; then
                    log_success "Successfully extracted and converted $zip_file to $target_file"
                    rm -rf Text/  # Clean up the extracted directory
                    return 0
                else
                    log_warning "Failed to convert or validate extracted file from $zip_file"
                    rm -f "$target_file"
                    rm -rf Text/
                fi
            else
                log_warning "Expected file $txt_file not found in existing zip $zip_file"
            fi
        else
            log_warning "Failed to extract existing zip file: $zip_file"
        fi
    fi
    
    log_info "Downloading ${file} from USGS..."
    
    if wget --timeout=600 --tries=3 --progress=dot:giga \
        "https://prd-tnm.s3.amazonaws.com/StagedProducts/GeographicNames/Topical/HistoricalFeatures_National_Text.zip"; then
        
        # Extract all files from zip (more robust than specific file extraction)
        if 7z x -y "$zip_file" 2>&1; then
            # Check if the file exists in the Text subdirectory
            if [[ -f "$txt_file" && -s "$txt_file" ]]; then
                # Convert tab-separated to CSV
                sed 's/\t/,/g' "$txt_file" > "$target_file" 2>/dev/null || {
                    log_warning "Failed to convert $txt_file to CSV, using original format"
                    cp "$txt_file" "$target_file" 2>/dev/null || true
                }
                rm -rf Text/  # Clean up the extracted directory
            else
                log_error "[$file] Expected file not found: $txt_file"
                return 1
            fi
        else
            log_error "[$file] Failed to extract from $zip_file"
            return 1
        fi
    else
        log_error "[$file] Download failed"
        return 1
    fi
    
    # Validate the file
    if [[ -f "$target_file" && -s "$target_file" ]]; then
        local line_count
        line_count=$(wc -l < "$target_file" 2>/dev/null || echo "0")
        log_debug "[$file] File has $line_count lines"
        
        if [[ "$line_count" -eq 0 ]]; then
            log_error "[$file] Downloaded file appears to be empty"
            return 1
        fi
    else
        log_error "[$file] Download failed or file is empty"
        return 1
    fi
    
    return 0
}

# Parallel GeoNames data download
download_geonames_files() {
    log_info "Downloading GeoNames files in parallel..."
    
    # Ensure temp directory exists
    mkdir -p "$TEMP_DIR"
    
    # Start all GeoNames download jobs in parallel
    start_job "geonames_download_administrative_regions" download_geonames_administrative_regions
    start_job "geonames_download_hydrographic" download_geonames_hydrographic
    start_job "geonames_download_hypsographic" download_geonames_hypsographic
    start_job "geonames_download_populated_places" download_geonames_populated_places
    start_job "geonames_download_areas_localities" download_geonames_areas_localities
    start_job "geonames_download_undersea" download_geonames_undersea
    start_job "geonames_download_transportation_networks" download_geonames_transportation_networks
    start_job "geonames_download_spot_features" download_geonames_spot_features
    start_job "geonames_download_vegetation" download_geonames_vegetation
    start_job "geonames_download_populated_places_national" download_geonames_populated_places_national
    start_job "geonames_download_historical_features_national" download_geonames_historical_features_national
    
    # Wait for all download jobs to complete
    wait_for_all_jobs true
    
    if [[ ${#FAILED_JOBS[@]} -eq 0 ]]; then
        log_success "All GeoNames files downloaded successfully in parallel"
    else
        local success_count=$((11 - ${#FAILED_JOBS[@]}))
        log_warning "GeoNames download completed with $success_count/11 files successful"
        log_warning "Failed downloads: ${FAILED_JOBS[*]}"
        log_info "Individual ingestion functions will handle missing files"
    fi
}

# Generic GeoNames ingestion function
ingest_geonames_generic() {
    local name="$1"
    local table_name="$2"
    local csv_file="$3"
    local x_field="${4:-long_dd}"
    local y_field="${5:-lat_dd}"
    
    log_info "Ingesting GeoNames ${name}..."
    
    # Check if table already exists
    if table_exists "geonames" "$table_name"; then
        return 0
    fi
    
    safe_cd "$TEMP_DIR" || return 1
    
    # Validate input file
    if [[ ! -f "$csv_file" || ! -s "$csv_file" ]]; then
        log_error "GeoNames file not found or empty: $csv_file"
        return 1
    fi
    
    ogr2ogr -progress \
        -f "PostgreSQL" \
        --config PG_USE_COPY YES \
        "PG:dbname=rbt host=${PG_HOST} user=${PG_USR} password=${PG_PASS}" \
         -a_srs EPSG:4326 \
        -nln "geonames.${table_name}" \
        -lco GEOMETRY_NAME=geometry \
        -nlt POINT \
        -lco PRECISION=NO \
        -lco DIM=2 \
        -lco UNLOGGED=ON \
        -oo QUOTED_FIELDS_AS_STRING=YES \
        -oo "X_POSSIBLE_NAMES=${x_field}" \
        -oo "Y_POSSIBLE_NAMES=${y_field}" \
        -oo EMPTY_STRING_AS_NULL=YES \
        -skipfailures \
        "$csv_file"
}

# Wrapper functions for GeoNames ingestion
ingest_geonames_administrative() {
    ingest_geonames_generic "Administrative Regions" "administrative_regions" "Administrative_Regions.csv"
}

ingest_geonames_hydrographic() {
    ingest_geonames_generic "Hydrographic" "hydrographic" "Hydrographic.csv"
}

ingest_geonames_hypsographic() {
    ingest_geonames_generic "Hypsographic" "hypsographic" "Hypsographic.csv"
}

ingest_geonames_populated_places() {
    ingest_geonames_generic "Populated Places" "populated_places" "Populated_Places.csv"
}

ingest_geonames_spot_features() {
    ingest_geonames_generic "Spot Features" "spot_features" "Spot_Features.csv"
}

ingest_geonames_areas_localities() {
    ingest_geonames_generic "Areas Localities" "areas_localities" "Areas_Localities.csv"
}

ingest_geonames_transportation() {
    ingest_geonames_generic "Transportation Networks" "transportation_networks" "Transportation_Networks.csv"
}

ingest_geonames_undersea() {
    ingest_geonames_generic "Undersea" "undersea" "Undersea.csv"
}

ingest_geonames_vegetation() {
    ingest_geonames_generic "Vegetation" "vegetation" "Vegetation.csv"
}

ingest_geonames_populated_places_national() {
    ingest_geonames_generic "Populated Places National" "populatedplaces_national" \
        "PopulatedPlaces_National.csv" "prim_long_dec" "prim_lat_dec"
}

ingest_geonames_historical_features() {
    ingest_geonames_generic "Historical Features National" "historicalfeatures_national" \
        "HistoricalFeatures_National.csv" "prim_long_dec" "prim_lat_dec"
}

# Execute all GeoNames ingestion jobs in parallel mode
execute_parallel_ingestion() {
    log_info "=== FULL PARALLEL GEONAMES DATA INGESTION MODE ==="
    log_progress "Starting all GeoNames data ingestion jobs in parallel..."
    
    # Download GeoNames files first
    if ! download_geonames_files; then
        log_warning "GeoNames file download failed, but continuing with available files"
    fi
    
    # Reset job arrays for ingestion phase
    COMPLETED_JOBS=()
    FAILED_JOBS=()
    
    # Start all GeoNames ingestion jobs in parallel
    start_job "geonames_administrative" ingest_geonames_administrative
    start_job "geonames_hydrographic" ingest_geonames_hydrographic
    start_job "geonames_hypsographic" ingest_geonames_hypsographic
    start_job "geonames_populated_places" ingest_geonames_populated_places
    start_job "geonames_spot_features" ingest_geonames_spot_features
    start_job "geonames_areas_localities" ingest_geonames_areas_localities
    start_job "geonames_transportation" ingest_geonames_transportation
    start_job "geonames_undersea" ingest_geonames_undersea
    start_job "geonames_vegetation" ingest_geonames_vegetation
    start_job "geonames_populated_places_national" ingest_geonames_populated_places_national
    start_job "geonames_historical_features" ingest_geonames_historical_features
    
    # Wait for all jobs to complete (continue even if some fail)
    wait_for_all_jobs true
    
    return 0
}

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

# =============================================================================
# MAIN EXECUTION FLOW
# =============================================================================

main() {
    local start_time
    start_time=$(date +%s)
    
    log_info "=== STARTING GEONAMES DATA INGESTION ==="
    log_info "Script: $SCRIPT_NAME"
    log_info "Version: Extracted GeoNames processing from main database setup"
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
    
    # Create GeoNames schema first
    log_info "=== SCHEMA CREATION ==="
    if ! create_geonames_schema; then
        log_error "Failed to create GeoNames schema"
        exit 1
    fi
    
    # Choose execution mode based on PARALLEL_INGESTION setting
    if [[ "$PARALLEL_INGESTION" == "true" ]]; then
        # Execute all data ingestion in full parallel mode
        if ! execute_parallel_ingestion; then
            log_warning "Some parallel data ingestion jobs failed, but continuing execution"
        fi
    else
        # Execute in sequential phases (original behavior)
        log_info "=== GEONAMES DATA DOWNLOAD ==="
        log_progress "Downloading GeoNames files..."
        if ! download_geonames_files; then
            log_warning "GeoNames file download failed, but continuing with available files"
        fi
        
        # Reset job arrays for ingestion
        COMPLETED_JOBS=()
        FAILED_JOBS=()
        
        log_info "=== GEONAMES DATA INGESTION ==="
        log_progress "Starting GeoNames data ingestion with parallel jobs..."
        start_job "geonames_administrative" ingest_geonames_administrative
        start_job "geonames_hydrographic" ingest_geonames_hydrographic
        start_job "geonames_hypsographic" ingest_geonames_hypsographic
        start_job "geonames_populated_places" ingest_geonames_populated_places
        start_job "geonames_spot_features" ingest_geonames_spot_features
        start_job "geonames_areas_localities" ingest_geonames_areas_localities
        start_job "geonames_transportation" ingest_geonames_transportation
        start_job "geonames_undersea" ingest_geonames_undersea
        start_job "geonames_vegetation" ingest_geonames_vegetation
        start_job "geonames_populated_places_national" ingest_geonames_populated_places_national
        start_job "geonames_historical_features" ingest_geonames_historical_features
        
        # Wait for all jobs to complete (continue even if some fail)
        wait_for_all_jobs true
    fi
    
    # Final summary
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))
    
    log_success "=== GEONAMES DATA INGESTION COMPLETED ==="
    log_success "Total execution time: ${hours}h ${minutes}m ${seconds}s"
    log_success "Completed jobs: ${#COMPLETED_JOBS[@]}"
    
    if [[ ${#FAILED_JOBS[@]} -gt 0 ]]; then
        log_warning "Failed jobs: ${#FAILED_JOBS[@]} - ${FAILED_JOBS[*]}"
    fi
    
    log_success "GeoNames data ingestion finished successfully!"
}

# Execute main function with all arguments
main "$@"
