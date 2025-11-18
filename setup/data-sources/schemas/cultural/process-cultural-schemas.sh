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
    echo "Process cultural layer SQL scripts based on the specified option."
    echo ""
    echo "Options:"
    echo "  --all        Process all SQL scripts (cultural, highway, railway, aero)"
    echo "  --cultural   Process only cultural.sql"
    echo "  --highway    Process only highway.sql"
    echo "  --railway    Process only railway.sql"
    echo "  --aero       Process only aero.sql"
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

# Execute cultural layer SQL script
run_cultural() {
    local LOG_DIR="${SHARED_LOG_DIR:-logs}"
    echo "Starting cultural layer processing..."
    if psql -f cultural-core.sql 2>&1 | tee "${LOG_DIR}/cultural_execution_$(date +%Y%m%d_%H%M%S).log"; then
        echo "Cultural layer processing completed successfully!"
    else
        echo "Error: Cultural layer processing failed!" >&2
        exit 1
    fi
}

# Execute highway layer SQL script
run_highway() {
    local LOG_DIR="${SHARED_LOG_DIR:-logs}"
    echo "Starting highway layer processing..."
    if psql -f transportation.sql 2>&1 | tee "${LOG_DIR}/highway_execution_$(date +%Y%m%d_%H%M%S).log"; then
        echo "Highway layer processing completed successfully!"
    else
        echo "Error: Highway layer processing failed!" >&2
        exit 1
    fi
}

# Execute railway layer SQL script
run_railway() {
    local LOG_DIR="${SHARED_LOG_DIR:-logs}"
    echo "Starting railway layer processing..."
    if psql -f transportation-railway.sql 2>&1 | tee "${LOG_DIR}/railway_execution_$(date +%Y%m%d_%H%M%S).log"; then
        echo "Railway layer processing completed successfully!"
    else
        echo "Error: Railway layer processing failed!" >&2
        exit 1
    fi
}

# Execute aero layer SQL script
run_aero() {
    local LOG_DIR="${SHARED_LOG_DIR:-logs}"
    echo "Starting aero layer processing..."
    if psql -f infrastructure.sql 2>&1 | tee "${LOG_DIR}/aero_execution_$(date +%Y%m%d_%H%M%S).log"; then
        echo "Aero layer processing completed successfully!"
    else
        echo "Error: Aero layer processing failed!" >&2
        exit 1
    fi
}

# Execute all SQL scripts
run_all() {
    run_cultural
    run_highway
    run_railway
    run_aero
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
    --cultural)
        echo "Processing cultural layer only..."
        run_cultural
        ;;
    --highway)
        echo "Processing highway layer only..."
        run_highway
        ;;
    --railway)
        echo "Processing railway layer only..."
        run_railway
        ;;
    --aero)
        echo "Processing aero layer only..."
        run_aero
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
