#!/bin/bash
set -euo pipefail

# =============================================================================
# RBT Overture Building Processing Script
# =============================================================================
# This script processes Overture building data using DuckDB and exports
# building tables with area-based filtering to FlatGeobuf format in multiple
# projections and zoom levels.
# =============================================================================

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Processing results
PROCESSING_ERRORS=0
PROCESSING_WARNINGS=0

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SQL_FILE="${SCRIPT_DIR}/duckdb-building-export.sql"
OUTPUT_DIR="${OUTPUT_DIR:-/data}"
DUCKDB_DATABASE="${DUCKDB_DATABASE:-}"  # Will be set relative to OUTPUT_DIR if not specified
CLEANUP_TEMP_FILES="${CLEANUP_TEMP_FILES:-true}"

# DuckDB Performance Configuration
DUCKDB_MAX_TEMP_SIZE="${DUCKDB_MAX_TEMP_SIZE:-2900GB}"
DUCKDB_TEMP_DIRECTORY="${DUCKDB_TEMP_DIRECTORY:-}"  # Will be set to OUTPUT_DIR if not specified
DUCKDB_MEMORY_LIMIT="${DUCKDB_MEMORY_LIMIT:-200GB}"

# =============================================================================
# Logging Functions
# =============================================================================

log_success() {
    local message="$*"
    echo -e "${GREEN}✅ $message${NC}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') SUCCESS: $message" >> "$LOG_FILE"
}

log_error() {
    local message="$*"
    echo -e "${RED}❌ $message${NC}" >&2
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: $message" >> "$LOG_FILE"
    ((PROCESSING_ERRORS++))
}

log_warning() {
    local message="$*"
    echo -e "${YELLOW}⚠️  $message${NC}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING: $message" >> "$LOG_FILE"
    ((PROCESSING_WARNINGS++))
}

log_info() {
    local message="$*"
    echo -e "${BLUE}ℹ️  $message${NC}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: $message" >> "$LOG_FILE"
}

# =============================================================================
# Validation Functions
# =============================================================================

validate_dependencies() {
    log_info "Checking system dependencies..."
    
    # Check for DuckDB
    if ! command -v duckdb >/dev/null 2>&1; then
        log_error "DuckDB not found. Please install DuckDB CLI."
        log_info "Installation instructions: https://duckdb.org/docs/installation/"
        return 1
    fi
    
    local duckdb_version
    duckdb_version=$(duckdb --version 2>/dev/null || echo "unknown")
    log_success "DuckDB found: $duckdb_version"
    
    # Check for required SQL file
    if [[ ! -f "$SQL_FILE" ]]; then
        log_error "SQL file not found: $SQL_FILE"
        return 1
    fi
    log_success "SQL file found: $SQL_FILE"
    
    return 0
}

validate_duckdb_functionality() {
    log_info "Validating DuckDB functionality..."
    
    # Ensure OUTPUT_DIR exists for testing
    if [[ ! -d "$OUTPUT_DIR" ]]; then
        if ! mkdir -p "$OUTPUT_DIR"; then
            log_error "Cannot create output directory for DuckDB testing: $OUTPUT_DIR"
            return 1
        fi
    fi
    
    # Validate DuckDB can create databases in OUTPUT_DIR
    local test_db="${OUTPUT_DIR}/duckdb_test_$$.db"
    if duckdb "$test_db" -c "SELECT 1;" >/dev/null 2>&1; then
        rm -f "$test_db"
        log_success "DuckDB functionality verified in output directory"
    else
        log_error "DuckDB cannot create databases in output directory: $OUTPUT_DIR"
        log_error "Check permissions and disk space in: $OUTPUT_DIR"
        return 1
    fi
    
    return 0
}

validate_environment() {
    log_info "Validating environment setup..."
    
    # Check if output directory exists, create if needed
    if [[ ! -d "$OUTPUT_DIR" ]]; then
        log_warning "Output directory does not exist: $OUTPUT_DIR"
        if mkdir -p "$OUTPUT_DIR"; then
            log_success "Created output directory: $OUTPUT_DIR"
        else
            log_error "Failed to create output directory: $OUTPUT_DIR"
            return 1
        fi
    else
        log_success "Output directory exists: $OUTPUT_DIR"
    fi
    
    # Check write permissions
    if [[ ! -w "$OUTPUT_DIR" ]]; then
        log_error "No write permission for output directory: $OUTPUT_DIR"
        return 1
    fi
    log_success "Output directory is writable"
    
    # Check disk space (require at least 50GB free)
    local available_gb
    available_gb=$(df "$OUTPUT_DIR" | awk 'NR==2 {print int($4/1024/1024)}')
    local required_gb=50
    
    if [[ $available_gb -ge $required_gb ]]; then
        log_success "Sufficient disk space: ${available_gb}GB available (${required_gb}GB required)"
    else
        log_error "Insufficient disk space: ${available_gb}GB available (${required_gb}GB required)"
        return 1
    fi
    
    return 0
}

validate_network_access() {
    log_info "Checking network access to Overture data..."
    
    # Test S3 access to Overture data
    local test_url="https://overturemaps-us-west-2.s3.us-west-2.amazonaws.com/"
    if curl -s --head "$test_url" >/dev/null 2>&1; then
        log_success "Network access to Overture S3 bucket confirmed"
    else
        log_warning "Cannot verify access to Overture S3 bucket (may still work)"
    fi
    
    return 0
}

# =============================================================================
# Processing Functions
# =============================================================================

prepare_duckdb_database() {
    log_info "Preparing DuckDB database..."
    
    # Ensure the database directory exists
    local db_dir
    db_dir="$(dirname "$DUCKDB_DATABASE")"
    if [[ ! -d "$db_dir" ]]; then
        if mkdir -p "$db_dir"; then
            log_success "Created database directory: $db_dir"
        else
            log_error "Failed to create database directory: $db_dir"
            return 1
        fi
    fi
    
    # Check if database exists and if we should remove it
    if [[ -f "$DUCKDB_DATABASE" ]]; then
        log_warning "DuckDB database already exists: $DUCKDB_DATABASE"
        log_info "Removing previous database to ensure clean processing..."
        if rm "$DUCKDB_DATABASE"; then
            log_success "Removed previous DuckDB database"
        else
            log_error "Could not remove previous DuckDB database: $DUCKDB_DATABASE"
            log_error "Check file permissions and ensure no other processes are using it"
            return 1
        fi
    fi
    
    # Verify write permissions in database directory
    if [[ ! -w "$db_dir" ]]; then
        log_error "No write permission for database directory: $db_dir"
        return 1
    fi
    
    # Create new empty DuckDB database
    log_info "Creating new DuckDB database: $DUCKDB_DATABASE"
    if duckdb "$DUCKDB_DATABASE" -c "SELECT 1;" >/dev/null 2>&1; then
        log_success "Created DuckDB database successfully"
        
        # Verify the database file was created and get its size
        if [[ -f "$DUCKDB_DATABASE" ]]; then
            local db_size
            db_size=$(du -h "$DUCKDB_DATABASE" | cut -f1)
            log_info "Database file size: $db_size"
        else
            log_warning "Database file not found after creation (this shouldn't happen)"
        fi
    else
        log_error "Failed to create DuckDB database: $DUCKDB_DATABASE"
        log_error "Check disk space and permissions"
        return 1
    fi
    
    return 0
}

cleanup_previous_run() {
    log_info "Cleaning up any previous run artifacts..."
    
    # Remove previous output files
    local output_files=(
        "${OUTPUT_DIR}/building_3395.fgb"
        "${OUTPUT_DIR}/building_3857.fgb"
        "${OUTPUT_DIR}/building_4326.fgb"
        "${OUTPUT_DIR}/building_z10_4326.fgb"
        "${OUTPUT_DIR}/building_z11_4326.fgb"
        "${OUTPUT_DIR}/building_z12_4326.fgb"
    )
    
    for file in "${output_files[@]}"; do
        if [[ -f "$file" ]]; then
            if rm "$file"; then
                log_info "Removed previous output file: $(basename "$file")"
            else
                log_warning "Could not remove previous output file: $file"
            fi
        fi
    done
}

execute_duckdb_processing() {
    log_info "Starting DuckDB processing of Overture building data..."
    log_info "This may take several hours depending on data size and network speed..."
    log_info "Using output directory: $OUTPUT_DIR"
    
    local start_time
    start_time=$(date +%s)
    
    # Export environment variables so DuckDB can access them
    export OUTPUT_DIR
    export DUCKDB_MAX_TEMP_SIZE
    export DUCKDB_TEMP_DIRECTORY
    export DUCKDB_MEMORY_LIMIT
    
    # Execute the DuckDB script
    if duckdb "$DUCKDB_DATABASE" < "$SQL_FILE"; then
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        local hours=$((duration / 3600))
        local minutes=$(((duration % 3600) / 60))
        local seconds=$((duration % 60))
        
        log_success "DuckDB processing completed successfully"
        log_success "Processing time: ${hours}h ${minutes}m ${seconds}s"
    else
        log_error "DuckDB processing failed"
        return 1
    fi
    
    return 0
}

validate_output_files() {
    log_info "Validating output files..."
    
    local expected_files=(
        "${OUTPUT_DIR}/building_3395.fgb"
        "${OUTPUT_DIR}/building_3857.fgb"
        "${OUTPUT_DIR}/building_4326.fgb"
        "${OUTPUT_DIR}/building_z10_4326.fgb"
        "${OUTPUT_DIR}/building_z11_4326.fgb"
        "${OUTPUT_DIR}/building_z12_4326.fgb"
    )
    
    local files_found=0
    
    for file in "${expected_files[@]}"; do
        if [[ -f "$file" && -s "$file" ]]; then
            local size_mb
            size_mb=$(du -m "$file" | cut -f1)
            log_success "Output file created: $(basename "$file") (${size_mb}MB)"
            ((files_found++))
        else
            log_error "Expected output file missing or empty: $(basename "$file")"
        fi
    done
    
    if [[ $files_found -eq ${#expected_files[@]} ]]; then
        log_success "All expected output files created successfully"
        return 0
    else
        log_error "Only $files_found of ${#expected_files[@]} expected files were created"
        return 1
    fi
}

cleanup_temporary_files() {
    log_info "Cleaning up temporary files..."
    
    # Remove DuckDB database if cleanup is enabled
    if [[ "${CLEANUP_TEMP_FILES:-true}" == "true" ]]; then
        if [[ -f "$DUCKDB_DATABASE" ]]; then
            if rm "$DUCKDB_DATABASE"; then
                log_success "Removed temporary DuckDB database"
            else
                log_warning "Could not remove temporary DuckDB database: $DUCKDB_DATABASE"
            fi
        fi
    else
        log_info "Keeping temporary DuckDB database for debugging: $DUCKDB_DATABASE"
    fi
}

# =============================================================================
# Main Execution
# =============================================================================

print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --output-dir DIR     Output directory for FlatGeobuf files (default: /data)"
    echo "  --database-file FILE DuckDB database file (default: <output-dir>/overture_buildings.db)"
    echo "  --temp-dir DIR       DuckDB temporary directory (default: <output-dir>)"
    echo "  --memory-limit SIZE  DuckDB memory limit (default: 200GB)"
    echo "  --temp-size SIZE     DuckDB max temp directory size (default: 2900GB)"
    echo "  --keep-temp-files    Keep temporary DuckDB database after processing"
    echo "  --help               Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  OUTPUT_DIR           Output directory (can be overridden by --output-dir)"
    echo "  DUCKDB_DATABASE      DuckDB database file path"
    echo "  DUCKDB_TEMP_DIRECTORY    DuckDB temporary directory for processing"
    echo "  DUCKDB_MEMORY_LIMIT      DuckDB memory limit (e.g., 200GB, 16GB)"
    echo "  DUCKDB_MAX_TEMP_SIZE     Maximum temporary directory size (e.g., 2900GB)"
    echo "  CLEANUP_TEMP_FILES   Set to 'false' to keep temporary files (default: true)"
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --database-file)
                DUCKDB_DATABASE="$2"
                shift 2
                ;;
            --temp-dir)
                DUCKDB_TEMP_DIRECTORY="$2"
                shift 2
                ;;
            --memory-limit)
                DUCKDB_MEMORY_LIMIT="$2"
                shift 2
                ;;
            --temp-size)
                DUCKDB_MAX_TEMP_SIZE="$2"
                shift 2
                ;;
            --keep-temp-files)
                CLEANUP_TEMP_FILES="false"
                shift
                ;;
            --help)
                print_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done
}

main() {
    parse_arguments "$@"
    
    # Set database and log file paths after OUTPUT_DIR is finalized
    # Set DUCKDB_DATABASE to OUTPUT_DIR if not explicitly specified
    if [[ -z "$DUCKDB_DATABASE" ]]; then
        DUCKDB_DATABASE="${OUTPUT_DIR}/overture_buildings.db"
    fi
    # Set DUCKDB_TEMP_DIRECTORY to OUTPUT_DIR if not explicitly specified
    if [[ -z "$DUCKDB_TEMP_DIRECTORY" ]]; then
        DUCKDB_TEMP_DIRECTORY="${OUTPUT_DIR}"
    fi
    LOG_FILE="${OUTPUT_DIR}/overture_building_processing.log"
    
    echo "🏢 RBT Overture Building Processing"
    echo "=================================="
    echo "Output Directory: $OUTPUT_DIR"
    echo "DuckDB Database: $DUCKDB_DATABASE"
    echo "DuckDB Temp Directory: $DUCKDB_TEMP_DIRECTORY"
    echo "DuckDB Memory Limit: $DUCKDB_MEMORY_LIMIT"
    echo "DuckDB Max Temp Size: $DUCKDB_MAX_TEMP_SIZE"
    echo "Log File: $LOG_FILE"
    echo ""
    
    # Initialize log file
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$(date '+%Y-%m-%d %H:%M:%S') Starting Overture building processing..." > "$LOG_FILE"
    
    # Run validation steps
    validate_dependencies || exit 1
    echo ""
    validate_environment || exit 1
    echo ""
    validate_duckdb_functionality || exit 1
    echo ""
    validate_network_access
    echo ""
    
    # Run processing steps
    cleanup_previous_run
    echo ""
    prepare_duckdb_database || exit 1
    echo ""
    execute_duckdb_processing || exit 1
    echo ""
    validate_output_files || exit 1
    echo ""
    cleanup_temporary_files
    echo ""
    
    # Summary
    echo "📋 Processing Summary"
    echo "===================="
    
    if [[ $PROCESSING_ERRORS -eq 0 ]]; then
        if [[ $PROCESSING_WARNINGS -eq 0 ]]; then
            log_success "All processing completed successfully!"
            log_success "Building data exported to: $OUTPUT_DIR"
        else
            echo -e "${YELLOW}⚠️  Processing completed with $PROCESSING_WARNINGS warning(s)${NC}"
            echo "   Check the warnings above and log file: $LOG_FILE"
        fi
        echo ""
        echo "Output files ready for use in vector tile generation."
        echo "Log file: $LOG_FILE"
        exit 0
    else
        echo -e "${RED}❌ Processing failed with $PROCESSING_ERRORS error(s) and $PROCESSING_WARNINGS warning(s)${NC}"
        echo "   Check the errors above and log file: $LOG_FILE"
        exit 1
    fi
}

# Execute main function with all arguments
main "$@"

