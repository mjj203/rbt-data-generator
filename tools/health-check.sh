#!/bin/bash
set -euo pipefail

# =============================================================================
# RBT Health Check Script
# =============================================================================
# Simple health check script for container orchestration and monitoring
# =============================================================================

# Check if database is accessible
if [[ -n "${PG_HOST:-}" && -n "${PG_USR:-}" && -n "${PG_PASS:-}" ]]; then
    if psql "host=${PG_HOST} port=5432 dbname=rbt user=${PG_USR} password=${PG_PASS}" \
       -c "SELECT 1" >/dev/null 2>&1; then
        echo "OK: Database connection successful"
        exit 0
    else
        echo "ERROR: Database connection failed"
        exit 1
    fi
else
    echo "ERROR: Database credentials not configured"
    exit 1
fi
