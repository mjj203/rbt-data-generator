#!/bin/bash

# =============================================================================
# DEPRECATED: the Python engine (`rbt tiles`) is the primary tile generator.
# Kept only as the `rbt tiles --mode bash` escape hatch until a real-data
# parity check (see docs/parity-runbook.md) confirms the native output.
# Do not add new layers here — extend config/layers.yml instead.
# =============================================================================

# =============================================================================
# Optimized Cultural Vector Tiles Generation Script for EPSG:4326
# =============================================================================
# 
# This script generates Mapbox Vector Tiles (MVT) for selected cultural layers
# using GDAL's MVT driver with EPSG:4326 coordinate system and custom tiling.
#
# Usage:
#   ./generate-cultural-4326.sh [options]
#
# Options:
#   --aeroway        Include airport/runway layers
#   --boundary       Include administrative boundary layers
#   --building       Include building structure layers
#   --cemetery       Include cemetery area layers
#   --geonames       Include hydrographic place name layers
#   --populated      Include populated places layers
#   --landuse        Include landuse/recreational layers
#   --military       Include military installation layers
#   --radar          Include radar installation layers
#   --transportation Include roads, railways, and port layers
#   --utilities      Include power, pipeline, and utility layers
#   --all            Include all layers (default if no options provided)
#   --help           Show this help message
#
# Examples:
#   ./generate-cultural-4326.sh --transportation --building
#   ./generate-cultural-4326.sh --all
#   ./generate-cultural-4326.sh --aeroway --boundary --populated --utilities
#
# Prerequisites:
# - PostgreSQL database with 'rbt' schema containing cultural layers
# - GDAL/OGR with MVT driver support
# - Environment variables: PG_HOST, PG_USR, PG_PASS
#
# =============================================================================

set -e  # Exit on any error

# =============================================================================
# Configuration
# =============================================================================

# Determine script location and source configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
readonly CONFIG_FILE="${PROJECT_ROOT}/config/rbt.conf"

# Source configuration
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Configuration file not found: $CONFIG_FILE" >&2
    exit 1
fi

# Database connection parameters (using config variables)
DB_CONNECTION="PG:dbname=${DATABASE_NAME} host=${DATABASE_HOST} user=${DATABASE_USER} password=${DATABASE_PASSWORD}"

# Output configuration
OUTPUT_DIR="cultural_tiles"
DATASET_NAME="cultural"
DATASET_DESCRIPTION="Cultural vector tiles dataset"

# Tiling parameters for EPSG:4326 (using config with fallbacks)
TILING_SCHEME="EPSG:4326,-180,180,360"
MIN_ZOOM="${TILE_MIN_ZOOM:-0}"
MAX_ZOOM="${TILE_MAX_ZOOM:-13}"
MAX_TILE_SIZE=900000
MAX_FEATURES=500000

# =============================================================================
# Layer Configuration (embedded from cultural-layers.json)
# =============================================================================

# Function to get layer configuration JSON
get_layer_config() {
    local layer_name="$1"
    
    case "$layer_name" in
        "aeroway")
            echo '{
    "rbt.aeroway_surface": {
        "target_name": "aeroway_surface",
        "description": "aeroway_surface",
        "minzoom": 8,
        "maxzoom": 13
    },
    "rbt.airports": {
        "target_name": "airports",
        "description": "airports",
        "minzoom": 5,
        "maxzoom": 13
    },
    "rbt.heliports": {
        "target_name": "heliports",
        "description": "heliports",
        "minzoom": 5,
        "maxzoom": 13
    },
    "rbt.runway_curve": {
        "target_name": "runway_curve",
        "description": "runway_curve",
        "minzoom": 8,
        "maxzoom": 13
    }
}'
            ;;
        "boundary")
            echo '{
    "rbt.adm0_labels": {
        "target_name": "adm0_labels",
        "description": "adm0_labels",
        "minzoom": 0,
        "maxzoom": 13
    },
    "rbt.adm0_lines": {
        "target_name": "adm0_lines",
        "description": "adm0_lines",
        "minzoom": 0,
        "maxzoom": 13
    },
    "rbt.adm1_labels": {
        "target_name": "adm1_labels",
        "description": "adm1_labels",
        "minzoom": 3,
        "maxzoom": 13
    },
    "rbt.adm1_lines": {
        "target_name": "adm1_lines",
        "description": "adm1_lines",
        "minzoom": 3,
        "maxzoom": 13
    },
    "rbt.adm2_labels": {
        "target_name": "adm2_labels",
        "description": "adm2_labels",
        "minzoom": 6,
        "maxzoom": 13
    },
    "rbt.adm2_lines": {
        "target_name": "adm2_lines",
        "description": "adm2_lines",
        "minzoom": 6,
        "maxzoom": 13
    }
}'
            ;;
        "building")
            echo '{
    "rbt.building_z10": {
        "target_name": "building",
        "description": "building",
        "minzoom": 10,
        "maxzoom": 13
    },
    "rbt.building_z11": {
        "target_name": "building",
        "description": "building",
        "minzoom": 11,
        "maxzoom": 13
    },
    "rbt.building_z12": {
        "target_name": "building",
        "description": "building",
        "minzoom": 12,
        "maxzoom": 13
    },
    "rbt.building": {
        "target_name": "building",
        "description": "building",
        "minzoom": 13,
        "maxzoom": 13
    }
}'
            ;;
        "cemetery")
            echo '{
    "rbt.cemetery": {
        "target_name": "cemetery",
        "description": "cemetery",
        "minzoom": 8,
        "maxzoom": 13
    },
    "rbt.cemetery_label": {
        "target_name": "cemetery_label",
        "description": "cemetery_label",
        "minzoom": 8,
        "maxzoom": 13
    }
}'
            ;;
        "geonames")
            echo '{
    "rbt.geonames_hydrographic_z2": {
        "target_name": "geonames_hydrographic",
        "description": "geonames_hydrographic",
        "minzoom": 1,
        "maxzoom": 2
    },
    "rbt.geonames_hydrographic_z3": {
        "target_name": "geonames_hydrographic",
        "description": "geonames_hydrographic",
        "minzoom": 3,
        "maxzoom": 3
    },
    "rbt.geonames_hydrographic_z4": {
        "target_name": "geonames_hydrographic",
        "description": "geonames_hydrographic",
        "minzoom": 4,
        "maxzoom": 4
    },
    "rbt.geonames_hydrographic_z5": {
        "target_name": "geonames_hydrographic",
        "description": "geonames_hydrographic",
        "minzoom": 5,
        "maxzoom": 5
    },
    "rbt.geonames_hydrographic_z6": {
        "target_name": "geonames_hydrographic",
        "description": "geonames_hydrographic",
        "minzoom": 6,
        "maxzoom": 6
    },
    "rbt.geonames_hydrographic_z7": {
        "target_name": "geonames_hydrographic",
        "description": "geonames_hydrographic",
        "minzoom": 7,
        "maxzoom": 7
    },
    "rbt.geonames_hydrographic_z8": {
        "target_name": "geonames_hydrographic",
        "description": "geonames_hydrographic",
        "minzoom": 8,
        "maxzoom": 8
    },
    "rbt.geonames_hydrographic_z9": {
        "target_name": "geonames_hydrographic",
        "description": "geonames_hydrographic",
        "minzoom": 9,
        "maxzoom": 9
    },
    "rbt.geonames_hydrographic_z10": {
        "target_name": "geonames_hydrographic",
        "description": "geonames_hydrographic",
        "minzoom": 10,
        "maxzoom": 10
    },
    "rbt.geonames_hydrographic": {
        "target_name": "geonames_hydrographic",
        "description": "geonames_hydrographic",
        "minzoom": 11,
        "maxzoom": 13
    }
}'
            ;;
        "populated")
            echo '{
    "rbt.populated_places_z3": {
        "target_name": "populated_places",
        "description": "populated_places",
        "minzoom": 3,
        "maxzoom": 6
    },
    "rbt.populated_places_z7": {
        "target_name": "populated_places",
        "description": "populated_places",
        "minzoom": 7,
        "maxzoom": 8
    },
    "rbt.populated_places_z9": {
        "target_name": "populated_places",
        "description": "populated_places",
        "minzoom": 9,
        "maxzoom": 11
    },
    "rbt.populated_places": {
        "target_name": "populated_places",
        "description": "populated_places",
        "minzoom": 12,
        "maxzoom": 13
    }
}'
            ;;
        "landuse")
            echo '{
    "rbt.stadium_surface": {
        "target_name": "stadium_surface",
        "description": "stadium_surface",
        "minzoom": 7,
        "maxzoom": 13
    },
    "rbt.stadium_labels": {
        "target_name": "stadium_labels",
        "description": "stadium_labels",
        "minzoom": 7,
        "maxzoom": 13
    }
}'
            ;;
        "military")
            echo '{
    "rbt.us_military_installations": {
        "target_name": "us_military_installations",
        "description": "us_military_installations",
        "minzoom": 4,
        "maxzoom": 13
    },
    "rbt.us_military_installations_labels": {
        "target_name": "us_military_installations_labels",
        "description": "us_military_installations_labels",
        "minzoom": 6,
        "maxzoom": 13
    }
}'
            ;;
        "radar")
            echo '{
    "rbt.radar_point": {
        "target_name": "radar_point",
        "description": "radar_point",
        "minzoom": 7,
        "maxzoom": 13
    }
}'
            ;;
        "transportation")
            echo '{
    "rbt.ferry": {
        "target_name": "ferry",
        "description": "ferry",
        "minzoom": 4,
        "maxzoom": 13
    },
    "rbt.highway_z4": {
        "target_name": "highway",
        "description": "highway",
        "minzoom": 4,
        "maxzoom": 13
    },
    "rbt.highway_z6": {
        "target_name": "highway",
        "description": "highway",
        "minzoom": 6,
        "maxzoom": 13
    },
    "rbt.highway_z7": {
        "target_name": "highway",
        "description": "highway",
        "minzoom": 7,
        "maxzoom": 13
    },
    "rbt.highway_z8": {
        "target_name": "highway",
        "description": "highway",
        "minzoom": 8,
        "maxzoom": 13
    },
    "rbt.highway_z9": {
        "target_name": "highway",
        "description": "highway",
        "minzoom": 9,
        "maxzoom": 13
    },
    "rbt.highway_z10": {
        "target_name": "highway",
        "description": "highway",
        "minzoom": 10,
        "maxzoom": 13
    },
    "rbt.highway_z11": {
        "target_name": "highway",
        "description": "highway",
        "minzoom": 11,
        "maxzoom": 13
    },
    "rbt.highway_z12": {
        "target_name": "highway",
        "description": "highway",
        "minzoom": 12,
        "maxzoom": 13
    },
    "rbt.highway": {
        "target_name": "highway",
        "description": "highway",
        "minzoom": 13,
        "maxzoom": 13
    },
    "rbt.lock_label": {
        "target_name": "lock_label",
        "description": "lock_label",
        "minzoom": 11,
        "maxzoom": 13
    },
    "rbt.lock": {
        "target_name": "lock",
        "description": "lock",
        "minzoom": 11,
        "maxzoom": 13
    },
    "rbt.port_label": {
        "target_name": "port_label",
        "description": "port_label",
        "minzoom": 7,
        "maxzoom": 13
    },
    "rbt.port_surface": {
        "target_name": "port_surface",
        "description": "port_surface",
        "minzoom": 7,
        "maxzoom": 13
    },
    "rbt.railway_z6": {
        "target_name": "railway",
        "description": "railway",
        "minzoom": 6,
        "maxzoom": 13
    },
    "rbt.railway": {
        "target_name": "railway",
        "description": "railway",
        "minzoom": 13,
        "maxzoom": 13
    },
    "rbt.railway_station": {
        "target_name": "railway_station",
        "description": "railway_station",
        "minzoom": 9,
        "maxzoom": 13
    },
    "rbt.railway_station_label": {
        "target_name": "railway_station_label",
        "description": "railway_station_label",
        "minzoom": 11,
        "maxzoom": 13
    },
    "rbt.yard_label": {
        "target_name": "yard_label",
        "description": "yard_label",
        "minzoom": 11,
        "maxzoom": 13
    }
}'
            ;;
        "utilities")
            echo '{
    "rbt.dam_curve": {
        "target_name": "dam_curve",
        "description": "dam_curve",
        "minzoom": 7,
        "maxzoom": 13
    },
    "rbt.dam_surface": {
        "target_name": "dam_surface",
        "description": "dam_surface",
        "minzoom": 7,
        "maxzoom": 13
    },
    "rbt.dam_label": {
        "target_name": "dam_label",
        "description": "dam_label",
        "minzoom": 7,
        "maxzoom": 13
    },
    "rbt.grain_srf": {
        "target_name": "grain_elevator_srf",
        "description": "grain_elevator_srf",
        "minzoom": 8,
        "maxzoom": 13
    },
    "rbt.grain_srf_pnt": {
        "target_name": "grain_elevator",
        "description": "grain_elevator",
        "minzoom": 8,
        "maxzoom": 13
    },
    "rbt.hydrocarbon_field": {
        "target_name": "hydrocarbon_field",
        "description": "hydrocarbon_field",
        "minzoom": 8,
        "maxzoom": 13
    },
    "rbt.hydrocarbon_label": {
        "target_name": "hydrocarbon_label",
        "description": "hydrocarbon_label",
        "minzoom": 8,
        "maxzoom": 13
    },
    "rbt.powerline": {
        "target_name": "powerline",
        "description": "powerline",
        "minzoom": 9,
        "maxzoom": 13
    },
    "rbt.pipeline": {
        "target_name": "pipeline",
        "description": "pipeline",
        "minzoom": 9,
        "maxzoom": 13
    },
    "rbt.utility_point_z6": {
        "target_name": "utility_point",
        "description": "utility_point",
        "minzoom": 6,
        "maxzoom": 13
    },
    "rbt.utility_point_z12": {
        "target_name": "utility_point",
        "description": "utility_point",
        "minzoom": 12,
        "maxzoom": 13
    },
    "rbt.utility_point": {
        "target_name": "utility_point",
        "description": "utility_point",
        "minzoom": 13,
        "maxzoom": 13
    },
    "rbt.power_station": {
        "target_name": "power_station",
        "description": "power_station",
        "minzoom": 8,
        "maxzoom": 13
    },
    "rbt.power_station_label": {
        "target_name": "power_station_label",
        "description": "power_station_label",
        "minzoom": 9,
        "maxzoom": 13
    },
    "rbt.pumping_station": {
        "target_name": "pumping_station",
        "description": "pumping_station",
        "minzoom": 8,
        "maxzoom": 13
    },
    "rbt.pumping_station_label": {
        "target_name": "pumping_station_label",
        "description": "pumping_station_label",
        "minzoom": 9,
        "maxzoom": 13
    }
}'
            ;;
        "all")
            # Special case for all layers - dynamically combine all layer configs
            local all_layers=("aeroway" "boundary" "building" "cemetery" "geonames" "populated" "landuse" "military" "radar" "transportation" "utilities")
            local first=true
            local config_parts=""
            
            for layer in "${all_layers[@]}"; do
                local layer_config=$(get_layer_config "$layer")
                if [[ -n "$layer_config" ]]; then
                    # Remove outer braces and clean up
                    local cleaned_config=$(printf "%s" "$layer_config" | sed -e '1s/^[[:space:]]*{//' -e '$s/}[[:space:]]*$//' -e '/^[[:space:]]*$/d' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
                    
                    if [[ "$first" == true ]]; then
                        config_parts="$cleaned_config"
                        first=false
                    else
                        config_parts=$(printf "%s,\n%s" "$config_parts" "$cleaned_config")
                    fi
                fi
            done
            
            printf "{\n%s\n}" "$config_parts"
            ;;
        *)
            echo "{}"
            ;;
    esac
}

# =============================================================================
# Table Groups
# =============================================================================

# Function to get table group
get_table_group() {
    local layer_name="$1"
    
    case "$layer_name" in
        "aeroway")
            echo "$AEROWAY_TABLES"
            ;;
        "boundary")
            echo "$BOUNDARY_TABLES"
            ;;
        "building")
            echo "$BUILDING_TABLES"
            ;;
        "cemetery")
            echo "$CEMETERY_TABLES"
            ;;
        "geonames")
            echo "$GEONAMES_HYDROGRAPHIC_TABLES"
            ;;
        "populated")
            echo "$POPULATED_PLACES_TABLES"
            ;;
        "landuse")
            echo "$LANDUSE_TABLES"
            ;;
        "military")
            echo "$MIRTA_TABLES"
            ;;
        "radar")
            echo "$RADAR_TABLES"
            ;;
        "transportation")
            echo "$TRANSPORTATION_TABLES"
            ;;
        "utilities")
            echo "$UTILITIES_TABLES"
            ;;
    esac
}

# =============================================================================
# Global Variables
# =============================================================================

# Arrays to track selected layers
declare -a SELECTED_LAYERS=()
declare -a SELECTED_TABLES=()
COMBINED_CONFIG="{}"

# =============================================================================
# Functions
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

show_help() {
    cat << EOF
Optimized Cultural Vector Tiles Generation Script for EPSG:4326

Usage: $0 [options]

Options:
    --aeroway        Include airport/runway layers
    --boundary       Include administrative boundary layers
    --building       Include building structure layers
    --cemetery       Include cemetery area layers
    --geonames       Include hydrographic place name layers
    --populated      Include populated places layers
    --landuse        Include landuse/recreational layers
    --military       Include military installation layers
    --radar          Include radar installation layers
    --transportation Include roads, railways, and port layers
    --utilities      Include power, pipeline, and utility layers
    --all            Include all layers (default if no options provided)
    --help           Show this help message

Environment Variables:
    DEBUG=1          Enable debug output showing generated JSON configuration
    DIAGNOSTIC=1     Test each table individually to identify problematic tables

Examples:
    $0 --transportation --building
    $0 --all
    $0 --aeroway --boundary --populated --utilities
    
    # Debug mode to see generated configuration
    DEBUG=1 $0 --transportation
    
    # Diagnostic mode to test each table individually
    DIAGNOSTIC=1 $0 --all

Description:
    This script generates Mapbox Vector Tiles (MVT) for selected cultural layers
    using GDAL's MVT driver with EPSG:4326 coordinate system. If no options are
    provided, all layers will be included by default.

EOF
    exit 0
}

parse_arguments() {
    local has_selection=false
    
    # If no arguments provided, select all
    if [[ $# -eq 0 ]]; then
        log "No layers specified, defaulting to all layers"
        SELECTED_LAYERS=("aeroway" "boundary" "building" "cemetery" "geonames" "populated" "landuse" "military" "radar" "transportation" "utilities")
        return
    fi
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help)
                show_help
                ;;
            --all)
                SELECTED_LAYERS=("aeroway" "boundary" "building" "cemetery" "geonames" "populated" "landuse" "military" "radar" "transportation" "utilities")
                has_selection=true
                ;;
            --aeroway)
                SELECTED_LAYERS+=("aeroway")
                has_selection=true
                ;;
            --boundary)
                SELECTED_LAYERS+=("boundary")
                has_selection=true
                ;;
            --building)
                SELECTED_LAYERS+=("building")
                has_selection=true
                ;;
            --cemetery)
                SELECTED_LAYERS+=("cemetery")
                has_selection=true
                ;;
            --geonames)
                SELECTED_LAYERS+=("geonames")
                has_selection=true
                ;;
            --populated)
                SELECTED_LAYERS+=("populated")
                has_selection=true
                ;;
            --landuse)
                SELECTED_LAYERS+=("landuse")
                has_selection=true
                ;;
            --military)
                SELECTED_LAYERS+=("military")
                has_selection=true
                ;;
            --radar)
                SELECTED_LAYERS+=("radar")
                has_selection=true
                ;;
            --transportation)
                SELECTED_LAYERS+=("transportation")
                has_selection=true
                ;;
            --utilities)
                SELECTED_LAYERS+=("utilities")
                has_selection=true
                ;;
            *)
                log "ERROR: Unknown option: $1"
                log "Use --help for usage information"
                exit 1
                ;;
        esac
        shift
    done
    
    # Check if any layers were selected
    if [[ "$has_selection" == false ]]; then
        log "No valid layers specified. Use --help for usage information"
        exit 1
    fi
    
    # Remove duplicates from SELECTED_LAYERS
    SELECTED_LAYERS=($(printf '%s\n' "${SELECTED_LAYERS[@]}" | sort -u))
}

build_configuration() {
    log "Building configuration for selected layers..."
    
    local first=true
    local config_parts=""
    local tables=""
    
    for layer in "${SELECTED_LAYERS[@]}"; do
        log "  Adding layer: $layer"
        
        # Add tables for this layer
        local layer_tables=$(get_table_group "$layer")
        if [[ -n "$layer_tables" ]]; then
            if [[ -n "$tables" ]]; then
                tables="${tables},${layer_tables}"
            else
                tables="${layer_tables}"
            fi
        fi
        
        # Add JSON config for this layer
        local layer_config=$(get_layer_config "$layer")
        if [[ -n "$layer_config" ]]; then
            # Parse the JSON entries from the layer config
            # Remove outer braces, empty lines, and leading/trailing whitespace
            local cleaned_config=$(printf "%s" "$layer_config" | sed -e '1s/^[[:space:]]*{//' -e '$s/}[[:space:]]*$//' -e '/^[[:space:]]*$/d' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            
            if [[ "$first" == true ]]; then
                config_parts="$cleaned_config"
                first=false
            else
                # Add comma and newline between configs
                config_parts=$(printf "%s,\n%s" "$config_parts" "$cleaned_config")
            fi
        fi
    done
    
    # Build final configuration with proper formatting
    COMBINED_CONFIG=$(printf "{\n%s\n}" "$config_parts")
    
    # Set the selected tables
    SELECTED_TABLES=("$tables")
    
    log "Configuration built with ${#SELECTED_LAYERS[@]} layer(s)"
}

validate_json_config() {
    local json_config="$1"
    
    # Debug: Show first few lines of config if verbose
    if [[ "${DEBUG:-0}" == "1" ]]; then
        log "DEBUG: Generated JSON configuration:"
        echo "$json_config" | head -20 | while IFS= read -r line; do
            log "  $line"
        done
        log "  ..."
    fi
    
    # Validate JSON syntax
    if command -v python3 &> /dev/null; then
        if ! echo "$json_config" | python3 -m json.tool > /dev/null 2>&1; then
            log "ERROR: Generated JSON has syntax errors:"
            echo "$json_config" | python3 -c "
import json
import sys
try:
    json.load(sys.stdin)
except json.JSONDecodeError as e:
    print(f'  JSON Error: {e}', file=sys.stderr)
    print(f'  Error at line {e.lineno}, column {e.colno}', file=sys.stderr)
    lines = sys.stdin.read().splitlines()
    if e.lineno <= len(lines):
        print(f'  Problem line: {lines[e.lineno-1].strip()}', file=sys.stderr)
" 2>&1
            log "Please check the JSON syntax and try again."
            return 1
        else
            log "JSON validation passed"
        fi
    elif command -v jq &> /dev/null; then
        # Try jq as alternative JSON validator
        if ! echo "$json_config" | jq empty 2>/dev/null; then
            log "ERROR: Generated JSON has syntax errors (validated with jq)"
            return 1
        else
            log "JSON validation passed (jq)"
        fi
    fi
    
    return 0
}

check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check required configuration variables
    if [[ -z "$DATABASE_HOST" || -z "$DATABASE_USER" || -z "$DATABASE_PASSWORD" || -z "$DATABASE_NAME" ]]; then
        log "ERROR: Required configuration variables not set. Please check ${CONFIG_FILE}"
        exit 1
    fi
    
    # Check if ogr2ogr is available
    if ! command -v ogr2ogr &> /dev/null; then
        log "ERROR: ogr2ogr not found. Please install GDAL."
        exit 1
    fi
    
    # Layer configuration is now embedded in the script
    
    log "Prerequisites check passed."
}

test_database_connection() {
    log "Testing database connection..."
    
    # Test connection by attempting to list tables
    if ! ogrinfo "$DB_CONNECTION" -so -sql "SELECT 1" &> /dev/null; then
        log "ERROR: Cannot connect to database. Please check connection parameters."
        exit 1
    fi
    
    log "Database connection successful."
}

cleanup_output() {
    log "Cleaning up previous output..."
    
    if [[ -d "$OUTPUT_DIR" ]]; then
        rm -rf "$OUTPUT_DIR"
        log "Removed existing output directory: $OUTPUT_DIR"
    fi
}

# =============================================================================
# Main Generation Function
# =============================================================================

generate_mvt_tiles() {
    local json_config="$1"
    
    log "Starting MVT tile generation for EPSG:4326..."
    log "Output directory: $OUTPUT_DIR"
    log "Selected layers: ${SELECTED_LAYERS[*]}"
    log "Tables to process: $(echo "${SELECTED_TABLES[@]}" | tr ',' '\n' | wc -l)"
    
    # If DIAGNOSTIC mode is enabled, test each table individually
    if [[ "${DIAGNOSTIC:-0}" == "1" ]]; then
        log "DIAGNOSTIC MODE: Testing each table individually..."
        local all_tables="${SELECTED_TABLES[*]}"
        IFS=',' read -ra TABLE_ARRAY <<< "$all_tables"
        
        for table in "${TABLE_ARRAY[@]}"; do
            log "Testing table: $table"
            local test_dir="${OUTPUT_DIR}_test_${table##*.}"
            
            if ogr2ogr \
                -f MVT \
                -t_srs EPSG:4326 \
                "$test_dir" \
                "$DB_CONNECTION" \
                -oo ACTIVE_SCHEMA=rbt \
                -oo SCHEMAS=rbt \
                -oo TABLES="$table" \
                -dsco NAME="test" \
                -dsco DESCRIPTION="Test for $table" \
                -dsco FORMAT=DIRECTORY \
                -dsco CONF="$json_config" \
                -dsco MINZOOM=0 \
                -dsco MAXZOOM=0 \
                -dsco MAX_SIZE="$MAX_TILE_SIZE" \
                -dsco MAX_FEATURES=10 \
                -dsco TILING_SCHEME="$TILING_SCHEME" \
                -skipfailures \
                2>&1 | head -20; then
                log "  ✓ Table $table processed successfully"
                rm -rf "$test_dir"
            else
                log "  ✗ Table $table FAILED - this may be the source of the error"
                rm -rf "$test_dir"
            fi
        done
        
        log "Diagnostic complete. Proceeding with full generation..."
    fi
    
    # Execute ogr2ogr command with selected tables
    log "Executing ogr2ogr command..."
    log "Using JSON configuration string directly (no temp file)"
    
    ogr2ogr \
        -f MVT \
        -t_srs EPSG:4326 \
        "$OUTPUT_DIR" \
        "$DB_CONNECTION" \
        -oo ACTIVE_SCHEMA=rbt \
        -oo SCHEMAS=rbt \
        -oo TABLES="${SELECTED_TABLES[*]}" \
        -dsco NAME="$DATASET_NAME" \
        -dsco DESCRIPTION="$DATASET_DESCRIPTION" \
        -dsco FORMAT=DIRECTORY \
        -dsco CONF="$json_config" \
        -dsco MINZOOM="$MIN_ZOOM" \
        -dsco MAXZOOM="$MAX_ZOOM" \
        -dsco MAX_SIZE="$MAX_TILE_SIZE" \
        -dsco MAX_FEATURES="$MAX_FEATURES" \
        -dsco TILING_SCHEME="$TILING_SCHEME" \
        -skipfailures \
        -progress
    
    local exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        log "MVT tile generation completed successfully."
    else
        log "ERROR: MVT tile generation failed with exit code $exit_code"
        
        # Provide troubleshooting suggestions
        log ""
        log "Troubleshooting suggestions:"
        log "1. Run with DIAGNOSTIC=1 to test each table individually:"
        log "   DIAGNOSTIC=1 $0 ${SELECTED_LAYERS[*]/#/--}"
        log "2. Check if the database views exist and contain valid data:"
        log "   psql -h \$PG_HOST -U \$PG_USR -d rbt -c \"\\dv rbt.*\""
        log "3. Run with DEBUG=1 to see the generated JSON configuration:"
        log "   DEBUG=1 $0 ${SELECTED_LAYERS[*]/#/--}"
        
        exit $exit_code
    fi
}

generate_metadata() {
    log "Generating metadata..."
    
    # Build categories based on selected layers
    local categories_json=""
    
    # Cultural layer categories
    [[ " ${SELECTED_LAYERS[*]} " =~ " aeroway " ]] && categories_json="${categories_json}        \"aviation\": [\"aeroway_surface\", \"airports\", \"heliports\", \"runway_curve\"],\n"
    [[ " ${SELECTED_LAYERS[*]} " =~ " boundary " ]] && categories_json="${categories_json}        \"administrative\": [\"adm0_labels\", \"adm0_lines\", \"adm1_labels\", \"adm1_lines\", \"adm2_labels\", \"adm2_lines\"],\n"
    [[ " ${SELECTED_LAYERS[*]} " =~ " building " ]] && categories_json="${categories_json}        \"structures\": [\"building\"],\n"
    [[ " ${SELECTED_LAYERS[*]} " =~ " cemetery " ]] && categories_json="${categories_json}        \"memorial\": [\"cemetery\", \"cemetery_label\"],\n"
    [[ " ${SELECTED_LAYERS[*]} " =~ " geonames " ]] && categories_json="${categories_json}        \"place_names\": [\"geonames_hydrographic\"],\n"
    [[ " ${SELECTED_LAYERS[*]} " =~ " populated " ]] && categories_json="${categories_json}        \"settlements\": [\"populated_places\"],\n"
    [[ " ${SELECTED_LAYERS[*]} " =~ " landuse " ]] && categories_json="${categories_json}        \"recreation\": [\"stadium_surface\", \"stadium_labels\"],\n"
    [[ " ${SELECTED_LAYERS[*]} " =~ " military " ]] && categories_json="${categories_json}        \"defense\": [\"us_military_installations\", \"us_military_installations_labels\"],\n"
    [[ " ${SELECTED_LAYERS[*]} " =~ " radar " ]] && categories_json="${categories_json}        \"surveillance\": [\"radar_point\"],\n"
    [[ " ${SELECTED_LAYERS[*]} " =~ " transportation " ]] && categories_json="${categories_json}        \"transport\": [\"ferry\", \"highway\", \"lock\", \"lock_label\", \"port_label\", \"port_surface\", \"railway\", \"railway_station\", \"railway_station_label\", \"yard_label\"],\n"
    [[ " ${SELECTED_LAYERS[*]} " =~ " utilities " ]] && categories_json="${categories_json}        \"infrastructure\": [\"dam_curve\", \"dam_surface\", \"dam_label\", \"grain_elevator_srf\", \"grain_elevator\", \"hydrocarbon_field\", \"hydrocarbon_label\", \"powerline\", \"pipeline\", \"utility_point\", \"power_station\", \"power_station_label\", \"pumping_station\", \"pumping_station_label\"],\n"
    
    # Remove trailing comma and newline
    categories_json=$(echo -e "$categories_json" | sed '$ s/,$//')
    
    # Build tables list
    local tables_list=$(echo "${SELECTED_TABLES[@]}" | tr ',' '\n' | sed 's/^/        "/' | sed 's/$/",/' | sed '$ s/,$//')
    
    # Create metadata file
    cat > "$OUTPUT_DIR/metadata.json" << EOF
{
    "name": "$DATASET_NAME",
    "description": "$DATASET_DESCRIPTION",
    "version": "1.0",
    "minzoom": $MIN_ZOOM,
    "maxzoom": $MAX_ZOOM,
    "format": "pbf",
    "type": "baselayer",
    "attribution": "Generated from PostgreSQL RBT schema",
    "created": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "projection": "EPSG:4326",
    "tiling_scheme": "$TILING_SCHEME",
    "selected_layers": [$(printf '"%s"' "${SELECTED_LAYERS[@]}" | sed 's/""/", "/g')],
    "layer_count": $(echo "${SELECTED_TABLES[@]}" | tr ',' '\n' | wc -l),
    "categories": {
$(echo -e "$categories_json")
    },
    "tables_processed": [
$tables_list
    ]
}
EOF
    
    log "Metadata file created: $OUTPUT_DIR/metadata.json"
}

display_summary() {
    log "=== Generation Summary ==="
    log "Output directory: $OUTPUT_DIR"
    log "Selected layers: ${SELECTED_LAYERS[*]}"
    log "Coordinate system: EPSG:4326"
    log "Zoom levels: $MIN_ZOOM-$MAX_ZOOM"
    log "Tiling scheme: $TILING_SCHEME"
    
    if [[ -d "$OUTPUT_DIR" ]]; then
        local tile_count=$(find "$OUTPUT_DIR" -name "*.pbf" 2>/dev/null | wc -l)
        local dir_size=$(du -sh "$OUTPUT_DIR" 2>/dev/null | cut -f1)
        log "Total tiles generated: $tile_count"
        log "Output directory size: $dir_size"
        
        # List zoom level directories
        log "Zoom levels created:"
        ls -1 "$OUTPUT_DIR" | grep -E '^[0-9]+$' | sort -n | sed 's/^/  z/' || true
        
        # Show selected cultural layer categories
        log "Selected cultural layer categories:"
        for layer in "${SELECTED_LAYERS[@]}"; do
            case $layer in
                aeroway)
                    echo "  - Aviation: airports, heliports, runways"
                    ;;
                boundary)
                    echo "  - Administrative: country, state, county boundaries"
                    ;;
                building)
                    echo "  - Structures: building footprints"
                    ;;
                cemetery)
                    echo "  - Memorial: cemetery areas and labels"
                    ;;
                geonames)
                    echo "  - Place Names: hydrographic place names"
                    ;;
                populated)
                    echo "  - Settlements: populated places"
                    ;;
                landuse)
                    echo "  - Recreation: stadiums and sports facilities"
                    ;;
                military)
                    echo "  - Defense: military installations"
                    ;;
                radar)
                    echo "  - Surveillance: radar installations"
                    ;;
                transportation)
                    echo "  - Transport: roads, railways, ports, ferries"
                    ;;
                utilities)
                    echo "  - Infrastructure: power, pipelines, utilities"
                    ;;
            esac
        done
    fi
    
    log "=========================="
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
    log "Starting optimized cultural 4326 MVT generation..."
    log "Script: $0"
    log "Working directory: $(pwd)"
    
    # Parse command line arguments
    parse_arguments "$@"
    
    # Build configuration for selected layers
    build_configuration
    
    # Pre-flight checks
    check_prerequisites
    test_database_connection
    
    # Validate JSON configuration
    if ! validate_json_config "$COMBINED_CONFIG"; then
        log "ERROR: Invalid JSON configuration generated"
        exit 1
    fi
    
    # Clean up and generate
    cleanup_output
    generate_mvt_tiles "$COMBINED_CONFIG"
    generate_metadata
    
    # Summary
    display_summary
    
    log "Cultural MVT generation completed successfully!"
    log "Tiles are available in: $OUTPUT_DIR"
}

# =============================================================================
# Script Entry Point
# =============================================================================

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi