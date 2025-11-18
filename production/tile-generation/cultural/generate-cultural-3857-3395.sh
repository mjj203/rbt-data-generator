#!/bin/bash

# =============================================================================
# Unified Cultural Vector Tiles Generation Script
# =============================================================================
# 
# This script generates Mapbox Vector Tiles (MBTiles) for all cultural layers
# using tippecanoe with configurable projection support (EPSG:3857, EPSG:3395).
#
# Consolidates all individual cultural layer tiles.sh scripts into a single workflow:
# - Exports data from PostgreSQL to FlatGeoBuf format  
# - Applies layer-specific tippecanoe filters and configurations
# - Outputs individual MBTiles files for each cultural layer
#
# Prerequisites:
# - PostgreSQL database with 'rbt' schema containing all cultural layers
# - GDAL/OGR with FlatGeoBuf support
# - Tippecanoe with filter support
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

# Default projection (can be overridden via command line)
PROJECTION_CODE="3857"
PROJECTION=""
OUTPUT_DIR=""

# Layer selection flags (default: run all layers)
RUN_AEROWAY=false
RUN_BOUNDARY=false
RUN_BUILDING=false
RUN_CEMETERY=false
RUN_GEONAMES=false
RUN_TRANSPORTATION=false
RUN_UTILITIES=false
RUN_OTHER=false
RUN_ALL=false

# Processing option flags
TILE_JOIN=false
ADD_BTIS=false

# BTP Schema version (default: 1.0.0)
BTP_SCHEMA_VERSION="1.0.0"

# Tippecanoe temp directory (using config with fallback)
TEMP_DIR="${TILE_TEMP_DIR:-/mnt/data}"

# =============================================================================
# Projection Configuration
# =============================================================================

configure_projection() {
    case "$PROJECTION_CODE" in
        3857)
            PROJECTION="EPSG:3857"
            OUTPUT_DIR="cultural_tiles_3857"
            TILE_ORIGIN_X="-20037508.343"
            TILE_ORIGIN_Y="20037508.343"
            TILE_DIMENSION="40075016.686"
            ;;
        3395)
            PROJECTION="EPSG:3395"
            OUTPUT_DIR="cultural_tiles_3395"
            TILE_ORIGIN_X="-20037508.343"
            TILE_ORIGIN_Y="20037508.343"
            TILE_DIMENSION="40075016.686"
            ;;
        *)
            log "ERROR: Unsupported projection code: $PROJECTION_CODE"
            log "Supported projections: 3857, 3395"
            exit 1
            ;;
    esac
}

# =============================================================================
# tippecanoe filter definitions
# =============================================================================

BUILDING_FILTER='{"*":["any",["all",[">=","$zoom",10],[">","area",5000]],["all",[">=","$zoom",11],[">","area",2500]],["all",[">=","$zoom",12],[">","area",1500]],["all",[">=","$zoom",13]]]}'

HIGHWAY_FILTER='{

    "*":
    ["any",
    ["all", [">=", "$zoom", 4], ["in", "subclass", "motorway", "trunk", "construction_trunk", "construction_motorway"]],
    ["all", [">=", "$zoom", 6], ["in", "subclass", "motorway", "trunk", "primary", "construction_trunk", "construction_motorway", "construction_primary"]],
    ["all", [">=", "$zoom", 7], ["in", "subclass", "motorway", "motorway_link", "trunk", "primary", "construction_trunk", "construction_motorway", "construction_primary"]],
    ["all", [">=", "$zoom", 8], ["in", "subclass", "motorway", "motorway_link", "trunk", "trunk_link", "primary", "secondary", "construction_trunk", "construction_motorway", "construction_primary", "construction_secondary"]],
    ["all", [">=", "$zoom", 9], ["in", "subclass", "motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link", "secondary", "construction_trunk", "construction_motorway", "construction_primary", "construction_secondary"]],
    ["all", [">=", "$zoom", 10], ["in", "subclass", "motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link", "secondary", "tertiary", "construction_trunk", "construction_motorway", "construction_primary", "construction_secondary", "construction_tertiary", "construction", "construction_unclassified", "construction_road"]],
    ["all", [">=", "$zoom", 11], ["in", "subclass", "motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link", "secondary", "secondary_link", "tertiary", "tertiary_link", "unclassified", "road", "construction_trunk", "construction_motorway", "construction_primary", "construction_secondary", "construction_tertiary", "construction_unclassified", "construction_road","construction"]],
    ["all", [">=", "$zoom", 12], ["in", "subclass", "motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link", "secondary", "secondary_link", "tertiary", "tertiary_link", "unclassified", "proposed", "road", "living_street", "residential", "tertiary_link", "unclassified", "road", "construction_trunk", "construction_motorway", "construction_primary", "construction_secondary", "construction", "construction_tertiary", "construction_unclassified", "construction_road", "construction_residential", "construction_living_street"]],
    ["all", [">=", "$zoom", 13]]
    ]
}'

RAILWAY_FILTER='{"*":["any",["all",[">=","$zoom",6],["!=","service","yard"]],["all",[">=","$zoom",13]]]}'

HYDROGRAPHIC_FILTER='{"*":["any",["all",[">=","$zoom",1],["in","class","Ocean","Sea"]],["all",[">=","$zoom",3],["in","class","Ocean","Sea","Gulf"]],["all",[">=","$zoom",4],[">=","area",12417500000]],["all",[">=","$zoom",5],[">=","area",9468380000]],["all",[">=","$zoom",6],[">=","area",5608210000]],["all",[">=","$zoom",7],[">=","area",1406880000]],["all",[">=","$zoom",8],[">=","area",24216600]],["all",[">=","$zoom",9],[">=","area",11804400]],["all",[">=","$zoom",10],[">","area",0]],["all",[">=","$zoom",12]]]}'

POPULATED_PLACES_FILTER='{"*":["any",["all",[">=","$zoom",3],["<","rank",8]],["all",[">=","$zoom",7],["<","rank",11]],["all",[">=","$zoom",9],["<","rank",12]],["all",[">=","$zoom",12]]]}'

UTILITY_FILTER='{"*":["any",["all",[">=","$zoom",6],["!in","subclass","utility_pole","pole","tower"]],["all",[">=","$zoom",12],["!in","subclass","utility_pole","pole"]],["all",[">=","$zoom",13]]]}'

# =============================================================================
# Functions
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
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
    
    # Check if tippecanoe is available
    if ! command -v tippecanoe &> /dev/null; then
        log "ERROR: tippecanoe not found. Please install tippecanoe."
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

show_help() {
    cat << EOF
Unified Cultural Vector Tiles Generation Script

Usage: $0 [OPTIONS]

Generate Mapbox Vector Tiles for cultural layers with configurable projection support.

OPTIONS:
    --projection <code>      Set projection (3857 or 3395). Default: 3857
    --temp-dir <path>        Temp directory for tippecanoe processing. Default: /mnt/data
    --all                    Generate all cultural layers (default behavior)
    --aeroway                Generate aeroway layers only (surface, airports, heliports, curves)
    --boundary               Generate boundary layers only (adm0/adm1/adm2 labels and lines)
    --building               Generate building layer only
    --cemetery               Generate cemetery layers only (polygons and labels)
    --geonames               Generate geonames layers only (hydrographic, populated places)
    --transportation         Generate transportation layers only (highway, railway, ferry, ports, stations)
    --utilities              Generate utilities layers only (dam, grain, hydrocarbon, powerline, pipeline)
    --other                  Generate other cultural layers only (stadium, military, radar)
    --tile-join              Join multiple layer tiles into a consolidated MBTiles file
    --add-btis               Add BTIS metadata to the final MBTiles file
    --version <version>      Set BTP schema version. Default: 1.0.0
    --help, -h               Show this help message

PROJECTION CODES:
    3857    Web Mercator (default)
    3395    World Mercator

EXAMPLES:
    # Generate all layers in default projection (EPSG:3857)
    $0
    $0 --all
    
    # Generate all layers in EPSG:3395
    $0 --projection 3395 --all
    
    # Generate with custom temp directory for tippecanoe
    $0 --temp-dir /tmp/tippecanoe --all
    
    # Generate specific layers with custom temp directory
    $0 --temp-dir /mnt/fast-storage --transportation --building
    
    # Generate all layers with tile joining and BTIS metadata
    $0 --all --tile-join --add-btis
    
    # Generate single layer category in specific projection
    $0 --projection 3395 --building
    $0 --projection 3857 --transportation --add-btis
    
    # Generate multiple specific layer categories with joining
    $0 --aeroway --boundary --transportation --tile-join
    
    # Generate infrastructure-related layers with full processing
    $0 --utilities --transportation --building --tile-join --add-btis

NOTES:
    - Multiple layer options can be combined
    - Use --tile-join to merge multiple layers into a consolidated MBTiles file
    - Use --add-btis to add BTIS metadata to the final MBTiles file  
    - --add-btis requires either a single layer or --tile-join with multiple layers
    - Individual layer MBTiles files are always generated alongside any consolidated file
    - Configuration loaded from: ${CONFIG_FILE}

EOF
}

parse_arguments() {
    if [[ $# -eq 0 ]]; then
        # No arguments provided - run all layers (backward compatibility)
        RUN_ALL=true
        return 0
    fi
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --projection)
                if [[ -z "$2" ]]; then
                    log "ERROR: --projection requires a value"
                    exit 1
                fi
                PROJECTION_CODE="$2"
                shift 2
                ;;
            --temp-dir)
                if [[ -z "$2" ]]; then
                    log "ERROR: --temp-dir requires a value"
                    exit 1
                fi
                TEMP_DIR="$2"
                shift 2
                ;;
            --all)
                RUN_ALL=true
                shift
                ;;
            --aeroway)
                RUN_AEROWAY=true
                shift
                ;;
            --boundary)
                RUN_BOUNDARY=true
                shift
                ;;
            --building)
                RUN_BUILDING=true
                shift
                ;;
            --cemetery)
                RUN_CEMETERY=true
                shift
                ;;
            --geonames)
                RUN_GEONAMES=true
                shift
                ;;
            --transportation)
                RUN_TRANSPORTATION=true
                shift
                ;;
            --utilities)
                RUN_UTILITIES=true
                shift
                ;;
            --other)
                RUN_OTHER=true
                shift
                ;;
            --tile-join)
                TILE_JOIN=true
                shift
                ;;
            --add-btis)
                ADD_BTIS=true
                shift
                ;;
            --version)
                if [[ -z "$2" ]]; then
                    log "ERROR: --version requires a value"
                    exit 1
                fi
                BTP_SCHEMA_VERSION="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log "ERROR: Unknown option: $1"
                log "Use --help for usage information."
                exit 1
                ;;
        esac
    done
    
    # If --all was specified, set all individual flags to true
    if [[ "$RUN_ALL" == "true" ]]; then
        RUN_AEROWAY=true
        RUN_BOUNDARY=true
        RUN_BUILDING=true
        RUN_CEMETERY=true
        RUN_GEONAMES=true
        RUN_TRANSPORTATION=true
        RUN_UTILITIES=true
        RUN_OTHER=true
    fi
}

setup_output() {
    log "Setting up output directory..."
    
    mkdir -p "$OUTPUT_DIR"
    log "Output directory ready: $OUTPUT_DIR"
}

# =============================================================================
# Cultural Layer Generation Functions
# =============================================================================

generate_aeroway() {
    log "Generating aeroway layers..."
    
    # Aeroway Surface
    local fgb_file="$OUTPUT_DIR/aeroway_surface_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$fgb_file" ]]; then
        log "FlatGeoBuf file already exists: $fgb_file, skipping ogr2ogr export"
    else
        log "Exporting aeroway surface data to FlatGeoBuf format..."
        ogr2ogr -lco SPATIAL_INDEX=NO -t_srs "$PROJECTION" "$fgb_file" \
            "$DB_CONNECTION" \
            rbt.aeroway_surface \
            -skipfailures \
            >> "$OUTPUT_DIR/aeroway_surface_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export aeroway surface data"
            return 1
        fi
        log "Data export completed: $fgb_file"
    fi
    
    log "Generating vector tiles..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/aeroway_surface_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 8 \
        -z 13 \
        --single-precision \
        --extra-detail=13 \
        --no-simplification-of-shared-nodes \
        --drop-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-tiny-polygon-reduction-at-maximum-zoom \
        -T area:float \
        -T osm_id:int \
        -T osm_runway_id:int \
        -n aeroway_surface \
        -l aeroway_surface \
        "$fgb_file" >> "$OUTPUT_DIR/aeroway_surface_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate aeroway surface tiles"
        return 1
    fi
    
    # Airports
    local airports_fgb="$OUTPUT_DIR/airports_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$airports_fgb" ]]; then
        log "FlatGeoBuf file already exists: $airports_fgb, skipping ogr2ogr export"
    else
        log "Exporting airports data to FlatGeoBuf format..."
        ogr2ogr -lco SPATIAL_INDEX=NO -t_srs "$PROJECTION" "$airports_fgb" \
            "$DB_CONNECTION" \
            rbt.airports \
            -skipfailures \
            >> "$OUTPUT_DIR/airports_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export airports data"
            return 1
        fi
        log "Data export completed: $airports_fgb"
    fi
    
    log "Generating vector tiles..."
    tippecanoe -t "$TEMP_DIR" -o "$OUTPUT_DIR/airports_${PROJECTION_CODE}.mbtiles" \
        -P -s EPSG:3857 \
        -Z 5 -z 13 \
        -r 1 \
        --drop-densest-as-needed \
        --single-precision \
        -T airport_id:int \
        -T runway_length_ft:int \
        -T osm_runway_length_ft:int \
        -T runway_width_ft:int \
        -T runway_lighted:int \
        -T runway_closed:int \
        -T runway_le_heading:float \
        -T runway_he_heading:float \
        -T elevation_ft:int \
        -T osm_id_aerodrome:int \
        -T osm_id_runway:int \
        -T osm_aerodrome_area:float \
        -T category:int \
        -T rank:int \
        -n airports \
        -l airports "$airports_fgb" >> "$OUTPUT_DIR/airports_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate airports tiles"
        return 1
    fi
    
    # Heliports
    local heliports_fgb="$OUTPUT_DIR/heliports_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$heliports_fgb" ]]; then
        log "FlatGeoBuf file already exists: $heliports_fgb, skipping ogr2ogr export"
    else
        log "Exporting heliports data to FlatGeoBuf format..."
        ogr2ogr -lco SPATIAL_INDEX=NO -t_srs "$PROJECTION" "$heliports_fgb" \
            "$DB_CONNECTION" \
            rbt.heliports \
            -skipfailures \
            >> "$OUTPUT_DIR/heliports_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export heliports data"
            return 1
        fi
        log "Data export completed: $heliports_fgb"
    fi
    
    log "Generating vector tiles..."
    tippecanoe -t "$TEMP_DIR" -o "$OUTPUT_DIR/heliports_${PROJECTION_CODE}.mbtiles" \
        -P -s EPSG:3857 \
        -Z 5 -z 13 \
        -r 1 \
        --drop-densest-as-needed \
        --single-precision \
        -T rank:int \
        -T elevation_ft:int \
        -n heliports \
        -l heliports "$heliports_fgb" >> "$OUTPUT_DIR/heliports_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate heliports tiles"
        return 1
    fi
    
    # Runway Curve
    local runway_curve_fgb="$OUTPUT_DIR/runway_curve_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$runway_curve_fgb" ]]; then
        log "FlatGeoBuf file already exists: $runway_curve_fgb, skipping ogr2ogr export"
    else
        log "Exporting runway curve data to FlatGeoBuf format..."
        ogr2ogr -lco SPATIAL_INDEX=NO -t_srs "$PROJECTION" "$runway_curve_fgb" \
            "$DB_CONNECTION" \
            rbt.runway_curve \
            -skipfailures \
            >> "$OUTPUT_DIR/runway_curve_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export runway curve data"
            return 1
        fi
        log "Data export completed: $runway_curve_fgb"
    fi
    
    log "Generating vector tiles..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/aeroway_curve_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 8 \
        -z 13 \
        --single-precision \
        --extra-detail=13 \
        --drop-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        -T aerodrome_id:int \
        -T length:int \
        -T osm_id:int \
        -n runway_curve \
        -l runway_curve \
        "$runway_curve_fgb" >> "$OUTPUT_DIR/runway_curve_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate runway curve tiles"
        return 1
    fi
    
    log "Aeroway layers completed."
}

generate_boundary() {
    log "Generating boundary layers..."
    
    # ADM0 Labels
    local adm0_labels_fgb="$OUTPUT_DIR/adm0_labels_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$adm0_labels_fgb" ]]; then
        log "FlatGeoBuf file already exists: $adm0_labels_fgb, skipping ogr2ogr export"
    else
        log "Exporting adm0_labels data to FlatGeoBuf format..."
        ogr2ogr -lco SPATIAL_INDEX=NO -t_srs "$PROJECTION" "$adm0_labels_fgb" \
            "$DB_CONNECTION" \
            rbt.adm0_labels \
            -skipfailures >> "$OUTPUT_DIR/adm0_labels_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export adm0_labels data"
            return 1
        fi
        log "Data export completed: $adm0_labels_fgb"
    fi
    
    log "Generating vector tiles for adm0_labels..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/adm0_labels_${PROJECTION_CODE}.mbtiles" \
        -s EPSG:3857 \
        -P --no-progress-indicator \
        -Z 0 \
        -z 13 \
        -r 1 \
        -pk -pf \
        --single-precision \
        -n adm0_labels \
        -l adm0_labels \
        "$adm0_labels_fgb" >> "$OUTPUT_DIR/adm0_labels_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate adm0_labels tiles"
        return 1
    fi
    
    # ADM0 Lines
    local adm0_lines_fgb="$OUTPUT_DIR/adm0_lines_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$adm0_lines_fgb" ]]; then
        log "FlatGeoBuf file already exists: $adm0_lines_fgb, skipping ogr2ogr export"
    else
        log "Exporting adm0_lines data to FlatGeoBuf format..."
        ogr2ogr -lco SPATIAL_INDEX=NO -t_srs "$PROJECTION" "$adm0_lines_fgb" \
            "$DB_CONNECTION" \
            rbt.adm0_lines \
            -skipfailures >> "$OUTPUT_DIR/adm0_lines_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export adm0_lines data"
            return 1
        fi
        log "Data export completed: $adm0_lines_fgb"
    fi
    
    log "Generating vector tiles for adm0_lines..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/adm0_lines_${PROJECTION_CODE}.mbtiles" \
        -s EPSG:3857 \
        -P --no-progress-indicator \
        -Z 0 \
        -z 13 \
        --drop-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        --single-precision \
        --extra-detail=13 \
        -n adm0_lines \
        -l adm0_lines \
        "$adm0_lines_fgb" >> "$OUTPUT_DIR/adm0_lines_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate adm0_lines tiles"
        return 1
    fi
    
    # ADM1 Labels
    local adm1_labels_fgb="$OUTPUT_DIR/adm1_labels_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$adm1_labels_fgb" ]]; then
        log "FlatGeoBuf file already exists: $adm1_labels_fgb, skipping ogr2ogr export"
    else
        log "Exporting adm1_labels data to FlatGeoBuf format..."
        ogr2ogr -lco SPATIAL_INDEX=NO -t_srs "$PROJECTION" "$adm1_labels_fgb" \
            "$DB_CONNECTION" \
            rbt.adm1_labels \
            -skipfailures >> "$OUTPUT_DIR/adm1_labels_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export adm1_labels data"
            return 1
        fi
        log "Data export completed: $adm1_labels_fgb"
    fi
    
    log "Generating vector tiles for adm1_labels..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/adm1_labels_${PROJECTION_CODE}.mbtiles" \
        -s EPSG:3857 \
        -P --no-progress-indicator \
        -Z 3 \
        -z 13 \
        -r 1 \
        --single-precision \
        -pk \
        -pf \
        -T area:float \
        --single-precision \
        -n adm1_labels \
        -l adm1_labels \
        "$adm1_labels_fgb" >> "$OUTPUT_DIR/adm1_labels_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate adm1_labels tiles"
        return 1
    fi
    
    # ADM1 Lines
    local adm1_lines_fgb="$OUTPUT_DIR/adm1_lines_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$adm1_lines_fgb" ]]; then
        log "FlatGeoBuf file already exists: $adm1_lines_fgb, skipping ogr2ogr export"
    else
        log "Exporting adm1_lines data to FlatGeoBuf format..."
        ogr2ogr -lco SPATIAL_INDEX=NO -t_srs "$PROJECTION" "$adm1_lines_fgb" \
            "$DB_CONNECTION" \
            rbt.adm1_lines \
            -skipfailures >> "$OUTPUT_DIR/adm1_lines_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export adm1_lines data"
            return 1
        fi
        log "Data export completed: $adm1_lines_fgb"
    fi
    
    log "Generating vector tiles for adm1_lines..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/adm1_lines_${PROJECTION_CODE}.mbtiles" \
        -s EPSG:3857 \
        -P --no-progress-indicator \
        -Z 3 \
        -z 13 \
        --drop-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        --single-precision \
        --extra-detail=13 \
        -n adm1_lines \
        -l adm1_lines \
        "$adm1_lines_fgb" >> "$OUTPUT_DIR/adm1_lines_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate adm1_lines tiles"
        return 1
    fi
    
    # ADM2 Labels
    local adm2_labels_fgb="$OUTPUT_DIR/adm2_labels_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$adm2_labels_fgb" ]]; then
        log "FlatGeoBuf file already exists: $adm2_labels_fgb, skipping ogr2ogr export"
    else
        log "Exporting adm2_labels data to FlatGeoBuf format..."
        ogr2ogr -lco SPATIAL_INDEX=NO -t_srs "$PROJECTION" "$adm2_labels_fgb" \
            "$DB_CONNECTION" \
            rbt.adm2_labels \
            -skipfailures >> "$OUTPUT_DIR/adm2_labels_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export adm2_labels data"
            return 1
        fi
        log "Data export completed: $adm2_labels_fgb"
    fi
    
    log "Generating vector tiles for adm2_labels..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/adm2_labels_${PROJECTION_CODE}.mbtiles" \
        -s EPSG:3857 \
        -P --no-progress-indicator \
        -Z 6 \
        -z 13 \
        -r 1 \
        -pk -pf \
        --single-precision \
        -n adm2_labels \
        -l adm2_labels \
        "$adm2_labels_fgb" >> "$OUTPUT_DIR/adm2_labels_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate adm2_labels tiles"
        return 1
    fi
    
    # ADM2 Lines
    local adm2_lines_fgb="$OUTPUT_DIR/adm2_lines_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$adm2_lines_fgb" ]]; then
        log "FlatGeoBuf file already exists: $adm2_lines_fgb, skipping ogr2ogr export"
    else
        log "Exporting adm2_lines data to FlatGeoBuf format..."
        ogr2ogr -lco SPATIAL_INDEX=NO -t_srs "$PROJECTION" "$adm2_lines_fgb" \
            "$DB_CONNECTION" \
            rbt.adm2_lines \
            -skipfailures >> "$OUTPUT_DIR/adm2_lines_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export adm2_lines data"
            return 1
        fi
        log "Data export completed: $adm2_lines_fgb"
    fi
    
    log "Generating vector tiles for adm2_lines..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/adm2_lines_${PROJECTION_CODE}.mbtiles" \
        -s EPSG:3857 \
        -P --no-progress-indicator \
        -Z 6 \
        -z 13 \
        --drop-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        --single-precision \
        --extra-detail=13 \
        -n adm2_lines \
        -l adm2_lines \
        "$adm2_lines_fgb" >> "$OUTPUT_DIR/adm2_lines_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate adm2_lines tiles"
        return 1
    fi
    
    log "Boundary layers completed."
}

generate_building() {
    log "Generating building layer..."
    
    local building_fgb="$OUTPUT_DIR/building_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$building_fgb" ]]; then
        log "FlatGeoBuf file already exists: $building_fgb, skipping ogr2ogr export"
    else
        log "Exporting building data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$building_fgb" \
            "$DB_CONNECTION" \
            rbt.building >> "$OUTPUT_DIR/building_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export building data"
            return 1
        fi
        log "Data export completed: $building_fgb"
    fi
    
    log "Generating vector tiles for building..."
    tippecanoe -j "$BUILDING_FILTER" \
        -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/building_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 10 \
        -z 13 \
        -pk \
        --extra-detail 13 \
        --coalesce-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        --no-tiny-polygon-reduction-at-maximum-zoom \
        --single-precision \
        -T height:float \
        -T area:float \
        -T has_parts:bool \
        -T class:string \
        -T subtype:string \
        -T id:string \
        -n building \
        -l building \
        "$building_fgb" >> "$OUTPUT_DIR/building_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate building tiles"
        return 1
    fi
    
    log "Building layer completed."
}

generate_cemetery() {
    log "Generating cemetery layers..."
    
    # Cemetery polygons
    local cemetery_fgb="$OUTPUT_DIR/cemetery_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$cemetery_fgb" ]]; then
        log "FlatGeoBuf file already exists: $cemetery_fgb, skipping ogr2ogr export"
    else
        log "Exporting cemetery data to FlatGeoBuf format..."
        ogr2ogr -lco SPATIAL_INDEX=NO -t_srs "$PROJECTION" "$cemetery_fgb" \
            "$DB_CONNECTION" \
            rbt.cemetery \
            -skipfailures >> "$OUTPUT_DIR/cemetery_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export cemetery data"
            return 1
        fi
        log "Data export completed: $cemetery_fgb"
    fi
    
    log "Generating vector tiles for cemetery..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/cemetery_${PROJECTION_CODE}.mbtiles" \
        -s EPSG:3857 \
        -P --no-progress-indicator \
        -Z 8 \
        -z 13 \
        --extra-detail 13 \
        --drop-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        --no-tiny-polygon-reduction-at-maximum-zoom \
        --single-precision \
        -n cemetery \
        -l cemetery \
        "$cemetery_fgb" >> "$OUTPUT_DIR/cemetery_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate cemetery tiles"
        return 1
    fi
    
    # Cemetery labels
    local cemetery_label_fgb="$OUTPUT_DIR/cemetery_label_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$cemetery_label_fgb" ]]; then
        log "FlatGeoBuf file already exists: $cemetery_label_fgb, skipping ogr2ogr export"
    else
        log "Exporting cemetery_label data to FlatGeoBuf format..."
        ogr2ogr -lco SPATIAL_INDEX=NO -t_srs "$PROJECTION" "$cemetery_label_fgb" \
            "$DB_CONNECTION" \
            rbt.cemetery_label \
            -skipfailures >> "$OUTPUT_DIR/cemetery_label_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export cemetery_label data"
            return 1
        fi
        log "Data export completed: $cemetery_label_fgb"
    fi
    
    log "Generating vector tiles for cemetery_label..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/cemetery_label_${PROJECTION_CODE}.mbtiles" \
        -s EPSG:3857 \
        -P --no-progress-indicator \
        -Z 8 \
        -z 13 \
        --single-precision \
        -r 1 \
        -pk \
        -pf \
        -n cemetery_label \
        -l cemetery_label \
        "$cemetery_label_fgb" >> "$OUTPUT_DIR/cemetery_label_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate cemetery_label tiles"
        return 1
    fi
    
    log "Cemetery layers completed."
}

generate_geonames() {
    log "Generating geonames layers..."
    
    # Hydrographic
    local geonames_hydrographic_fgb="$OUTPUT_DIR/geonames_hydrographic_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$geonames_hydrographic_fgb" ]]; then
        log "FlatGeoBuf file already exists: $geonames_hydrographic_fgb, skipping ogr2ogr export"
    else
        log "Exporting geonames_hydrographic data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$geonames_hydrographic_fgb" \
            "$DB_CONNECTION" \
            rbt.geonames_hydrographic \
            -skipfailures >> "$OUTPUT_DIR/geonames_hydrographic_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export geonames_hydrographic data"
            return 1
        fi
        log "Data export completed: $geonames_hydrographic_fgb"
    fi
    
    log "Generating vector tiles for geonames_hydrographic..."
    tippecanoe -t "$TEMP_DIR"\
        -j "$HYDROGRAPHIC_FILTER" \
        -o "$OUTPUT_DIR/geonames_hydrographic_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 1 \
        -z 13 \
        --single-precision \
        -r 1 \
        -pk \
        -pf \
        -n geonames_hydrographic \
        -l geonames_hydrographic \
        "$geonames_hydrographic_fgb" >> "$OUTPUT_DIR/geonames_hydrographic_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate geonames_hydrographic tiles"
        return 1
    fi
    
    # Populated Places
    local populated_places_fgb="$OUTPUT_DIR/populated_places_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$populated_places_fgb" ]]; then
        log "FlatGeoBuf file already exists: $populated_places_fgb, skipping ogr2ogr export"
    else
        log "Exporting populated_places data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$populated_places_fgb" \
            "$DB_CONNECTION" \
            rbt.populated_places \
            -skipfailures >> "$OUTPUT_DIR/populated_places_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export populated_places data"
            return 1
        fi
        log "Data export completed: $populated_places_fgb"
    fi
    
    log "Generating vector tiles for populated_places..."
    tippecanoe -t "$TEMP_DIR" \
        -j "$POPULATED_PLACES_FILTER" \
        -o "$OUTPUT_DIR/populated_places_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 3 \
        -z 13 \
        --single-precision \
        -r 1 \
        -pk \
        -pf \
        -n populated_places \
        -l populated_places \
        "$populated_places_fgb" >> "$OUTPUT_DIR/populated_places_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate populated_places tiles"
        return 1
    fi
    
    log "Geonames layers completed."
}

generate_transportation() {
    log "Generating transportation layers..."
    
    # Highway
    local highway_fgb="$OUTPUT_DIR/highway_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$highway_fgb" ]]; then
        log "FlatGeoBuf file already exists: $highway_fgb, skipping ogr2ogr export"
    else
        log "Exporting highway data to FlatGeoBuf format..."
        ogr2ogr -lco SPATIAL_INDEX=NO -t_srs "$PROJECTION" "$highway_fgb" \
            "$DB_CONNECTION" \
            rbt.highway \
            -skipfailures >> "$OUTPUT_DIR/highway_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export highway data"
            return 1
        fi
        log "Data export completed: $highway_fgb"
    fi
    
    log "Generating vector tiles for highway..."
    tippecanoe -t "$TEMP_DIR" \
        -j "$HIGHWAY_FILTER" \
        -o "$OUTPUT_DIR/highway_${PROJECTION_CODE}.mbtiles" \
        -s EPSG:3857 \
        -P --no-progress-indicator \
        -D 11 \
        -Z 6 \
        -z 13 \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        --extra-detail=13 \
        --single-precision \
        -pk -pf \
        -T name_len:int \
        -T ref_len:int \
        -T ref_number_len:int \
        -T lane:int \
        -T geom_len:int \
        -T osm_id:int \
        -n highway \
        -l highway \
        "$highway_fgb" >> "$OUTPUT_DIR/highway_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate highway tiles"
        return 1
    fi
    
    # Railway
    local railway_fgb="$OUTPUT_DIR/railway_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$railway_fgb" ]]; then
        log "FlatGeoBuf file already exists: $railway_fgb, skipping ogr2ogr export"
    else
        log "Exporting railway data to FlatGeoBuf format..."
        ogr2ogr -lco SPATIAL_INDEX=NO -t_srs "$PROJECTION" "$railway_fgb" \
            "$DB_CONNECTION" \
            rbt.railway \
            -skipfailures >> "$OUTPUT_DIR/railway_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export railway data"
            return 1
        fi
        log "Data export completed: $railway_fgb"
    fi
    
    log "Generating vector tiles for railway..."
    tippecanoe -t "$TEMP_DIR" \
        -j "$RAILWAY_FILTER" \
        -o "$OUTPUT_DIR/railway_${PROJECTION_CODE}.mbtiles" \
        -s EPSG:3857 \
        -P --no-progress-indicator \
        -Z 6 \
        -z 13 \
        -pk -pf \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        --single-precision \
        --extra-detail=13 \
        -n railway \
        -l railway "$railway_fgb" >> "$OUTPUT_DIR/railway_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate railway tiles"
        return 1
    fi
    
    # Ferry
    local ferry_fgb="$OUTPUT_DIR/ferry_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$ferry_fgb" ]]; then
        log "FlatGeoBuf file already exists: $ferry_fgb, skipping ogr2ogr export"
    else
        log "Exporting ferry data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$ferry_fgb" \
            "$DB_CONNECTION" \
            rbt.ferry \
            -skipfailures >> "$OUTPUT_DIR/ferry_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export ferry data"
            return 1
        fi
        log "Data export completed: $ferry_fgb"
    fi
    
    log "Generating vector tiles for ferry..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/ferry_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 6 \
        -z 13 \
        --single-precision \
        --extra-detail=13 \
        --drop-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        -n ferry \
        -l ferry \
        "$ferry_fgb" >> "$OUTPUT_DIR/ferry_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate ferry tiles"
        return 1
    fi
    
    # Lock Label
    local lock_label_fgb="$OUTPUT_DIR/lock_label_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$lock_label_fgb" ]]; then
        log "FlatGeoBuf file already exists: $lock_label_fgb, skipping ogr2ogr export"
    else
        log "Exporting lock_label data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$lock_label_fgb" \
            "$DB_CONNECTION" \
            rbt.lock_label \
            -skipfailures >> "$OUTPUT_DIR/lock_label_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export lock_label data"
            return 1
        fi
        log "Data export completed: $lock_label_fgb"
    fi
    
    log "Generating vector tiles for lock_label..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/lock_label_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 8 \
        -z 13 \
        --single-precision \
        -r 1 \
        -pk \
        -pf \
        -n lock_label \
        -l lock_label \
        "$lock_label_fgb" >> "$OUTPUT_DIR/lock_label_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate lock_label tiles"
        return 1
    fi
    
    # Lock
    local lock_fgb="$OUTPUT_DIR/lock_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$lock_fgb" ]]; then
        log "FlatGeoBuf file already exists: $lock_fgb, skipping ogr2ogr export"
    else
        log "Exporting lock data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$lock_fgb" \
            "$DB_CONNECTION" \
            rbt.lock \
            -skipfailures >> "$OUTPUT_DIR/lock_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export lock data"
            return 1
        fi
        log "Data export completed: $lock_fgb"
    fi
    
    log "Generating vector tiles for lock..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/lock_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 8 \
        -z 13 \
        --single-precision \
        --extra-detail=13 \
        --drop-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        -n lock \
        -l lock \
        "$lock_fgb" >> "$OUTPUT_DIR/lock_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate lock tiles"
        return 1
    fi
    
    # Port Label
    local port_label_fgb="$OUTPUT_DIR/port_label_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$port_label_fgb" ]]; then
        log "FlatGeoBuf file already exists: $port_label_fgb, skipping ogr2ogr export"
    else
        log "Exporting port_label data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$port_label_fgb" \
            "$DB_CONNECTION" \
            rbt.port_label \
            -skipfailures >> "$OUTPUT_DIR/port_label_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export port_label data"
            return 1
        fi
        log "Data export completed: $port_label_fgb"
    fi
    
    log "Generating vector tiles for port_label..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/port_label_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 7 \
        -z 13 \
        --single-precision \
        -r 1 \
        -pk \
        -pf \
        -n port_label \
        -l port_label \
        "$port_label_fgb" >> "$OUTPUT_DIR/port_label_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate port_label tiles"
        return 1
    fi
    
    # Port Surface
    local port_surface_fgb="$OUTPUT_DIR/port_surface_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$port_surface_fgb" ]]; then
        log "FlatGeoBuf file already exists: $port_surface_fgb, skipping ogr2ogr export"
    else
        log "Exporting port_surface data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$port_surface_fgb" \
            "$DB_CONNECTION" \
            rbt.port_surface \
            -skipfailures >> "$OUTPUT_DIR/port_surface_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export port_surface data"
            return 1
        fi
        log "Data export completed: $port_surface_fgb"
    fi
    
    log "Generating vector tiles for port_surface..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/port_surface_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 7 \
        -z 13 \
        --single-precision \
        --extra-detail=13 \
        --drop-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        --no-tiny-polygon-reduction-at-maximum-zoom \
        -n port_surface \
        -l port_surface \
        "$port_surface_fgb" >> "$OUTPUT_DIR/port_surface_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate port_surface tiles"
        return 1
    fi
    
    # Railway Station
    local railway_station_fgb="$OUTPUT_DIR/railway_station_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$railway_station_fgb" ]]; then
        log "FlatGeoBuf file already exists: $railway_station_fgb, skipping ogr2ogr export"
    else
        log "Exporting railway_station data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$railway_station_fgb" \
            "$DB_CONNECTION" \
            rbt.railway_station \
            -skipfailures >> "$OUTPUT_DIR/railway_station_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export railway_station data"
            return 1
        fi
        log "Data export completed: $railway_station_fgb"
    fi
    
    log "Generating vector tiles for railway_station..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/railway_station_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 9 \
        -z 13 \
        --single-precision \
        --extra-detail=13 \
        --drop-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        --no-tiny-polygon-reduction-at-maximum-zoom \
        -n railway_station \
        -l railway_station \
        "$railway_station_fgb" >> "$OUTPUT_DIR/railway_station_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate railway_station tiles"
        return 1
    fi
    
    # Railway Station Label
    local railway_station_label_fgb="$OUTPUT_DIR/railway_station_label_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$railway_station_label_fgb" ]]; then
        log "FlatGeoBuf file already exists: $railway_station_label_fgb, skipping ogr2ogr export"
    else
        log "Exporting railway_station_label data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$railway_station_label_fgb" \
            "$DB_CONNECTION" \
            rbt.railway_station_label \
            -skipfailures >> "$OUTPUT_DIR/railway_station_label_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export railway_station_label data"
            return 1
        fi
        log "Data export completed: $railway_station_label_fgb"
    fi
    
    log "Generating vector tiles for railway_station_label..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/railway_station_label_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 9 \
        -z 13 \
        --single-precision \
        -r 1 \
        -pk \
        -pf \
        -n railway_station_label \
        -l railway_station_label \
        "$railway_station_label_fgb" >> "$OUTPUT_DIR/railway_station_label_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate railway_station_label tiles"
        return 1
    fi
    
    # Yard Label
    local yard_label_fgb="$OUTPUT_DIR/yard_label_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$yard_label_fgb" ]]; then
        log "FlatGeoBuf file already exists: $yard_label_fgb, skipping ogr2ogr export"
    else
        log "Exporting yard_label data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$yard_label_fgb" \
            "$DB_CONNECTION" \
            rbt.yard_label \
            -skipfailures >> "$OUTPUT_DIR/yard_label_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export yard_label data"
            return 1
        fi
        log "Data export completed: $yard_label_fgb"
    fi
    
    log "Generating vector tiles for yard_label..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/yard_label_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 11 \
        -z 13 \
        --single-precision \
        -r 1 \
        -pk \
        -pf \
        -n yard_label \
        -l yard_label \
        "$yard_label_fgb" >> "$OUTPUT_DIR/yard_label_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate yard_label tiles"
        return 1
    fi
    
    log "Transportation layers completed."
}

generate_utilities() {
    log "Generating utilities layers..."
    
    # Dam Curve
    local dam_curve_fgb="$OUTPUT_DIR/dam_curve_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$dam_curve_fgb" ]]; then
        log "FlatGeoBuf file already exists: $dam_curve_fgb, skipping ogr2ogr export"
    else
        log "Exporting dam_curve data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$dam_curve_fgb" \
            "$DB_CONNECTION" \
            rbt.dam_curve \
            -skipfailures >> "$OUTPUT_DIR/dam_curve_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export dam_curve data"
            return 1
        fi
        log "Data export completed: $dam_curve_fgb"
    fi
    
    log "Generating vector tiles for dam_curve..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/dam_curve_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 9 \
        -z 13 \
        --single-precision \
        --extra-detail=13 \
        --drop-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        -n dam_curve \
        -l dam_curve \
        "$dam_curve_fgb" >> "$OUTPUT_DIR/dam_curve_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate dam_curve tiles"
        return 1
    fi
    
    # Dam Surface
    local dam_surface_fgb="$OUTPUT_DIR/dam_surface_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$dam_surface_fgb" ]]; then
        log "FlatGeoBuf file already exists: $dam_surface_fgb, skipping ogr2ogr export"
    else
        log "Exporting dam_surface data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$dam_surface_fgb" \
            "$DB_CONNECTION" \
            rbt.dam_surface \
            -skipfailures >> "$OUTPUT_DIR/dam_surface_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export dam_surface data"
            return 1
        fi
        log "Data export completed: $dam_surface_fgb"
    fi
    
    log "Generating vector tiles for dam_surface..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/dam_surface_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 9 \
        -z 13 \
        --single-precision \
        --extra-detail=13 \
        --drop-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        --no-tiny-polygon-reduction-at-maximum-zoom \
        -n dam_surface \
        -l dam_surface \
        "$dam_surface_fgb" >> "$OUTPUT_DIR/dam_surface_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate dam_surface tiles"
        return 1
    fi
    
    # Dam Label
    local dam_label_fgb="$OUTPUT_DIR/dam_label_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$dam_label_fgb" ]]; then
        log "FlatGeoBuf file already exists: $dam_label_fgb, skipping ogr2ogr export"
    else
        log "Exporting dam_label data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$dam_label_fgb" \
            "$DB_CONNECTION" \
            rbt.dam_label \
            -skipfailures >> "$OUTPUT_DIR/dam_label_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export dam_label data"
            return 1
        fi
        log "Data export completed: $dam_label_fgb"
    fi
    
    log "Generating vector tiles for dam_label..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/dam_label_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 9 \
        -z 13 \
        -r 1 \
        --single-precision \
        -pk \
        -pf \
        -n dam_label \
        -l dam_label \
        "$dam_label_fgb" >> "$OUTPUT_DIR/dam_label_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate dam_label tiles"
        return 1
    fi
    
    # Grain Surface
    local grain_srf_fgb="$OUTPUT_DIR/grain_srf_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$grain_srf_fgb" ]]; then
        log "FlatGeoBuf file already exists: $grain_srf_fgb, skipping ogr2ogr export"
    else
        log "Exporting grain_srf data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$grain_srf_fgb" \
            "$DB_CONNECTION" \
            rbt.grain_srf \
            -skipfailures >> "$OUTPUT_DIR/grain_srf_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export grain_srf data"
            return 1
        fi
        log "Data export completed: $grain_srf_fgb"
    fi
    
    log "Generating vector tiles for grain_srf..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/grain_srf_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 9 \
        -z 13 \
        --single-precision \
        --extra-detail=13 \
        --drop-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        --no-tiny-polygon-reduction-at-maximum-zoom \
        -n grain_srf \
        -l grain_srf \
        "$grain_srf_fgb" >> "$OUTPUT_DIR/grain_srf_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate grain_srf tiles"
        return 1
    fi
    
    # Grain Points
    local grain_srf_pnt_fgb="$OUTPUT_DIR/grain_srf_pnt_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$grain_srf_pnt_fgb" ]]; then
        log "FlatGeoBuf file already exists: $grain_srf_pnt_fgb, skipping ogr2ogr export"
    else
        log "Exporting grain_srf_pnt data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$grain_srf_pnt_fgb" \
            "$DB_CONNECTION" \
            rbt.grain_srf_pnt \
            -skipfailures >> "$OUTPUT_DIR/grain_srf_pnt_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export grain_srf_pnt data"
            return 1
        fi
        log "Data export completed: $grain_srf_pnt_fgb"
    fi
    
    log "Generating vector tiles for grain_srf_pnt..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/grain_srf_pnt_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 9 \
        -z 13 \
        --single-precision \
        -r 1 \
        -pk \
        -pf \
        -n grain_srf_pnt \
        -l grain_srf_pnt \
        "$grain_srf_pnt_fgb" >> "$OUTPUT_DIR/grain_srf_pnt_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate grain_srf_pnt tiles"
        return 1
    fi
    
    # Hydrocarbon Field
    local hydrocarbon_field_fgb="$OUTPUT_DIR/hydrocarbon_field_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$hydrocarbon_field_fgb" ]]; then
        log "FlatGeoBuf file already exists: $hydrocarbon_field_fgb, skipping ogr2ogr export"
    else
        log "Exporting hydrocarbon_field data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$hydrocarbon_field_fgb" \
            "$DB_CONNECTION" \
            rbt.hydrocarbon_field \
            -skipfailures >> "$OUTPUT_DIR/hydrocarbon_field_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export hydrocarbon_field data"
            return 1
        fi
        log "Data export completed: $hydrocarbon_field_fgb"
    fi
    
    log "Generating vector tiles for hydrocarbon_field..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/hydrocarbon_field_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 7 \
        -z 13 \
        --single-precision \
        --extra-detail=13 \
        --drop-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        --no-tiny-polygon-reduction-at-maximum-zoom \
        -n hydrocarbon_field \
        -l hydrocarbon_field \
        "$hydrocarbon_field_fgb" >> "$OUTPUT_DIR/hydrocarbon_field_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate hydrocarbon_field tiles"
        return 1
    fi
    
    # Hydrocarbon Label
    local hydrocarbon_label_fgb="$OUTPUT_DIR/hydrocarbon_label_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$hydrocarbon_label_fgb" ]]; then
        log "FlatGeoBuf file already exists: $hydrocarbon_label_fgb, skipping ogr2ogr export"
    else
        log "Exporting hydrocarbon_label data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$hydrocarbon_label_fgb" \
            "$DB_CONNECTION" \
            rbt.hydrocarbon_label \
            -skipfailures >> "$OUTPUT_DIR/hydrocarbon_label_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export hydrocarbon_label data"
            return 1
        fi
        log "Data export completed: $hydrocarbon_label_fgb"
    fi
    
    log "Generating vector tiles for hydrocarbon_label..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/hydrocarbon_label_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 7 \
        -z 13 \
        --single-precision \
        -r 1 \
        -pk \
        -pf \
        -n hydrocarbon_label \
        -l hydrocarbon_label \
        "$hydrocarbon_label_fgb" >> "$OUTPUT_DIR/hydrocarbon_label_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate hydrocarbon_label tiles"
        return 1
    fi
    
    # Powerline
    local powerline_fgb="$OUTPUT_DIR/powerline_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$powerline_fgb" ]]; then
        log "FlatGeoBuf file already exists: $powerline_fgb, skipping ogr2ogr export"
    else
        log "Exporting powerline data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$powerline_fgb" \
            "$DB_CONNECTION" \
            rbt.powerline \
            -skipfailures >> "$OUTPUT_DIR/powerline_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export powerline data"
            return 1
        fi
        log "Data export completed: $powerline_fgb"
    fi
    
    log "Generating vector tiles for powerline..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/powerline_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 9 \
        -z 13 \
        --single-precision \
        --drop-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        -n powerline \
        -l powerline \
        "$powerline_fgb" >> "$OUTPUT_DIR/powerline_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate powerline tiles"
        return 1
    fi
    
    # Pipeline
    local pipeline_fgb="$OUTPUT_DIR/pipeline_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$pipeline_fgb" ]]; then
        log "FlatGeoBuf file already exists: $pipeline_fgb, skipping ogr2ogr export"
    else
        log "Exporting pipeline data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$pipeline_fgb" \
            "$DB_CONNECTION" \
            rbt.pipeline \
            -skipfailures >> "$OUTPUT_DIR/pipeline_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export pipeline data"
            return 1
        fi
        log "Data export completed: $pipeline_fgb"
    fi
    
    log "Generating vector tiles for pipeline..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/pipeline_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 9 \
        -z 13 \
        --single-precision \
        --extra-detail=13 \
        --drop-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        -n pipeline \
        -l pipeline \
        "$pipeline_fgb" >> "$OUTPUT_DIR/pipeline_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate pipeline tiles"
        return 1
    fi
    
    # Utility Point
    local utility_point_fgb="$OUTPUT_DIR/utility_point_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$utility_point_fgb" ]]; then
        log "FlatGeoBuf file already exists: $utility_point_fgb, skipping ogr2ogr export"
    else
        log "Exporting utility_point data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$utility_point_fgb" \
            "$DB_CONNECTION" \
            rbt.utility_point \
            -skipfailures >> "$OUTPUT_DIR/utility_point_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export utility_point data"
            return 1
        fi
        log "Data export completed: $utility_point_fgb"
    fi
    
    log "Generating vector tiles for utility_point..."
    tippecanoe -t "$TEMP_DIR" \
        -j "$UTILITY_FILTER" \
        -o "$OUTPUT_DIR/utility_point_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 9 \
        -z 13 \
        -r 1 \
        --single-precision \
        -pk \
        -pf \
        -n utility_point \
        -l utility_point \
        "$utility_point_fgb" >> "$OUTPUT_DIR/utility_point_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate utility_point tiles"
        return 1
    fi
    
    # Power Station
    local power_station_fgb="$OUTPUT_DIR/power_station_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$power_station_fgb" ]]; then
        log "FlatGeoBuf file already exists: $power_station_fgb, skipping ogr2ogr export"
    else
        log "Exporting power_station data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$power_station_fgb" \
            "$DB_CONNECTION" \
            rbt.power_station \
            -skipfailures >> "$OUTPUT_DIR/power_station_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export power_station data"
            return 1
        fi
        log "Data export completed: $power_station_fgb"
    fi
    
    log "Generating vector tiles for power_station..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/power_station_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 7 \
        -z 13 \
        --single-precision \
        --extra-detail=13 \
        --drop-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        --no-tiny-polygon-reduction-at-maximum-zoom \
        -n power_station \
        -l power_station \
        "$power_station_fgb" >> "$OUTPUT_DIR/power_station_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate power_station tiles"
        return 1
    fi
    
    # Power Station Label
    local power_station_label_fgb="$OUTPUT_DIR/power_station_label_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$power_station_label_fgb" ]]; then
        log "FlatGeoBuf file already exists: $power_station_label_fgb, skipping ogr2ogr export"
    else
        log "Exporting power_station_label data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$power_station_label_fgb" \
            "$DB_CONNECTION" \
            rbt.power_station_label \
            -skipfailures >> "$OUTPUT_DIR/power_station_label_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export power_station_label data"
            return 1
        fi
        log "Data export completed: $power_station_label_fgb"
    fi
    
    log "Generating vector tiles for power_station_label..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/power_station_label_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 7 \
        -z 13 \
        --single-precision \
        -r 1 \
        -pk \
        -pf \
        -n power_station_label \
        -l power_station_label \
        "$power_station_label_fgb" >> "$OUTPUT_DIR/power_station_label_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate power_station_label tiles"
        return 1
    fi
    
    # Pumping Station
    local pumping_station_fgb="$OUTPUT_DIR/pumping_station_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$pumping_station_fgb" ]]; then
        log "FlatGeoBuf file already exists: $pumping_station_fgb, skipping ogr2ogr export"
    else
        log "Exporting pumping_station data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$pumping_station_fgb" \
            "$DB_CONNECTION" \
            rbt.pumping_station \
            -skipfailures >> "$OUTPUT_DIR/pumping_station_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export pumping_station data"
            return 1
        fi
        log "Data export completed: $pumping_station_fgb"
    fi
    
    log "Generating vector tiles for pumping_station..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/pumping_station_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 8 \
        -z 13 \
        --single-precision \
        --extra-detail=13 \
        --drop-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        --no-tiny-polygon-reduction-at-maximum-zoom \
        -n pumping_station \
        -l pumping_station \
        "$pumping_station_fgb" >> "$OUTPUT_DIR/pumping_station_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate pumping_station tiles"
        return 1
    fi
    
    # Pumping Station Label
    local pumping_station_label_fgb="$OUTPUT_DIR/pumping_station_label_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$pumping_station_label_fgb" ]]; then
        log "FlatGeoBuf file already exists: $pumping_station_label_fgb, skipping ogr2ogr export"
    else
        log "Exporting pumping_station_label data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$pumping_station_label_fgb" \
            "$DB_CONNECTION" \
            rbt.pumping_station_label \
            -skipfailures >> "$OUTPUT_DIR/pumping_station_label_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export pumping_station_label data"
            return 1
        fi
        log "Data export completed: $pumping_station_label_fgb"
    fi
    
    log "Generating vector tiles for pumping_station_label..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/pumping_station_label_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 8 \
        -z 13 \
        --single-precision \
        -r 1 \
        -pk \
        -pf \
        -n pumping_station_label \
        -l pumping_station_label \
        "$pumping_station_label_fgb" >> "$OUTPUT_DIR/pumping_station_label_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate pumping_station_label tiles"
        return 1
    fi
    
    log "Utilities layers completed."
}

generate_other() {
    log "Generating other cultural layers..."
    
    # Stadium Surface
    local stadium_surface_fgb="$OUTPUT_DIR/stadium_surface_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$stadium_surface_fgb" ]]; then
        log "FlatGeoBuf file already exists: $stadium_surface_fgb, skipping ogr2ogr export"
    else
        log "Exporting stadium_surface data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$stadium_surface_fgb" \
            "$DB_CONNECTION" \
            rbt.stadium_surface \
            -skipfailures >> "$OUTPUT_DIR/stadium_surface_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export stadium_surface data"
            return 1
        fi
        log "Data export completed: $stadium_surface_fgb"
    fi
    
    log "Generating vector tiles for stadium_surface..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/stadium_surface_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 10 \
        -z 13 \
        --single-precision \
        --extra-detail=13 \
        --drop-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        --no-tiny-polygon-reduction-at-maximum-zoom \
        -n stadium_surface \
        -l stadium_surface \
        "$stadium_surface_fgb" >> "$OUTPUT_DIR/stadium_surface_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate stadium_surface tiles"
        return 1
    fi
    
    # Stadium Labels
    local stadium_labels_fgb="$OUTPUT_DIR/stadium_labels_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$stadium_labels_fgb" ]]; then
        log "FlatGeoBuf file already exists: $stadium_labels_fgb, skipping ogr2ogr export"
    else
        log "Exporting stadium_labels data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$stadium_labels_fgb" \
            "$DB_CONNECTION" \
            rbt.stadium_labels \
            -skipfailures >> "$OUTPUT_DIR/stadium_labels_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export stadium_labels data"
            return 1
        fi
        log "Data export completed: $stadium_labels_fgb"
    fi
    
    log "Generating vector tiles for stadium_labels..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/stadium_labels_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 10 \
        -z 13 \
        --single-precision \
        -r 1 \
        -pk \
        -pf \
        -n stadium_labels \
        -l stadium_labels \
        "$stadium_labels_fgb" >> "$OUTPUT_DIR/stadium_labels_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate stadium_labels tiles"
        return 1
    fi
    
    # US Military Installations
    local us_military_installations_fgb="$OUTPUT_DIR/us_military_installations_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$us_military_installations_fgb" ]]; then
        log "FlatGeoBuf file already exists: $us_military_installations_fgb, skipping ogr2ogr export"
    else
        log "Exporting us_military_installations data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$us_military_installations_fgb" \
            "$DB_CONNECTION" \
            rbt.us_military_installations \
            -skipfailures >> "$OUTPUT_DIR/us_military_installations_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export us_military_installations data"
            return 1
        fi
        log "Data export completed: $us_military_installations_fgb"
    fi
    
    log "Generating vector tiles for us_military_installations..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/us_military_installations_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 5 \
        -z 13 \
        --single-precision \
        --extra-detail=13 \
        --drop-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        --no-tiny-polygon-reduction-at-maximum-zoom \
        -n us_military_installations \
        -l us_military_installations \
        "$us_military_installations_fgb" >> "$OUTPUT_DIR/us_military_installations_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate us_military_installations tiles"
        return 1
    fi
    
    # US Military Installations Labels
    local us_military_installations_labels_fgb="$OUTPUT_DIR/us_military_installations_labels_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$us_military_installations_labels_fgb" ]]; then
        log "FlatGeoBuf file already exists: $us_military_installations_labels_fgb, skipping ogr2ogr export"
    else
        log "Exporting us_military_installations_labels data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$us_military_installations_labels_fgb" \
            "$DB_CONNECTION" \
            rbt.us_military_installations_labels \
            -skipfailures >> "$OUTPUT_DIR/us_military_installations_labels_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export us_military_installations_labels data"
            return 1
        fi
        log "Data export completed: $us_military_installations_labels_fgb"
    fi
    
    log "Generating vector tiles for us_military_installations_labels..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/us_military_installations_labels_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 5 \
        -z 13 \
        --single-precision \
        -r 1 \
        -pk \
        -pf \
        -n us_military_installations_labels \
        -l us_military_installations_labels \
        "$us_military_installations_labels_fgb" >> "$OUTPUT_DIR/us_military_installations_labels_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate us_military_installations_labels tiles"
        return 1
    fi
    
    # Radar Point
    local radar_point_fgb="$OUTPUT_DIR/radar_point_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$radar_point_fgb" ]]; then
        log "FlatGeoBuf file already exists: $radar_point_fgb, skipping ogr2ogr export"
    else
        log "Exporting radar_point data to FlatGeoBuf format..."
        ogr2ogr -t_srs "$PROJECTION" "$radar_point_fgb" \
            "$DB_CONNECTION" \
            rbt.radar_point \
            -skipfailures >> "$OUTPUT_DIR/radar_point_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export radar_point data"
            return 1
        fi
        log "Data export completed: $radar_point_fgb"
    fi
    
    log "Generating vector tiles for radar_point..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/radar_point_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 8 \
        -z 13 \
        --single-precision \
        -r 1 \
        -pk \
        -pf \
        -n radar_point \
        -l radar_point \
        "$radar_point_fgb" >> "$OUTPUT_DIR/radar_point_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate radar_point tiles"
        return 1
    fi
    
    log "Other cultural layers completed."
}

merge_all_layers() {
    log "Merging all cultural layers into consolidated mbtiles file..."
    
    # Check if tile-join is available
    if ! command -v tile-join &> /dev/null; then
        log "ERROR: tile-join not found. Please install tippecanoe with tile-join support."
        exit 1
    fi
    
    # Collect all generated mbtiles files
    local mbtiles_files=()
    local expected_files=(
        "aeroway_surface_${PROJECTION_CODE}.mbtiles"
        "airports_${PROJECTION_CODE}.mbtiles"
        "heliports_${PROJECTION_CODE}.mbtiles"
        "aeroway_curve_${PROJECTION_CODE}.mbtiles"
        "adm0_labels_${PROJECTION_CODE}.mbtiles"
        "adm0_lines_${PROJECTION_CODE}.mbtiles"
        "adm1_labels_${PROJECTION_CODE}.mbtiles"
        "adm1_lines_${PROJECTION_CODE}.mbtiles"
        "adm2_labels_${PROJECTION_CODE}.mbtiles"
        "adm2_lines_${PROJECTION_CODE}.mbtiles"
        "building_${PROJECTION_CODE}.mbtiles"
        "cemetery_${PROJECTION_CODE}.mbtiles"
        "cemetery_label_${PROJECTION_CODE}.mbtiles"
        "geonames_hydrographic_${PROJECTION_CODE}.mbtiles"
        "populated_places_${PROJECTION_CODE}.mbtiles"
        "highway_${PROJECTION_CODE}.mbtiles"
        "railway_${PROJECTION_CODE}.mbtiles"
        "ferry_${PROJECTION_CODE}.mbtiles"
        "lock_label_${PROJECTION_CODE}.mbtiles"
        "lock_${PROJECTION_CODE}.mbtiles"
        "port_label_${PROJECTION_CODE}.mbtiles"
        "port_surface_${PROJECTION_CODE}.mbtiles"
        "railway_station_${PROJECTION_CODE}.mbtiles"
        "railway_station_label_${PROJECTION_CODE}.mbtiles"
        "yard_label_${PROJECTION_CODE}.mbtiles"
        "dam_curve_${PROJECTION_CODE}.mbtiles"
        "dam_surface_${PROJECTION_CODE}.mbtiles"
        "dam_label_${PROJECTION_CODE}.mbtiles"
        "grain_srf_${PROJECTION_CODE}.mbtiles"
        "grain_srf_pnt_${PROJECTION_CODE}.mbtiles"
        "hydrocarbon_field_${PROJECTION_CODE}.mbtiles"
        "hydrocarbon_label_${PROJECTION_CODE}.mbtiles"
        "powerline_${PROJECTION_CODE}.mbtiles"
        "pipeline_${PROJECTION_CODE}.mbtiles"
        "utility_point_${PROJECTION_CODE}.mbtiles"
        "power_station_${PROJECTION_CODE}.mbtiles"
        "power_station_label_${PROJECTION_CODE}.mbtiles"
        "pumping_station_${PROJECTION_CODE}.mbtiles"
        "pumping_station_label_${PROJECTION_CODE}.mbtiles"
        "stadium_surface_${PROJECTION_CODE}.mbtiles"
        "stadium_labels_${PROJECTION_CODE}.mbtiles"
        "us_military_installations_${PROJECTION_CODE}.mbtiles"
        "us_military_installations_labels_${PROJECTION_CODE}.mbtiles"
        "radar_point_${PROJECTION_CODE}.mbtiles"
    )
    
    # Check which files exist and add them to the merge list
    for file in "${expected_files[@]}"; do
        if [[ -f "$OUTPUT_DIR/$file" ]]; then
            mbtiles_files+=("$OUTPUT_DIR/$file")
            log "Found layer: $file"
        else
            log "WARNING: Expected layer file not found: $file"
        fi
    done
    
    if [[ ${#mbtiles_files[@]} -eq 0 ]]; then
        log "ERROR: No mbtiles files found to merge"
        return 1
    fi
    
    # Perform the merge using tile-join
    local merged_file="$OUTPUT_DIR/cultural_${PROJECTION_CODE}.mbtiles"
    log "Merging ${#mbtiles_files[@]} layer files into: $(basename "$merged_file")"
    
    tile-join -f -pk \
        -o "$merged_file" \
        "${mbtiles_files[@]}" \
        >> "$OUTPUT_DIR/merge_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -eq 0 ]]; then
        log "Successfully merged all layers into: $(basename "$merged_file")"
        
        # Display merge statistics
        if [[ -f "$merged_file" ]]; then
            local merged_size=$(du -sh "$merged_file" 2>/dev/null | cut -f1)
            log "Merged file size: $merged_size"
        fi
    else
        log "ERROR: Failed to merge layers. Check $OUTPUT_DIR/merge_${PROJECTION_CODE}.log for details."
        return 1
    fi
}

add_btis_metadata() {
    local target_file="${1:-$OUTPUT_DIR/cultural_${PROJECTION_CODE}.mbtiles}"
    log "Adding BTIS metadata to MBTiles file: $(basename "$target_file")..."
    
    # Check if the target file exists
    if [[ ! -f "$target_file" ]]; then
        log "ERROR: MBTiles file not found: $target_file"
        return 1
    fi
    
    # Check if sqlite3 is available
    if ! command -v sqlite3 &> /dev/null; then
        log "ERROR: sqlite3 not found. Please install SQLite."
        return 1
    fi
    
    # Add projection-specific metadata
    log "Adding CRS metadata (EPSG:${PROJECTION_CODE})..."
    sqlite3 "$target_file" "INSERT OR REPLACE INTO metadata(name,value) VALUES('crs','EPSG:${PROJECTION_CODE}');" && \
    
    log "Adding tile origin metadata..."
    sqlite3 "$target_file" "INSERT OR REPLACE INTO metadata(name,value) VALUES('tile_origin_upper_left_x','-20037508.343');" && \
    sqlite3 "$target_file" "INSERT OR REPLACE INTO metadata(name,value) VALUES('tile_origin_upper_left_y','20037508.343');" && \
    
    log "Adding tile dimension metadata..."
    sqlite3 "$target_file" "INSERT OR REPLACE INTO metadata(name,value) VALUES('tile_dimension_zoom_0','40075016.686');" && \
    
    log "Adding BTP schema version ($BTP_SCHEMA_VERSION)..."
    sqlite3 "$target_file" "INSERT OR REPLACE INTO metadata(name,value) VALUES('btp_schema_version','$BTP_SCHEMA_VERSION');" && \
    
    log "Adding changelog URL..."
    sqlite3 "$target_file" "INSERT OR REPLACE INTO metadata(name,value) VALUES('changelog_url','');" && \
    
    log "Cleaning up tippecanoe metadata..."
    sqlite3 "$target_file" "DELETE FROM metadata WHERE name = 'generator_options';" && \
    sqlite3 "$target_file" "DELETE FROM metadata WHERE name = 'strategies';"
    
    if [[ $? -eq 0 ]]; then
        log "Successfully added BTIS metadata to $(basename "$target_file")"
        
        # Display metadata summary
        log "Metadata entries added:"
        log "  - CRS: EPSG:${PROJECTION_CODE}"
        log "  - Tile origin: (${TILE_ORIGIN_X}, ${TILE_ORIGIN_Y})"
        log "  - Tile dimension (zoom 0): ${TILE_DIMENSION}"
        log "  - BTP schema version: 1.0.0"
        log "  - Removed tippecanoe generator metadata"
    else
        log "ERROR: Failed to add BTIS metadata. Check SQLite operations."
        return 1
    fi
}

# =============================================================================
# Summary and Statistics
# =============================================================================

display_summary() {
    log "=== Generation Summary ==="
    log "Output directory: $OUTPUT_DIR"
    log "Projection used: $PROJECTION"
    
    if [[ -d "$OUTPUT_DIR" ]]; then
        local merged_mbtiles_path="$OUTPUT_DIR/cultural_${PROJECTION_CODE}.mbtiles"
        local fgb_count=$(find "$OUTPUT_DIR" -name "*.fgb" 2>/dev/null | wc -l)
        local dir_size=$(du -sh "$OUTPUT_DIR" 2>/dev/null | cut -f1)
        
        if [[ -f "$merged_mbtiles_path" ]]; then
            local merged_size=$(du -sh "$merged_mbtiles_path" 2>/dev/null | cut -f1)
            log "Consolidated file: cultural_${PROJECTION_CODE}.mbtiles ($merged_size)"
        else
            log "Merged MBTiles file not found."
        fi
        
        log "FGB intermediate files: $fgb_count"
        log "Output directory size: $dir_size"
        
        # Show layer categories
        log "Cultural layer categories:"
        log "  - Aeroway: aeroway_surface, airports, heliports, runway_curve"
        log "  - Boundary: adm0_labels/lines, adm1_labels/lines, adm2_labels/lines"
        log "  - Building: building"
        log "  - Cemetery: cemetery, cemetery_label"
        log "  - Geonames: hydrographic, populated_places"
        log "  - Transportation: highway, railway, ferry, lock, port, station, yard"
        log "  - Utilities: dam, grain, hydrocarbon, powerline, pipeline, utility_point, stations"
        log "  - Other: stadium, military, radar"
    fi
    
    log "=========================="
}

# =============================================================================
# Main Execution
# =============================================================================

count_selected_layers() {
    local count=0
    [[ "$RUN_AEROWAY" == "true" ]] && ((count++))
    [[ "$RUN_BOUNDARY" == "true" ]] && ((count++))
    [[ "$RUN_BUILDING" == "true" ]] && ((count++))
    [[ "$RUN_CEMETERY" == "true" ]] && ((count++))
    [[ "$RUN_GEONAMES" == "true" ]] && ((count++))
    [[ "$RUN_TRANSPORTATION" == "true" ]] && ((count++))
    [[ "$RUN_UTILITIES" == "true" ]] && ((count++))
    [[ "$RUN_OTHER" == "true" ]] && ((count++))
    echo $count
}

main() {
    # Parse command line arguments first
    parse_arguments "$@"
    
    # Configure projection settings
    configure_projection
    
    log "Starting unified cultural MVT generation..."
    log "Script: $0"
    log "Working directory: $(pwd)"
    log "Projection: $PROJECTION"
    
    # Show which layers will be generated
    local selected_count=$(count_selected_layers)
    if [[ "$RUN_ALL" == "true" ]]; then
        log "Mode: Generate all cultural layers"
    else
        log "Mode: Generate selected layers ($selected_count layers)"
        [[ "$RUN_AEROWAY" == "true" ]] && log "  - aeroway (surface, airports, heliports, curves)"
        [[ "$RUN_BOUNDARY" == "true" ]] && log "  - boundary (adm0/adm1/adm2 labels and lines)"
        [[ "$RUN_BUILDING" == "true" ]] && log "  - building"
        [[ "$RUN_CEMETERY" == "true" ]] && log "  - cemetery (polygons and labels)"
        [[ "$RUN_GEONAMES" == "true" ]] && log "  - geonames (hydrographic, populated places)"
        [[ "$RUN_TRANSPORTATION" == "true" ]] && log "  - transportation (highway, railway, ferry, ports, stations)"
        [[ "$RUN_UTILITIES" == "true" ]] && log "  - utilities (dam, grain, hydrocarbon, powerline, pipeline)"
        [[ "$RUN_OTHER" == "true" ]] && log "  - other (stadium, military, radar)"
    fi
    
    # Pre-flight checks
    check_prerequisites
    test_database_connection
    
    # Setup
    setup_output
    
    # Generate selected layers
    log "Generating selected cultural layers..."
    
    [[ "$RUN_AEROWAY" == "true" ]] && generate_aeroway
    [[ "$RUN_BOUNDARY" == "true" ]] && generate_boundary
    [[ "$RUN_BUILDING" == "true" ]] && generate_building
    [[ "$RUN_CEMETERY" == "true" ]] && generate_cemetery
    [[ "$RUN_GEONAMES" == "true" ]] && generate_geonames
    [[ "$RUN_TRANSPORTATION" == "true" ]] && generate_transportation
    [[ "$RUN_UTILITIES" == "true" ]] && generate_utilities
    [[ "$RUN_OTHER" == "true" ]] && generate_other
    
    # Handle tile joining and BTIS metadata based on flags
    if [[ $selected_count -gt 1 ]]; then
        if [[ "$TILE_JOIN" == "true" ]]; then
            log "Multiple layers generated - creating consolidated MBTiles file..."
            merge_all_layers
            if [[ "$ADD_BTIS" == "true" ]]; then
                add_btis_metadata
            fi
        else
            log "Multiple layers generated - individual files created (use --tile-join to consolidate)"
        fi
    elif [[ $selected_count -eq 1 ]]; then
        log "Single layer generated"
        if [[ "$ADD_BTIS" == "true" ]]; then
            # For single layer, find the generated mbtiles file and add metadata directly to it
            local single_mbtiles=$(find "$OUTPUT_DIR" -name "*.mbtiles" -not -name "cultural_${PROJECTION_CODE}.mbtiles" | head -1)
            if [[ -f "$single_mbtiles" ]]; then
                add_btis_metadata "$single_mbtiles"
            else
                log "WARNING: Could not find generated MBTiles file for BTIS metadata"
            fi
        fi
    else
        log "ERROR: No layers were selected for generation"
        show_help
        exit 1
    fi
    
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
