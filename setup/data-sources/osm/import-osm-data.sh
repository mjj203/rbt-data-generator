#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, pipe failures

# =============================================================================
# CONTRACT — bash leaf script, invoked via `rbt import osm` / `rbt setup`
# =============================================================================
# Inputs:  OSM planet PBF or regional extract (downloaded via aria2c), env
#          DATABASE_*/PG_* (provided by the rbt CLI), OSM_* settings from
#          config/rbt.conf (data/cache/diff dirs, imposm mapping + config).
# Outputs: imposm-managed OSM tables in the target database; logs under
#          $SHARED_LOG_DIR.
# Exit:    0 on success, non-zero on any failed stage (callers treat this as
#          fatal). Do not invoke directly — only through the rbt CLI, which
#          resolves and exports the environment this script expects.
# =============================================================================

# =============================================================================
# OSM Data Import Script - Optimized for Containerized Environments
# =============================================================================

# Configuration via environment variables with sensible defaults
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source configuration file if available
CONFIG_DIR="${SCRIPT_DIR}/../../../config"
if [[ -f "${CONFIG_DIR}/rbt.conf" ]]; then
    echo "Loading configuration from ${CONFIG_DIR}/rbt.conf"
    # shellcheck source=/dev/null
    source "${CONFIG_DIR}/rbt.conf"
    
    # Map OSM-specific variables to script variables
    export LOG_FILE="${OSM_LOG_FILE:-${LOG_FILE}}"
    export DATA_DIR="${OSM_DATA_DIR:-${DATA_DIR}}"
    export CONFIG_FILE="${OSM_CONFIG_FILE:-${CONFIG_FILE}}"
    export MAPPING_FILE="${OSM_MAPPING_FILE:-${MAPPING_FILE}}"
    export CACHE_DIR="${OSM_CACHE_DIR:-${CACHE_DIR}}"
    export DIFF_DIR="${OSM_DIFF_DIR:-${DIFF_DIR}}"
    export CONNECTION="${OSM_CONNECTION:-${CONNECTION}}"
    export SRID="${OSM_SRID:-${SRID}}"
    export CLEANUP_ON_EXIT="${OSM_CLEANUP_ON_EXIT:-${CLEANUP_ON_EXIT}}"
    export VALIDATE_DOWNLOADS="${OSM_VALIDATE_DOWNLOADS:-${VALIDATE_DOWNLOADS}}"
fi
readonly LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/../logs/osm_import.log}"
readonly DATA_DIR="${DATA_DIR:-/mnt/data}"
readonly CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/imposm-config.json}"
readonly MAPPING_FILE="${MAPPING_FILE:-${SCRIPT_DIR}/imposm-mapping.yaml}"
readonly CACHE_DIR="${CACHE_DIR:-/mnt/cache}"
readonly DIFF_DIR="${DIFF_DIR:-/mnt/diff}"
readonly CONNECTION="${CONNECTION:-postgis://postgres:postgres@localhost/rbt?prefix=NONE}"
readonly SRID="${SRID:-3857}"
readonly MAX_RETRIES="${MAX_RETRIES:-3}"
readonly RETRY_DELAY="${RETRY_DELAY:-10}"
readonly ARIA2C_MAX_DOWNLOADS="${ARIA2C_MAX_DOWNLOADS:-12}"
readonly ARIA2C_MAX_CONNECTIONS="${ARIA2C_MAX_CONNECTIONS:-16}"
readonly ARIA2C_SPLITS="${ARIA2C_SPLITS:-9}"
readonly WGET_PARALLEL_JOBS="${WGET_PARALLEL_JOBS:-8}"
readonly DIFF_START_SEQ="${DIFF_START_SEQ:-713}"
readonly DIFF_END_SEQ="${DIFF_END_SEQ:-730}"
readonly CLEANUP_ON_EXIT="${CLEANUP_ON_EXIT:-true}"
readonly VALIDATE_DOWNLOADS="${VALIDATE_DOWNLOADS:-true}"
# Minimum acceptable PBF size in MB for the import-stage sanity check. The
# default admits regional extracts; raise it (e.g. 50000) to also catch
# truncated planet downloads.
readonly MIN_PBF_SIZE_MB="${OSM_MIN_PBF_SIZE_MB:-10}"

# Global variables
PID_FILE="/tmp/osm_import.pid"
TEMP_FILES=()
BACKGROUND_PIDS=()

# =============================================================================
# Logging Functions
# =============================================================================

log() {
    local level="$1"
    shift
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="[$timestamp] [$level] $*"
    echo "$message" | tee -a "$LOG_FILE"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_debug() { log "DEBUG" "$@"; }

log_progress() {
    local current="$1"
    local total="$2"
    local task="$3"
    local percent=$((current * 100 / total))
    log_info "Progress: $task [$current/$total] ($percent%)"
}

# =============================================================================
# Error Handling and Cleanup
# =============================================================================

cleanup() {
    log_info "Cleaning up resources..."
    
    # Kill background processes
    if [[ ${#BACKGROUND_PIDS[@]} -gt 0 ]]; then
        for pid in "${BACKGROUND_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                log_info "Terminating background process $pid"
                kill -TERM "$pid" 2>/dev/null || true
            fi
        done
    fi
    
    # Remove temporary files if cleanup is enabled
    if [[ "$CLEANUP_ON_EXIT" == "true" ]] && [[ ${#TEMP_FILES[@]} -gt 0 ]]; then
        for file in "${TEMP_FILES[@]}"; do
            if [[ -f "$file" ]]; then
                log_info "Removing temporary file: $file"
                rm -f "$file"
            fi
        done
    fi
    
    # Remove PID file
    [[ -f "$PID_FILE" ]] && rm -f "$PID_FILE"
    
    log_info "Cleanup completed"
}

error_exit() {
    local exit_code="${1:-1}"
    local message="${2:-"Script failed with exit code $exit_code"}"
    log_error "$message"
    cleanup
    exit "$exit_code"
}

signal_handler() {
    local signal="$1"
    log_warn "Received signal $signal, initiating graceful shutdown..."
    cleanup
    exit 130
}

# =============================================================================
# Utility Functions
# =============================================================================

validate_dependencies() {
    local missing_deps=()
    local deps=("aria2c" "wget" "osmium" "osmosis" "imposm")
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        error_exit 127 "Missing dependencies: ${missing_deps[*]}"
    fi
    
    log_info "All dependencies validated"
}

validate_config() {
    [[ -f "$CONFIG_FILE" ]] || error_exit 2 "Config file not found: $CONFIG_FILE"
    [[ -d "$DATA_DIR" ]] || mkdir -p "$DATA_DIR"
    [[ -d "$(dirname "$LOG_FILE")" ]] || mkdir -p "$(dirname "$LOG_FILE")"
    log_info "Configuration validated"
}

retry_command() {
    local max_attempts="$1"
    local delay="$2"
    shift 2
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        log_info "Attempt $attempt/$max_attempts: $*"
        if "$@"; then
            return 0
        else
            local exit_code=$?
            if [[ $attempt -lt $max_attempts ]]; then
                log_warn "Command failed (exit code: $exit_code), retrying in ${delay}s..."
                sleep "$delay"
            else
                log_error "Command failed after $max_attempts attempts"
                return $exit_code
            fi
        fi
        ((attempt++))
    done
}

check_disk_space() {
    local required_gb="$1"
    local available_kb=$(df "$DATA_DIR" | awk 'NR==2 {print $4}')
    local available_gb=$((available_kb / 1024 / 1024))
    
    if [[ $available_gb -lt $required_gb ]]; then
        error_exit 28 "Insufficient disk space. Required: ${required_gb}GB, Available: ${available_gb}GB"
    fi
    
    log_info "Disk space check passed: ${available_gb}GB available"
}

validate_file() {
    local file="$1"
    local min_size_mb="${2:-1}"
    
    if [[ ! -f "$file" ]]; then
        log_error "File not found: $file"
        return 1
    fi
    
    local size_mb=$(($(stat -f%z "$file" 2>/dev/null || stat -c%s "$file") / 1024 / 1024))
    if [[ $size_mb -lt $min_size_mb ]]; then
        log_error "File too small: $file (${size_mb}MB < ${min_size_mb}MB)"
        return 1
    fi
    
    log_info "File validation passed: $file (${size_mb}MB)"
    return 0
}

# =============================================================================
# Download Functions
# =============================================================================

download_planet_file() {
    log_info "Starting planet file download..."
    local start_time=$(date +%s)
    
    # Check if file already exists and is valid
    local planet_file="$DATA_DIR/planet-latest-v2.osm.pbf"
    if [[ -f "$planet_file" ]] && validate_file "$planet_file" "$MIN_PBF_SIZE_MB"; then
        log_info "Planet file already exists and is valid, skipping download"
        return 0
    fi
    
    # Ensure sufficient disk space (estimate 70GB needed)
    check_disk_space 70
    
    local aria2c_args=(
        --file-allocation=falloc
        --max-concurrent-downloads="$ARIA2C_MAX_DOWNLOADS"
        --max-connection-per-server="$ARIA2C_MAX_CONNECTIONS"
        --split="$ARIA2C_SPLITS"
        --http-accept-gzip=true
        --user-agent="OpenMapTiles download-osm 7.1.1 (https://github.com/openmaptiles/openmaptiles-tools)"
        --dir="$DATA_DIR"
        --out=planet-latest.osm.pbf
        --auto-file-renaming=false
        --continue=true
        --max-tries=3
        --retry-wait=10
        --timeout=300
        --summary-interval=60
    )
    
    local mirrors=(
        "https://ftp.spline.de/pub/openstreetmap/pbf/planet-latest.osm.pbf"
        "https://ftp5.gwdg.de/pub/misc/openstreetmap/planet.openstreetmap.org/pbf/planet-latest.osm.pbf"
        "https://ftp.fau.de/osm-planet/pbf/planet-latest.osm.pbf"
        "https://ftpmirror.your.org/pub/openstreetmap/pbf/planet-latest.osm.pbf"
        "https://download.bbbike.org/osm/planet/planet-latest.osm.pbf"
        "https://ftp.nluug.nl/maps/planet.openstreetmap.org/pbf/planet-latest.osm.pbf"
        "https://ftp.osuosl.org/pub/openstreetmap/pbf/planet-latest.osm.pbf"
        "https://ftp.snt.utwente.nl/pub/misc/openstreetmap/planet-latest.osm.pbf"
        "https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf"
    )
    
    if ! retry_command "$MAX_RETRIES" "$RETRY_DELAY" aria2c "${aria2c_args[@]}" "${mirrors[@]}"; then
        error_exit 3 "Failed to download planet file"
    fi
    
    if [[ "$VALIDATE_DOWNLOADS" == "true" ]]; then
        validate_file "$planet_file" 50000 || error_exit 4 "Planet file validation failed"
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    log_info "Planet file download completed in ${duration}s"
}

download_diff_files() {
    local start_seq="${1:-$DIFF_START_SEQ}"
    local end_seq="${2:-$DIFF_END_SEQ}"
    
    log_info "Starting diff files download..."
    log_info "Downloading sequence range: $start_seq to $end_seq"
    local start_time=$(date +%s)
    
    cd "$DATA_DIR" || error_exit 5 "Cannot change to data directory"
    
    # Generate diff file URLs
    local diff_urls=()
    for seq in $(seq -f "%03g" "$start_seq" "$end_seq"); do
        # Convert sequence to path format (000/004/XXX)
        local path="000/004/${seq}"
        diff_urls+=("https://planet.openstreetmap.org/replication/day/${path}.osc.gz")
    done
    
    # Download in batches to avoid overwhelming the server
    local batch_size="$WGET_PARALLEL_JOBS"
    local total_files=${#diff_urls[@]}
    local downloaded=0
    
    for ((i=0; i<total_files; i+=batch_size)); do
        local batch_urls=("${diff_urls[@]:i:batch_size}")
        local pids=()
        
        log_progress $((i+1)) "$total_files" "diff files download"
        
        for url in "${batch_urls[@]}"; do
            local filename=$(basename "$url")
            if [[ -f "$filename" ]] && validate_file "$filename" 1; then
                log_debug "Diff file already exists: $filename"
                ((downloaded++))
                continue
            fi
            
            {
                if retry_command 3 5 wget -q --timeout=60 --tries=3 "$url"; then
                    log_debug "Downloaded: $filename"
                    ((downloaded++))
                else
                    log_error "Failed to download: $url"
                fi
            } &
            pids+=($!)
        done
        
        # Wait for batch to complete
        for pid in "${pids[@]}"; do
            wait "$pid"
        done
        
        # Brief pause between batches
        sleep 2
    done
    
    log_info "Downloaded $downloaded/$total_files diff files"
    
    if [[ "$VALIDATE_DOWNLOADS" == "true" ]]; then
        local valid_files=0
        for seq in $(seq -f "%03g" "$start_seq" "$end_seq"); do
            local filename="${seq}.osc.gz"
            if validate_file "$filename" 1; then
                ((valid_files++))
            fi
        done
        log_info "Validated $valid_files diff files"
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    log_info "Diff files download completed in ${duration}s"
}

# =============================================================================
# Processing Functions
# =============================================================================

merge_diff_files() {
    log_info "Merging diff files..."
    local start_time=$(date +%s)
    
    cd "$DATA_DIR" || error_exit 5 "Cannot change to data directory"
    
    # Add merged file to temp files for cleanup
    TEMP_FILES+=("$DATA_DIR/osm.osc.gz")
    
    if ! retry_command "$MAX_RETRIES" "$RETRY_DELAY" osmium merge-changes -o osm.osc.gz -s [0-9]*.osc.gz; then
        error_exit 6 "Failed to merge diff files"
    fi
    
    if [[ "$VALIDATE_DOWNLOADS" == "true" ]]; then
        validate_file "osm.osc.gz" 10 || error_exit 7 "Merged diff file validation failed"
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    log_info "Diff files merge completed in ${duration}s"
}

apply_changes() {
    log_info "Applying changes to planet file..."
    local start_time=$(date +%s)
    
    cd "$DATA_DIR" || error_exit 5 "Cannot change to data directory"
    
    # Check for input files
    validate_file "osm.osc.gz" 10 || error_exit 8 "Merged diff file not found or invalid"
    validate_file "planet-latest-v2.osm.pbf" 50000 || error_exit 9 "Planet file not found or invalid"
    
    # Add output file to temp files for cleanup
    TEMP_FILES+=("$DATA_DIR/planet.osm.pbf")
    
    local osmosis_args=(
        --read-xml-change file="osm.osc.gz"
        --read-pbf file="planet-latest-v2.osm.pbf"
        --apply-change
        --write-pbf file="planet.osm.pbf"
    )
    
    if ! retry_command "$MAX_RETRIES" "$RETRY_DELAY" osmosis "${osmosis_args[@]}"; then
        error_exit 10 "Failed to apply changes"
    fi
    
    if [[ "$VALIDATE_DOWNLOADS" == "true" ]]; then
        validate_file "planet.osm.pbf" 50000 || error_exit 11 "Updated planet file validation failed"
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    log_info "Changes applied in ${duration}s"
}

import_data() {
    log_info "Importing data with imposm..."
    local start_time=$(date +%s)
    
    cd "$DATA_DIR" || error_exit 5 "Cannot change to data directory"
    
    validate_file "planet.osm.pbf" "$MIN_PBF_SIZE_MB" || error_exit 12 "Planet file not found for import"
    
    local imposm_args=(
        import
        -config "$CONFIG_FILE"
        -mapping "$MAPPING_FILE"
        -cachedir "$CACHE_DIR"
        -diffdir "$DIFF_DIR"
        -srid "$SRID"
        -connection "$CONNECTION"
        -read planet.osm.pbf
        -write
        -diff
        -optimize
    )
    
    if ! retry_command "$MAX_RETRIES" "$RETRY_DELAY" imposm "${imposm_args[@]}"; then
        error_exit 13 "Failed to import data"
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    log_info "Data import completed in ${duration}s"
}

import_diff() {
    log_info "Importing diff files with imposm..."
    local start_time=$(date +%s)
    
    cd "$DATA_DIR" || error_exit 5 "Cannot change to data directory"
    
    # Check if changeset files exist
    local changeset_files=()
    for file in *.osc.gz; do
        if [[ -f "$file" ]]; then
            if validate_file "$file" 1; then
                changeset_files+=("$file")
            else
                log_warn "Invalid changeset file: $file (skipping)"
            fi
        fi
    done
    
    if [[ ${#changeset_files[@]} -eq 0 ]]; then
        error_exit 15 "No valid changeset files found for diff import"
    fi
    
    log_info "Found ${#changeset_files[@]} changeset files for diff import"
    
    # Sort changeset files to ensure proper chronological order
    IFS=$'\n' changeset_files=($(sort <<<"${changeset_files[*]}"))
    unset IFS
    
    local imposm_args=(
        diff
        -config "$CONFIG_FILE"
        -connection "$CONNECTION"
        -diffdir "$DIFF_DIR"
        -srid "$SRID"
        -mapping "$MAPPING_FILE"
        -cachedir "$CACHE_DIR"
    )
    
    # Add all changeset files to the command
    for file in "${changeset_files[@]}"; do
        imposm_args+=("$file")
    done
    
    log_info "Applying ${#changeset_files[@]} changeset files: ${changeset_files[*]}"
    
    if ! retry_command "$MAX_RETRIES" "$RETRY_DELAY" imposm "${imposm_args[@]}"; then
        error_exit 16 "Failed to import diff files"
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    log_info "Diff import completed in ${duration}s"
}

run_imposm() {
    log_info "Starting imposm run for continuous updates..."
    
    cd "$DATA_DIR" || error_exit 5 "Cannot change to data directory"
    
    local imposm_run_args=(
        run
        -config "$CONFIG_FILE"
        -connection "$CONNECTION"
        -diffdir "$DIFF_DIR"
        -srid "$SRID"
        -mapping "$MAPPING_FILE"
        -cachedir "$CACHE_DIR"
    )
    
    # For continuous updates, we don't want to retry indefinitely
    # This will run until interrupted by signal
    imposm "${imposm_run_args[@]}" || error_exit 14 "Imposm run failed"
}

# =============================================================================
# Usage and Help Functions
# =============================================================================

show_usage() {
    echo "Usage: $0 [OPTION] [ARGUMENTS]"
    echo "Import and process OSM data based on the specified option."
    echo ""
    echo "Options:"
    echo "  --all             Run all processes (download planet, diffs, merge, apply, import, run imposm)"
    echo "  --download-planet Download planet file only"
    echo "  --download-diffs START_SEQ END_SEQ"
    echo "                    Download diff files only (requires start and end sequence numbers)"
    echo "  --merge-diffs     Merge diff files only"
    echo "  --apply-changes   Apply changes to planet file only"
    echo "  --import          Import data with imposm only"
    echo "  --import-diff     Import changeset files (.osc.gz) with imposm diff (one-time update)"
    echo "  --run-imposm      Run imposm for continuous updates only"
    echo "  --help            Show this help message"
    echo ""
    echo "Arguments:"
    echo "  START_SEQ         Starting sequence number for diff files (3-digit format)"
    echo "  END_SEQ           Ending sequence number for diff files (3-digit format)"
    echo ""
    echo "Environment variables:"
    echo "  DATA_DIR          Directory for data files (default: /mnt/data)"
    echo "  CONFIG_FILE       Imposm configuration file (default: ./imposm-config.json)"
    echo "  LOG_FILE          Log file path (default: ../logs/osm_import.log)"
    echo "  MAX_RETRIES       Maximum retry attempts (default: 3)"
    echo "  CLEANUP_ON_EXIT   Clean up temporary files on exit (default: true)"
    echo "  OSM_MIN_PBF_SIZE_MB"
    echo "                    Minimum PBF size in MB accepted by the import-stage"
    echo "                    size check (default: 10; admits regional extracts)"
    echo "  DIFF_START_SEQ    Default start sequence for diffs (default: 713)"
    echo "  DIFF_END_SEQ      Default end sequence for diffs (default: 730)"
    echo ""
    echo "Examples:"
    echo "  $0 --all                    # Run complete workflow"
    echo "  $0 --download-planet        # Only download planet file"
    echo "  $0 --download-diffs 713 730 # Download diff files from seq 713 to 730"
    echo "  $0 --download-diffs 800 850 # Download diff files from seq 800 to 850"
    echo "  $0 --import                 # Only import data"
    echo "  $0 --import-diff            # Import changeset files for one-time database update"
}

# =============================================================================
# Individual Process Functions
# =============================================================================

run_download_planet() {
    log_info "Running planet download process only..."
    validate_dependencies
    validate_config
    start_health_check_server
    download_planet_file
    log_info "Planet download completed successfully!"
}

run_download_diffs() {
    local start_seq="${1:-$DIFF_START_SEQ}"
    local end_seq="${2:-$DIFF_END_SEQ}"
    
    log_info "Running diff files download process only..."
    log_info "Using sequence range: $start_seq to $end_seq"
    validate_dependencies
    validate_config
    start_health_check_server
    download_diff_files "$start_seq" "$end_seq"
    log_info "Diff files download completed successfully!"
}

run_merge_diffs() {
    log_info "Running diff files merge process only..."
    validate_dependencies
    validate_config
    start_health_check_server
    merge_diff_files
    log_info "Diff files merge completed successfully!"
}

run_apply_changes() {
    log_info "Running apply changes process only..."
    validate_dependencies
    validate_config
    start_health_check_server
    apply_changes
    log_info "Apply changes completed successfully!"
}

run_import_only() {
    log_info "Running data import process only..."
    validate_dependencies
    validate_config
    start_health_check_server
    import_data
    log_info "Data import completed successfully!"
}

run_import_diff_only() {
    log_info "Running diff import process only..."
    validate_dependencies
    validate_config
    start_health_check_server
    import_diff
    log_info "Diff import completed successfully!"
}

run_imposm_only() {
    log_info "Running imposm continuous updates only..."
    validate_dependencies
    validate_config
    start_health_check_server
    run_imposm
    log_info "Imposm run completed successfully!"
}

# =============================================================================
# Main Execution
# =============================================================================

run_all_processes() {
    log_info "Running all OSM import processes..."
    
    # Validation phase
    validate_dependencies
    validate_config
    
    # Start health check server for container orchestration
    start_health_check_server
    
    # Execute main workflow
    download_planet_file
    download_diff_files "$DIFF_START_SEQ" "$DIFF_END_SEQ"
    merge_diff_files
    apply_changes
    import_data
    run_imposm
    
    log_info "All processes completed successfully!"
}

setup_script_environment() {
    local script_start_time=$(date +%s)
    
    # Write PID file
    echo $$ > "$PID_FILE"
    
    # Set up signal handlers
    trap 'signal_handler SIGINT' INT
    trap 'signal_handler SIGTERM' TERM
    trap 'cleanup' EXIT
    
    # Set system limits
    ulimit -n 1000000
    
    log_info "Starting OSM data import script (PID: $$)"
    log_info "Configuration: DATA_DIR=$DATA_DIR, CONFIG_FILE=$CONFIG_FILE"
    log_info "Log file: $LOG_FILE"
    
    return 0
}

main() {
    # Parse command line arguments first
    if [[ $# -eq 0 ]]; then
        echo "Error: No arguments provided" >&2
        echo ""
        show_usage
        exit 1
    fi
    
    # Validate arguments and handle special cases without setting up environment
    case "$1" in
        --help)
            show_usage
            exit 0
            ;;
        --all|--download-planet|--merge-diffs|--apply-changes|--import|--import-diff|--run-imposm)
            # Valid options, continue to setup
            ;;
        --download-diffs)
            # Validate that start and end sequences are provided
            if [[ $# -lt 3 ]]; then
                echo "Error: --download-diffs requires START_SEQ and END_SEQ arguments" >&2
                echo ""
                show_usage
                exit 1
            fi
            # Validate that arguments are numeric
            if ! [[ "$2" =~ ^[0-9]+$ ]] || ! [[ "$3" =~ ^[0-9]+$ ]]; then
                echo "Error: START_SEQ and END_SEQ must be numeric values" >&2
                echo ""
                show_usage
                exit 1
            fi
            # Validate sequence range
            if [[ $2 -gt $3 ]]; then
                echo "Error: START_SEQ ($2) must be less than or equal to END_SEQ ($3)" >&2
                echo ""
                show_usage
                exit 1
            fi
            ;;
        *)
            echo "Error: Unknown option '$1'" >&2
            echo ""
            show_usage
            exit 1
            ;;
    esac
    
    # Set up environment for all valid operations
    setup_script_environment
    local script_start_time=$(date +%s)
    
    # Process arguments
    case "$1" in
        --all)
            echo "Processing all OSM import steps..."
            run_all_processes
            ;;
        --download-planet)
            echo "Processing planet download only..."
            run_download_planet
            ;;
        --download-diffs)
            echo "Processing diff files download only..."
            run_download_diffs "$2" "$3"
            ;;
        --merge-diffs)
            echo "Processing diff files merge only..."
            run_merge_diffs
            ;;
        --apply-changes)
            echo "Processing apply changes only..."
            run_apply_changes
            ;;
        --import)
            echo "Processing data import only..."
            run_import_only
            ;;
        --import-diff)
            echo "Processing diff import only..."
            run_import_diff_only
            ;;
        --run-imposm)
            echo "Processing imposm run only..."
            run_imposm_only
            ;;
    esac
    
    local script_end_time=$(date +%s)
    local total_duration=$((script_end_time - script_start_time))
    local hours=$((total_duration / 3600))
    local minutes=$(((total_duration % 3600) / 60))
    local seconds=$((total_duration % 60))
    
    log_info "Script completed successfully in ${hours}h ${minutes}m ${seconds}s"
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
