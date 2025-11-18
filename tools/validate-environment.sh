#!/bin/bash
set -euo pipefail

# =============================================================================
# RBT Environment Validation Script
# =============================================================================
# This script validates that all required dependencies and environment
# variables are properly configured for RBT Vector Tiles.
# =============================================================================

# Source configuration file
CONFIG_FILE="$(dirname "$0")/../config/rbt.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "Warning: Configuration file not found at $CONFIG_FILE"
    echo "Using default values and environment variables only."
fi

# Resolve database configuration, preferring config values but allowing overrides
: "${DATABASE_HOST:=${PG_HOST:-localhost}}"
: "${DATABASE_PORT:=${PG_PORT:-5432}}"
: "${DATABASE_NAME:=${PG_DATABASE:-rbt}}"
: "${DATABASE_USER:=${PG_USR:-postgres}}"
: "${DATABASE_PASSWORD:=${PG_PASS:-}}"

# Keep backward-compatible PG_* variables in sync for scripts that still rely on them
export PG_HOST="${PG_HOST:-${DATABASE_HOST}}"
export PG_PORT="${PG_PORT:-${DATABASE_PORT}}"
export PG_USR="${PG_USR:-${DATABASE_USER}}"
export PG_PASS="${PG_PASS:-${DATABASE_PASSWORD}}"

readonly ADMIN_DB_CONN="host=${DATABASE_HOST} port=${DATABASE_PORT} dbname=postgres user=${DATABASE_USER} password=${DATABASE_PASSWORD}"
readonly RBT_DB_CONN="host=${DATABASE_HOST} port=${DATABASE_PORT} dbname=${DATABASE_NAME} user=${DATABASE_USER} password=${DATABASE_PASSWORD}"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Validation results
VALIDATION_ERRORS=0
VALIDATION_WARNINGS=0

# =============================================================================
# Logging Functions
# =============================================================================

log_success() {
    echo -e "${GREEN}✅ $*${NC}"
}

log_error() {
    echo -e "${RED}❌ $*${NC}" >&2
    VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
}

log_warning() {
    echo -e "${YELLOW}⚠️  $*${NC}"
    VALIDATION_WARNINGS=$((VALIDATION_WARNINGS + 1))
}

log_info() {
    echo -e "${BLUE}ℹ️  $*${NC}"
}

# =============================================================================
# Validation Functions
# =============================================================================

validate_environment_variables() {
    echo "🔍 Checking environment variables..."
    
    # Required configuration values for database connection
    local required_vars=("DATABASE_HOST" "DATABASE_USER" "DATABASE_NAME")
    
    for var in "${required_vars[@]}"; do
        if [[ -z "$(eval echo \${${var}:-})" ]]; then
            log_error "Required configuration value not set: $var (set in config/rbt.conf or via env override)"
        else
            log_success "Configuration available: $var=${!var}"
        fi
    done
    
    # Optional but recommended variables
    local optional_vars=("DATABASE_PASSWORD" "MAX_PARALLEL_JOBS" "LOG_LEVEL")
    
    for var in "${optional_vars[@]}"; do
        local var_value=$(eval echo \${${var}:-})
        if [[ -z "$var_value" ]]; then
            log_warning "Optional configuration value not set: $var (will use default)"
        else
            local display_value="$var_value"
            if [[ "$var" == "DATABASE_PASSWORD" ]]; then
                display_value="****"
            fi
            log_success "Optional configuration available: $var=${display_value}"
        fi
    done
    
    # Show configuration values being used
    log_info "Database configuration:"
    log_info "  Host: ${DATABASE_HOST}"
    log_info "  Port: ${DATABASE_PORT}"  
    log_info "  Database: ${DATABASE_NAME}"
    log_info "  User: ${DATABASE_USER}"
    log_info "Processing configuration:"
    log_info "  Max parallel jobs: ${MAX_PARALLEL_JOBS}"
    log_info "  Log level: ${LOG_LEVEL}"
    log_info "  Tile cache directory: ${TILE_CACHE_DIR}"
}

validate_system_dependencies() {
    echo "🔍 Checking system dependencies..."
    
    # Core tools
    local required_tools=(
        "psql:PostgreSQL client"
        "ogr2ogr:GDAL/OGR spatial data tools"
        "imposm:Imposm3 OSM import tool"
        "tippecanoe:Mapbox vector tile generation"
        "tile-join:Tippecanoe tile joining tool"
        "wget:File download utility"
        "aws:AWS CLI (for Overture data)"
    )
    
    for tool_desc in "${required_tools[@]}"; do
        local tool="${tool_desc%%:*}"
        local description="${tool_desc##*:}"
        
        if command -v "$tool" >/dev/null 2>&1; then
            local version=$(${tool} --version 2>&1 | head -n1 || echo "version unknown")
            log_success "$description: $tool ($version)"
        else
            log_error "$description: $tool not found"
        fi
    done
    
    # Optional tools
    local optional_tools=(
        "7z:7-Zip archive utility"
        "sqlite3:SQLite database utility"
        "docker:Docker containerization"
    )
    
    for tool_desc in "${optional_tools[@]}"; do
        local tool="${tool_desc%%:*}"
        local description="${tool_desc##*:}"
        
        if command -v "$tool" >/dev/null 2>&1; then
            log_success "$description: $tool (available)"
        else
            log_warning "$description: $tool not found (optional)"
        fi
    done
}

validate_database_connection() {
    echo "🔍 Checking database connection..."
    
    if [[ -z "${DATABASE_HOST:-}" || -z "${DATABASE_USER:-}" ]]; then
        log_error "Database host/user not configured, skipping connection test"
        return
    fi
    
    if [[ -z "${DATABASE_PASSWORD:-}" ]]; then
        log_warning "DATABASE_PASSWORD not set; relying on passwordless/peer authentication"
    fi
    
    # Test basic connection using configuration values
    if psql "$ADMIN_DB_CONN" -c "SELECT version();" >/dev/null 2>&1; then
        log_success "Database connection successful"
        
        # Check if RBT database exists
        if psql "$ADMIN_DB_CONN" \
           -c "SELECT 1 FROM pg_database WHERE datname='${DATABASE_NAME}'" | grep -q 1; then
            log_success "${DATABASE_NAME} database exists"
            
            # Check required extensions
            for extension in ${DATABASE_EXTENSIONS}; do
                if psql "$RBT_DB_CONN" \
                   -c "SELECT 1 FROM pg_extension WHERE extname='${extension}'" | grep -q 1; then
                    log_success "Extension '${extension}' is installed"
                else
                    log_warning "Extension '${extension}' not found in ${DATABASE_NAME} database"
                fi
            done
            
            # Check required schemas
            for schema in ${DATABASE_SCHEMAS}; do
                if psql "$RBT_DB_CONN" \
                   -c "SELECT 1 FROM information_schema.schemata WHERE schema_name='${schema}'" | grep -q 1; then
                    log_success "Schema '${schema}' exists"
                else
                    log_warning "Schema '${schema}' not found in ${DATABASE_NAME} database"
                fi
            done
        else
            log_warning "${DATABASE_NAME} database does not exist (run setup/init-database.sh)"
        fi
    else
        log_error "Cannot connect to database with configured credentials"
    fi
}

validate_disk_space() {
    echo "🔍 Checking disk space..."
    
    local current_dir=$(pwd)
    local available_gb=$(df "$current_dir" | awk 'NR==2 {print int($4/1024/1024)}')
    local required_gb=${DISK_SPACE_REQUIRED_GB}
    
    if [[ $available_gb -ge $required_gb ]]; then
        log_success "Sufficient disk space: ${available_gb}GB available (${required_gb}GB required)"
    else
        log_error "Insufficient disk space: ${available_gb}GB available (${required_gb}GB required)"
    fi
}

validate_memory() {
    echo "🔍 Checking system memory..."
    
    local required_gb=${MEMORY_REQUIRED_GB}
    
    if command -v free >/dev/null 2>&1; then
        local total_gb=$(free -g | awk 'NR==2{print $2}')
        
        if [[ $total_gb -ge $required_gb ]]; then
            log_success "Sufficient memory: ${total_gb}GB total (${required_gb}GB recommended)"
        else
            log_warning "Limited memory: ${total_gb}GB total (${required_gb}GB recommended)"
        fi
    elif [[ "$(uname)" == "Darwin" ]]; then
        local total_gb=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
        
        if [[ $total_gb -ge $required_gb ]]; then
            log_success "Sufficient memory: ${total_gb}GB total (${required_gb}GB recommended)"
        else
            log_warning "Limited memory: ${total_gb}GB total (${required_gb}GB recommended)"
        fi
    else
        log_warning "Cannot determine system memory"
    fi
}

validate_project_structure() {
    echo "🔍 Checking project structure..."
    
    local required_dirs=(
        "setup/data-sources/osm"
        "setup/data-sources/reference-data"
        "setup/data-sources/schemas"
        "production/tile-generation"
        "config"
        "output"
    )
    
    for dir in "${required_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            log_success "Directory exists: $dir"
        else
            log_error "Required directory missing: $dir"
        fi
    done
    
    # Check for key files
    local required_files=(
        "setup/init-database.sh"
        "production/generate-tiles.sh"
        "production/update-osm.sh"
        "config/rbt.conf"
        "setup/data-sources/osm/imposm-mapping.yaml"
        "setup/data-sources/osm/imposm-config.json"
    )
    
    for file in "${required_files[@]}"; do
        if [[ -f "$file" ]]; then
            log_success "File exists: $file"
        else
            log_error "Required file missing: $file"
        fi
    done
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
    echo "🚀 RBT Vector Tiles Environment Validation"
    echo "=========================================="
    echo ""
    
    validate_environment_variables
    echo ""
    validate_system_dependencies
    echo ""
    validate_database_connection
    echo ""
    validate_disk_space
    echo ""
    validate_memory
    echo ""
    validate_project_structure
    echo ""
    
    # Summary
    echo "📋 Validation Summary"
    echo "===================="
    
    if [[ $VALIDATION_ERRORS -eq 0 ]]; then
        if [[ $VALIDATION_WARNINGS -eq 0 ]]; then
            log_success "All validations passed! System is ready for RBT Vector Tiles."
        else
            echo -e "${YELLOW}⚠️  Validation completed with $VALIDATION_WARNINGS warning(s)${NC}"
            echo "   System should work but may have reduced functionality."
        fi
        echo ""
        echo "Next steps:"
        echo "  1. Initialize database: ./setup/init-database.sh"
        echo "  2. Start OSM updates: ./production/update-osm.sh &"
        echo "  3. Generate tiles: ./production/generate-tiles.sh --all"
        exit 0
    else
        echo -e "${RED}❌ Validation failed with $VALIDATION_ERRORS error(s) and $VALIDATION_WARNINGS warning(s)${NC}"
        echo "   Please fix the errors before proceeding."
        exit 1
    fi
}

# Execute main function
main "$@"
