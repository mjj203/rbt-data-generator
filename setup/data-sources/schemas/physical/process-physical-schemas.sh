#!/bin/bash

# Exit on any error, undefined variables, and pipe failures
set -euo pipefail

# Source configuration file if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/../../../../config"
if [[ -f "${CONFIG_DIR}/rbt.conf" ]]; then
    echo "Loading configuration from ${CONFIG_DIR}/rbt.conf"
    # shellcheck source=/dev/null
    source "${CONFIG_DIR}/rbt.conf"
fi

# Set connection parameters
export PGHOST=${DATABASE_HOST}
export PGPORT=${DATABASE_PORT}
export PGUSER=${DATABASE_USER}
export PGDATABASE=${DATABASE_NAME}
export PGPASSWORD=${DATABASE_PASSWORD}

# Show usage information
show_usage() {
    echo "Usage: $0 [OPTION]"
    echo "Process physical layer SQL scripts based on the specified option."
    echo ""
    echo "Options:"
    echo "  --all        Process all SQL scripts (physical, landcover, water, contour)"
    echo "  --physical   Process only physical-core.sql"
    echo "  --landcover  Process only landcover.sql"
    echo "  --water      Process only water-features.sql"
    echo "  --contour    Process only terrain.sql"
    echo "  --help       Show this help message"
    echo ""
    echo "Environment variables required:"
    echo "  PG_USR       PostgreSQL username"
    echo "  PG_PASS      PostgreSQL password"
}

# Validate required environment variables
validate_environment() {
    if [[ -z "${PG_USR:-}" ]]; then
        echo "Error: PG_USR environment variable is not set" >&2
        exit 1
    fi

    if [[ -z "${PG_PASS:-}" ]]; then
        echo "Error: PG_PASS environment variable is not set" >&2
        exit 1
    fi
}

# Ensure logs directory exists
setup_logging() {
    local LOG_DIR="${SHARED_LOG_DIR:-logs}"
    mkdir -p "$LOG_DIR"
}

# Execute physical layer SQL script
run_physical() {
    local LOG_DIR="${SHARED_LOG_DIR:-logs}"
    echo "Starting physical layer processing..."
    if psql -f physical-core.sql 2>&1 | tee "${LOG_DIR}/physical_execution_$(date +%Y%m%d_%H%M%S).log"; then
        echo "Physical layer processing completed successfully!"
    else
        echo "Error: Physical layer processing failed!" >&2
        exit 1
    fi
}

# Execute landcover layer SQL script
run_landcover() {
    local LOG_DIR="${SHARED_LOG_DIR:-logs}"
    echo "Starting landcover layer processing..."
    if psql -f landcover.sql 2>&1 | tee "${LOG_DIR}/landcover_execution_$(date +%Y%m%d_%H%M%S).log"; then
        echo "Landcover layer processing completed successfully!"
    else
        echo "Error: Landcover layer processing failed!" >&2
        exit 1
    fi
}

# Execute water layer SQL script
run_water() {
    local LOG_DIR="${SHARED_LOG_DIR:-logs}"
    echo "Starting water layer processing..."
    if psql -f water-features.sql 2>&1 | tee "${LOG_DIR}/water_execution_$(date +%Y%m%d_%H%M%S).log"; then
        echo "Water layer processing completed successfully!"
    else
        echo "Error: Water layer processing failed!" >&2
        exit 1
    fi
}

# Execute contour layer SQL script
run_contour() {
    local LOG_DIR="${SHARED_LOG_DIR:-logs}"
    echo "Starting contour layer processing..."
    if psql -f terrain.sql 2>&1 | tee "${LOG_DIR}/contour_execution_$(date +%Y%m%d_%H%M%S).log"; then
        echo "Contour layer processing completed successfully!"
    else
        echo "Error: Contour layer processing failed!" >&2
        exit 1
    fi
}

# Execute all SQL scripts
run_all() {
    run_physical
    run_landcover
    run_water
    run_contour
}

# Parse command line arguments
if [[ $# -eq 0 ]]; then
    echo "Error: No arguments provided" >&2
    echo ""
    show_usage
    exit 1
fi

# Validate environment and setup
validate_environment
setup_logging

# Process arguments
case "$1" in
    --all)
        echo "Processing all SQL scripts..."
        run_all
        echo "All processing completed successfully!"
        ;;
    --physical)
        echo "Processing physical layer only..."
        run_physical
        ;;
    --landcover)
        echo "Processing landcover layer only..."
        run_landcover
        ;;
    --water)
        echo "Processing water layer only..."
        run_water
        ;;
    --contour)
        echo "Processing contour layer only..."
        run_contour
        ;;
    --help)
        show_usage
        exit 0
        ;;
    *)
        echo "Error: Unknown option '$1'" >&2
        echo ""
        show_usage
        exit 1
        ;;
esac