#!/bin/bash

# =============================================================================
# DEPRECATED: the Python engine (`rbt tiles`) is the primary tile generator.
# Kept only as the `rbt tiles --mode bash` escape hatch until a real-data
# parity check (see docs/parity-runbook.md) confirms the native output.
# Do not add new layers here — extend config/layers.yml instead.
# =============================================================================

# =============================================================================
# Optimized Physical Vector Tiles Generation Script for EPSG:4326
# =============================================================================
# 
# This script generates Mapbox Vector Tiles (MVT) for selected physical layers
# using GDAL's MVT driver with EPSG:4326 coordinate system and custom tiling.
#
# Usage:
#   ./4326_optimized_tiles.sh [options]
#
# Options:
#   --builtuparea    Include built-up area layers
#   --contour        Include contour layers
#   --glacier        Include glacier layers
#   --landcover      Include landcover layers
#   --mountain       Include mountain label layers
#   --park           Include park layers
#   --water          Include water layers
#   --all            Include all layers (default if no options provided)
#   --help           Show this help message
#
# Examples:
#   ./4326_optimized_tiles.sh --water --landcover
#   ./4326_optimized_tiles.sh --all
#   ./4326_optimized_tiles.sh --builtuparea --glacier --landcover --mountain --park --water
#
# Prerequisites:
# - PostgreSQL database with 'rbt' schema containing physical layers
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
OUTPUT_DIR="physical_tiles"
DATASET_NAME="physical"
DATASET_DESCRIPTION="Physical vector tiles dataset"

# Tiling parameters for EPSG:4326 (using config with fallbacks)
TILING_SCHEME="EPSG:4326,-180,180,360"
MIN_ZOOM="${TILE_MIN_ZOOM:-0}"
MAX_ZOOM="${TILE_MAX_ZOOM:-13}"
MAX_TILE_SIZE=900000
MAX_FEATURES=500000

# =============================================================================
# Layer Configuration (embedded from physical_layer_config.json)
# =============================================================================

# Function to get layer configuration JSON
get_layer_config() {
    local layer_name="$1"
    
    case "$layer_name" in
        "builtuparea")
            echo '{
    "rbt.builtuparea_ne": {
        "target_name": "builtuparea",
        "description": "builtuparea",
        "minzoom": 3,
        "maxzoom": 8
    },
    "rbt.builtuparea_osm": {
        "target_name": "builtuparea",
        "description": "builtuparea",
        "minzoom": 8,
        "maxzoom": 13
    }
}'
            ;;
        "contour")
            echo '{
    "rbt.contour_z8": {
        "target_name": "contour",
        "description": "contour",
        "minzoom": 8,
        "maxzoom": 13
    },
    "rbt.contour_z10": {
        "target_name": "contour",
        "description": "contour",
        "minzoom": 10,
        "maxzoom": 13
    },
    "rbt.contour_z12": {
        "target_name": "contour",
        "description": "contour",
        "minzoom": 12,
        "maxzoom": 13
    },
    "rbt.contour": {
        "target_name": "contour",
        "description": "contour",
        "minzoom": 13,
        "maxzoom": 13
    },
    "rbt.contour_glacier_z8": {
        "target_name": "contour_glacier",
        "description": "contour_glacier",
        "minzoom": 8,
        "maxzoom": 13
    },
    "rbt.contour_glacier_z10": {
        "target_name": "contour_glacier",
        "description": "contour_glacier",
        "minzoom": 10,
        "maxzoom": 13
    },
    "rbt.contour_glacier_z12": {
        "target_name": "contour_glacier",
        "description": "contour_glacier",
        "minzoom": 12,
        "maxzoom": 13
    },
    "rbt.contour_glacier": {
        "target_name": "contour_glacier",
        "description": "contour_glacier",
        "minzoom": 13,
        "maxzoom": 13
    }
}'
            ;;
        "glacier")
            echo '{
    "rbt.glacier_ne": {
        "target_name": "glacier",
        "description": "glacier",
        "minzoom": 0,
        "maxzoom": 7
    },
    "rbt.glacier_osm": {
        "target_name": "glacier",
        "description": "glacier",
        "minzoom": 7,
        "maxzoom": 13
    }
}'
            ;;
        "landcover")
            echo '{
    "rbt.landcover_z4": {
        "target_name": "landcover",
        "description": "landcover",
        "minzoom": 4,
        "maxzoom": 13
    },
    "rbt.landcover_z6": {
        "target_name": "landcover",
        "description": "landcover",
        "minzoom": 6,
        "maxzoom": 13
    },
    "rbt.landcover_z9": {
        "target_name": "landcover",
        "description": "landcover",
        "minzoom": 9,
        "maxzoom": 13
    },
    "rbt.landcover_z10": {
        "target_name": "landcover",
        "description": "landcover",
        "minzoom": 10,
        "maxzoom": 13
    },
    "rbt.landcover": {
        "target_name": "landcover",
        "description": "landcover",
        "minzoom": 12,
        "maxzoom": 13
    },
    "rbt.landcover_labels_z4": {
        "target_name": "landcover_labels",
        "description": "landcover_labels",
        "minzoom": 4,
        "maxzoom": 13
    },
    "rbt.landcover_labels_z6": {
        "target_name": "landcover_labels",
        "description": "landcover_labels",
        "minzoom": 6,
        "maxzoom": 13
    },
    "rbt.landcover_labels_z9": {
        "target_name": "landcover_labels",
        "description": "landcover_labels",
        "minzoom": 9,
        "maxzoom": 13
    },
    "rbt.landcover_labels_z10": {
        "target_name": "landcover_labels",
        "description": "landcover_labels",
        "minzoom": 10,
        "maxzoom": 13
    },
    "rbt.landcover_labels": {
        "target_name": "landcover_labels",
        "description": "landcover_labels",
        "minzoom": 12,
        "maxzoom": 13
    }
}'
            ;;
        "mountain")
            echo '{
    "rbt.mountain_label": {
        "target_name": "mountain_label",
        "description": "mountain_label",
        "minzoom": 2,
        "maxzoom": 13
    }
}'
            ;;
        "park")
            echo '{
    "rbt.park": {
        "target_name": "park",
        "description": "park",
        "minzoom": 6,
        "maxzoom": 13
    }
}'
            ;;
        "water")
            echo '{
    "rbt.inland_water_intermittent_dissolved": {
        "target_name": "inland_water_intermittent",
        "description": "inland_water_intermittent",
        "minzoom": 8,
        "maxzoom": 13
    },
    "rbt.water_simplified": {
        "target_name": "water",
        "description": "water",
        "minzoom": 0,
        "maxzoom": 9
    },
    "rbt.water": {
        "target_name": "water",
        "description": "water",
        "minzoom": 10,
        "maxzoom": 13
    },
    "rbt.ne_water_label": {
        "target_name": "ne_water_label",
        "description": "ne_water_label",
        "minzoom": 0,
        "maxzoom": 13
    },
    "rbt.waterway": {
        "target_name": "waterway",
        "description": "waterway",
        "minzoom": 5,
        "maxzoom": 13
    }
}'
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
        "builtuparea")
            echo "rbt.builtuparea_ne,rbt.builtuparea_osm"
            ;;
        "contour")
            echo "rbt.contour_z8,rbt.contour_z10,rbt.contour_z12,rbt.contour,rbt.contour_glacier_z8,rbt.contour_glacier_z10,rbt.contour_glacier_z12,rbt.contour_glacier"
            ;;
        "glacier")
            echo "rbt.glacier_ne,rbt.glacier_osm"
            ;;
        "landcover")
            echo "rbt.landcover_z4,rbt.landcover_z6,rbt.landcover_z9,rbt.landcover_z10,rbt.landcover,rbt.landcover_labels_z4,rbt.landcover_labels_z6,rbt.landcover_labels_z9,rbt.landcover_labels_z10,rbt.landcover_labels"
            ;;
        "mountain")
            echo "rbt.mountain_label"
            ;;
        "park")
            echo "rbt.park"
            ;;
        "water")
            echo "rbt.inland_water_intermittent_dissolved,rbt.water_simplified,rbt.water,rbt.ne_water_label,rbt.waterway"
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
Optimized Physical Vector Tiles Generation Script for EPSG:4326

Usage: $0 [options]

Options:
    --builtuparea    Include built-up area layers
    --contour        Include contour layers  
    --glacier        Include glacier layers
    --landcover      Include landcover layers
    --mountain       Include mountain label layers
    --park           Include park layers
    --water          Include water layers
    --all            Include all layers (default if no options provided)
    --help           Show this help message

Environment Variables:
    DEBUG=1          Enable debug output showing generated JSON configuration
    DIAGNOSTIC=1     Test each table individually to identify problematic tables

Examples:
    $0 --water --landcover
    $0 --all
    $0 --builtuparea --glacier --landcover --mountain --park --water
    
    # Debug mode to see generated configuration
    DEBUG=1 $0 --water
    
    # Diagnostic mode to test each table individually
    DIAGNOSTIC=1 $0 --all

Description:
    This script generates Mapbox Vector Tiles (MVT) for selected physical layers
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
        SELECTED_LAYERS=("builtuparea" "contour" "glacier" "landcover" "mountain" "park" "water")
        return
    fi
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help)
                show_help
                ;;
            --all)
                SELECTED_LAYERS=("builtuparea" "contour" "glacier" "landcover" "mountain" "park" "water")
                has_selection=true
                ;;
            --builtuparea)
                SELECTED_LAYERS+=("builtuparea")
                has_selection=true
                ;;
            --contour)
                SELECTED_LAYERS+=("contour")
                has_selection=true
                ;;
            --glacier)
                SELECTED_LAYERS+=("glacier")
                has_selection=true
                ;;
            --landcover)
                SELECTED_LAYERS+=("landcover")
                has_selection=true
                ;;
            --mountain)
                SELECTED_LAYERS+=("mountain")
                has_selection=true
                ;;
            --park)
                SELECTED_LAYERS+=("park")
                has_selection=true
                ;;
            --water)
                SELECTED_LAYERS+=("water")
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
    local category_items=""
    
    # Terrain category
    if [[ " ${SELECTED_LAYERS[*]} " =~ " contour " ]] || [[ " ${SELECTED_LAYERS[*]} " =~ " mountain " ]]; then
        category_items=""
        [[ " ${SELECTED_LAYERS[*]} " =~ " contour " ]] && category_items="\"contour\", \"contour_glacier\""
        [[ " ${SELECTED_LAYERS[*]} " =~ " mountain " ]] && {
            [[ -n "$category_items" ]] && category_items="${category_items}, "
            category_items="${category_items}\"mountain_label\""
        }
        categories_json="${categories_json}        \"terrain\": [${category_items}],\n"
    fi
    
    # Hydrology category
    if [[ " ${SELECTED_LAYERS[*]} " =~ " water " ]]; then
        categories_json="${categories_json}        \"hydrology\": [\"water\", \"waterway\", \"inland_water_intermittent\", \"ne_water_label\"],\n"
    fi
    
    # Land Surface category
    category_items=""
    [[ " ${SELECTED_LAYERS[*]} " =~ " landcover " ]] && category_items="\"landcover\", \"landcover_labels\""
    [[ " ${SELECTED_LAYERS[*]} " =~ " glacier " ]] && {
        [[ -n "$category_items" ]] && category_items="${category_items}, "
        category_items="${category_items}\"glacier\""
    }
    [[ " ${SELECTED_LAYERS[*]} " =~ " builtuparea " ]] && {
        [[ -n "$category_items" ]] && category_items="${category_items}, "
        category_items="${category_items}\"builtuparea\""
    }
    [[ -n "$category_items" ]] && categories_json="${categories_json}        \"land_surface\": [${category_items}],\n"
    
    # Recreation category
    if [[ " ${SELECTED_LAYERS[*]} " =~ " park " ]]; then
        categories_json="${categories_json}        \"recreation\": [\"park\"],\n"
    fi
    
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
    "selected_layers": [$(printf '"%s"' "${SELECTED_LAYERS[@]}" | sed 's/""/, "/g')],
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
        
        # Show selected layer categories
        log "Selected physical layer categories:"
        for layer in "${SELECTED_LAYERS[@]}"; do
            case $layer in
                contour|mountain)
                    echo "  - Terrain: $layer"
                    ;;
                water)
                    echo "  - Hydrology: water, waterway, inland_water_intermittent, ne_water_label"
                    ;;
                landcover|glacier|builtuparea)
                    echo "  - Land Surface: $layer"
                    ;;
                park)
                    echo "  - Recreation: park"
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
    log "Starting optimized physical 4326 MVT generation..."
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
    
    log "Physical MVT generation completed successfully!"
    log "Tiles are available in: $OUTPUT_DIR"
}

# =============================================================================
# Script Entry Point
# =============================================================================

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
