#!/bin/bash

# Single source of truth for DATABASE_* / legacy PG_* resolution.
#
# Scripts should:
#   PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
#   source "${PROJECT_ROOT}/scripts/lib/config.sh"
#   rbt_config_load
#
# After `rbt_config_load` returns:
#   - config/rbt.conf has been sourced (if present).
#   - DATABASE_HOST / DATABASE_PORT / DATABASE_NAME / DATABASE_USER / DATABASE_PASSWORD
#     are set (defaulting to legacy PG_* then to sensible defaults).
#   - Legacy PG_HOST / PG_PORT / PG_USR / PG_PASS / PG_DATABASE are exported for
#     downstream tools that still expect them.
#   - rbt_psql_conn_string and rbt_psql_env_exports helpers are defined.

if [[ -n "${RBT_CONFIG_LIB_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
RBT_CONFIG_LIB_SOURCED=1

rbt_config_project_root() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")" && pwd)"
    while [[ "${here}" != "/" ]]; do
        if [[ -f "${here}/config/rbt.conf" ]]; then
            echo "${here}"
            return 0
        fi
        here="$(dirname "${here}")"
    done
    # Fall back to the canonical project root relative to this file.
    (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
}

rbt_config_load() {
    local project_root
    project_root="$(rbt_config_project_root)"
    local config_file="${project_root}/config/rbt.conf"

    if [[ -f "${config_file}" ]]; then
        # shellcheck source=/dev/null
        source "${config_file}"
    fi

    # Resolve DATABASE_* from config → legacy PG_* → defaults.
    : "${DATABASE_HOST:=${PG_HOST:-localhost}}"
    : "${DATABASE_PORT:=${PG_PORT:-5432}}"
    : "${DATABASE_NAME:=${PG_DATABASE:-rbt}}"
    : "${DATABASE_USER:=${PG_USR:-postgres}}"
    : "${DATABASE_PASSWORD:=${PG_PASS:-}}"

    export DATABASE_HOST DATABASE_PORT DATABASE_NAME DATABASE_USER DATABASE_PASSWORD

    # Export legacy names too, for tools that still expect them.
    export PG_HOST="${PG_HOST:-${DATABASE_HOST}}"
    export PG_PORT="${PG_PORT:-${DATABASE_PORT}}"
    export PG_USR="${PG_USR:-${DATABASE_USER}}"
    export PG_PASS="${PG_PASS:-${DATABASE_PASSWORD}}"
    export PG_DATABASE="${PG_DATABASE:-${DATABASE_NAME}}"

    # libpq env vars used directly by psql / ogr2ogr.
    export PGHOST="${DATABASE_HOST}"
    export PGPORT="${DATABASE_PORT}"
    export PGUSER="${DATABASE_USER}"
    export PGDATABASE="${DATABASE_NAME}"
    if [[ -n "${DATABASE_PASSWORD}" ]]; then
        export PGPASSWORD="${DATABASE_PASSWORD}"
    fi

    export RBT_PROJECT_ROOT="${project_root}"
    export RBT_CONFIG_LOADED=1
}

rbt_psql_conn_string() {
    local dbname="${1:-${DATABASE_NAME}}"
    local conn="host=${DATABASE_HOST} port=${DATABASE_PORT} dbname=${dbname} user=${DATABASE_USER}"
    if [[ -n "${DATABASE_PASSWORD:-}" ]]; then
        conn="${conn} password=${DATABASE_PASSWORD}"
    fi
    echo "${conn}"
}

rbt_psql_env_exports() {
    printf 'PGHOST=%q PGPORT=%q PGDATABASE=%q PGUSER=%q' \
        "${DATABASE_HOST}" "${DATABASE_PORT}" "${DATABASE_NAME}" "${DATABASE_USER}"
    if [[ -n "${DATABASE_PASSWORD:-}" ]]; then
        printf ' PGPASSWORD=%q' "${DATABASE_PASSWORD}"
    fi
}
