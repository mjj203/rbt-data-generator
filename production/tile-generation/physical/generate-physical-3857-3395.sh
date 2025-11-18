#!/bin/bash

# =============================================================================
# Unified Physical Vector Tiles Generation Script
# =============================================================================
# 
# This script generates Mapbox Vector Tiles (MBTiles) for all physical layers
# using tippecanoe with configurable projection support (EPSG:3857, EPSG:3395).
#
# Consolidates all individual layer tiles.sh scripts into a single workflow:
# - Exports data from PostgreSQL to FlatGeoBuf format  
# - Applies layer-specific tippecanoe filters and configurations
# - Outputs individual MBTiles files for each physical layer
#
# Prerequisites:
# - PostgreSQL database with 'rbt' schema containing all physical layers
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
RUN_BUILTUPAREA=false
RUN_CONTOUR=false
RUN_GLACIER=false
RUN_LANDCOVER=false
RUN_MOUNTAIN=false
RUN_PARK=false
RUN_WATER=false
RUN_WATER_LABEL=false
RUN_WATERWAY=false
RUN_INLAND_WATER_INTERMITTENT=false
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
            OUTPUT_DIR="physical_tiles_3857"
            TILE_ORIGIN_X="-20037508.343"
            TILE_ORIGIN_Y="20037508.343"
            TILE_DIMENSION="40075016.686"
            ;;
        3395)
            PROJECTION="EPSG:3395"
            OUTPUT_DIR="physical_tiles_3395"
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

# Built-up area filter: switches between Natural Earth (low zoom) and OSM (high zoom)
BUILTUP_FILTER='{"*":["any",["all",["<=","$zoom",8],["==","class","ne"]],["all",[">=","$zoom",8],["==","class","osm"]]]}'

# Contour filter: progressive line display based on zoom level
CONTOUR_FILTER='{"*":["any",["all",[">=","$zoom",8],["==","nth_line",10]],["all",[">=","$zoom",10],["in","nth_line",5,10]],["all",[">=","$zoom",12],["in","nth_line",5,10,2]],["all",[">=","$zoom",13]]]}'

# Glacier filter: switches between Natural Earth (low zoom) and OSM (high zoom)
GLACIER_FILTER='{"*":["any",["all",["<=","$zoom",7],["==","source","ne"]],["all",[">=","$zoom",7],["==","source","osm"]]]}'

# Landcover filter: progressive feature display based on zoom and area
LANDCOVER_FILTER='{"*":["any",["all",[">=","$zoom",4],[">=","area",15625000],["in","subclass","sand","dune","dune_system","beach"]],["all",[">=","$zoom",6],[">=","area",15625000],["in","subclass","sand","dune","dune_system","beach","bog","mangrove","marsh","reedbed","rice","saltmarsh","swamp","unknown_wetland","wetland","paddy","wet_meadow"]],["all",[">=","$zoom",9],["in","subclass","sand","dune","dune_system","beach","bog","mangrove","marsh","reedbed","rice","paddy","saltmarsh","swamp","unknown_wetland","wetland","wet_meadow"]],["all",[">=","$zoom",10],["in","subclass","sand","dune","dune_system","beach","bog","mangrove","marsh","reedbed","rice","saltmarsh","swamp","unknown_wetland","wetland","wet_meadow","meadow","grassland","forest","wood","tundra","reef","scrub","heath","farm","farmland","orchard","paddy","vineyard"]],["all",[">=","$zoom",12]]]}'

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
    
    # Check if ogr2ogr -lco SPATIAL_INDEX=NO is available
    if ! command -v ogr2ogr -lco SPATIAL_INDEX=NO &> /dev/null; then
        log "ERROR: ogr2ogr -lco SPATIAL_INDEX=NO not found. Please install GDAL."
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
Unified Physical Vector Tiles Generation Script

Usage: $0 [OPTIONS]

Generate Mapbox Vector Tiles for physical layers with configurable projection support.

OPTIONS:
    --projection <code>      Set projection (3857 or 3395). Default: 3857
    --temp-dir <path>        Temp directory for tippecanoe processing. Default: /mnt/data
    --all                    Generate all physical layers (default behavior)
    --builtuparea            Generate builtuparea layer only
    --contour                Generate contour layers (regular and glacier contours)
    --glacier                Generate glacier layer only  
    --landcover              Generate landcover layers (polygons and labels)
    --mountain               Generate mountain label layer only
    --park                   Generate park layer only
    --water                  Generate water layer only
    --water-label            Generate water label layer only
    --waterway               Generate waterway layer only
    --inland-water           Generate inland water intermittent layer only
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
    $0 --temp-dir /mnt/fast-storage --water --landcover
    
    # Generate all layers with tile joining and BTIS metadata
    $0 --all --tile-join --add-btis
    
    # Generate single layer in specific projection
    $0 --projection 3395 --builtuparea
    $0 --projection 3857 --water --add-btis
    
    # Generate multiple specific layers with joining
    $0 --water --waterway --landcover --tile-join
    
    # Generate terrain-related layers with full processing
    $0 --contour --glacier --mountain --tile-join --add-btis

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
            --builtuparea)
                RUN_BUILTUPAREA=true
                shift
                ;;
            --contour)
                RUN_CONTOUR=true
                shift
                ;;
            --glacier)
                RUN_GLACIER=true
                shift
                ;;
            --landcover)
                RUN_LANDCOVER=true
                shift
                ;;
            --mountain)
                RUN_MOUNTAIN=true
                shift
                ;;
            --park)
                RUN_PARK=true
                shift
                ;;
            --water)
                RUN_WATER=true
                shift
                ;;
            --water-label)
                RUN_WATER_LABEL=true
                shift
                ;;
            --waterway)
                RUN_WATERWAY=true
                shift
                ;;
            --inland-water)
                RUN_INLAND_WATER_INTERMITTENT=true
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
        RUN_BUILTUPAREA=true
        RUN_CONTOUR=true
        RUN_GLACIER=true
        RUN_LANDCOVER=true
        RUN_MOUNTAIN=true
        RUN_PARK=true
        RUN_WATER=true
        RUN_WATER_LABEL=true
        RUN_WATERWAY=true
        RUN_INLAND_WATER_INTERMITTENT=true
    fi
}

setup_output() {
    log "Setting up output directory..."
    
    mkdir -p "$OUTPUT_DIR"
    log "Output directory ready: $OUTPUT_DIR"
}

# =============================================================================
# Layer Generation Functions
# =============================================================================

generate_builtuparea() {
    log "Generating builtuparea layer..."
    
    local geojson_file="$OUTPUT_DIR/builtuparea_${PROJECTION_CODE}.geojson"
    local ndjson_file="$OUTPUT_DIR/builtuparea_${PROJECTION_CODE}.ndjson"
    
    # Check if NDJSON file exists (final processed file)
    if [[ -f "$ndjson_file" ]]; then
        log "NDJSON file already exists: $ndjson_file, skipping data export and conversion"
    else
        # Check if GeoJSON file exists
        if [[ -f "$geojson_file" ]]; then
            log "GeoJSON file already exists: $geojson_file, skipping ogr2ogr export"
        else
            log "Exporting data to GeoJSON format..."
            ogr2ogr -f "GeoJSON" -t_srs "$PROJECTION" "$geojson_file" \
                "$DB_CONNECTION" \
                rbt.builtuparea \
                -skipfailures \
                >> "$OUTPUT_DIR/builtuparea_${PROJECTION_CODE}.log" 2>&1
            
            if [[ $? -ne 0 ]]; then
                log "ERROR: Failed to export builtuparea data to GeoJSON"
                return 1
            fi
            log "Data export completed: $geojson_file"
        fi
        
        # Convert GeoJSON to NDJSON
        log "Converting GeoJSON to NDJSON format..."
        tippecanoe-json-tool "$geojson_file" > "$ndjson_file" 2>> "$OUTPUT_DIR/builtuparea_${PROJECTION_CODE}.log"
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to convert GeoJSON to NDJSON"
            return 1
        fi
        log "NDJSON conversion completed: $ndjson_file"
    fi
    
    log "Generating vector tiles..."
    tippecanoe -t "$TEMP_DIR" -j "$BUILTUP_FILTER" \
        -o "$OUTPUT_DIR/builtuparea_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 3 \
        -z 13 \
        --single-precision \
        --extra-detail=13 \
        -pk \
        -pf \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        --no-tiny-polygon-reduction-at-maximum-zoom \
        -n builtuparea \
        -l builtuparea \
        "$ndjson_file" >> "$OUTPUT_DIR/builtuparea_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate builtuparea tiles"
        return 1
    fi
    
    log "Builtuparea layer completed."
}

generate_contour() {
    log "Generating contour layers..."
    
    # Regular contours
    local contour_fgb="$OUTPUT_DIR/contour_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$contour_fgb" ]]; then
        log "FlatGeoBuf file already exists: $contour_fgb, skipping ogr2ogr -lco SPATIAL_INDEX=NO export"
    else
        log "Exporting regular contour data to FlatGeoBuf format..."
        ogr2ogr -lco SPATIAL_INDEX=NO -t_srs "$PROJECTION" "$contour_fgb" \
            "$DB_CONNECTION" \
            rbt.contour \
            -skipfailures \
            >> "$OUTPUT_DIR/contour_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export contour data"
            return 1
        fi
        log "Data export completed: $contour_fgb"
    fi
    
    log "Generating regular contour tiles..."
    tippecanoe -t "$TEMP_DIR" -j "$CONTOUR_FILTER" \
        -o "$OUTPUT_DIR/contour_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 8 \
        -z 13 \
        -pk \
        -pf \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        -T elevation:int \
        -T negative:int \
        -T nth_line:int \
        -n contour \
        -l contour \
        "$contour_fgb" >> "$OUTPUT_DIR/contour_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate contour tiles"
        return 1
    fi
    
    # Glacier contours
    local glacier_contour_fgb="$OUTPUT_DIR/contour_glacier_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$glacier_contour_fgb" ]]; then
        log "FlatGeoBuf file already exists: $glacier_contour_fgb, skipping ogr2ogr -lco SPATIAL_INDEX=NO export"
    else
        log "Exporting glacier contour data to FlatGeoBuf format..."
        ogr2ogr -lco SPATIAL_INDEX=NO -t_srs "$PROJECTION" "$glacier_contour_fgb" \
            "$DB_CONNECTION" \
            rbt.contour_glacier \
            -skipfailures \
            >> "$OUTPUT_DIR/contour_glacier_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export glacier contour data"
            return 1
        fi
        log "Data export completed: $glacier_contour_fgb"
    fi
    
    log "Generating glacier contour tiles..."
    tippecanoe -t "$TEMP_DIR" -j "$CONTOUR_FILTER" \
        -o "$OUTPUT_DIR/contour_glacier_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 8 \
        -z 13 \
        --single-precision \
        --extra-detail=13 \
        -pk \
        -pf \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        -T elevation:int \
        -T negative:int \
        -T nth_line:int \
        -n contour_glacier \
        -l contour_glacier \
        "$glacier_contour_fgb" >> "$OUTPUT_DIR/contour_glacier_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate glacier contour tiles"
        return 1
    fi
    
    log "Contour layers completed."
}

generate_glacier() {
    log "Generating glacier layer..."
    
    local fgb_file="$OUTPUT_DIR/glacier_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$fgb_file" ]]; then
        log "FlatGeoBuf file already exists: $fgb_file, skipping ogr2ogr -lco SPATIAL_INDEX=NO export"
    else
        log "Exporting data to FlatGeoBuf format..."
        ogr2ogr -lco SPATIAL_INDEX=NO -t_srs "$PROJECTION" "$fgb_file" \
            "$DB_CONNECTION" \
            rbt.glacier \
            -skipfailures \
            >> "$OUTPUT_DIR/glacier_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export glacier data"
            return 1
        fi
        log "Data export completed: $fgb_file"
    fi
    
    log "Generating vector tiles..."
    tippecanoe -t "$TEMP_DIR" -j "$GLACIER_FILTER" \
        -o "$OUTPUT_DIR/glacier_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -z 13 \
        --single-precision \
        --extra-detail=13 \
        -pk \
        -pf \
        --detect-longitude-wraparound \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        --no-tiny-polygon-reduction-at-maximum-zoom \
        -n glacier \
        -l glacier \
        "$fgb_file" >> "$OUTPUT_DIR/glacier_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate glacier tiles"
        return 1
    fi
    
    log "Glacier layer completed."
}

generate_landcover() {
    log "Generating landcover layers..."
    
    # Landcover polygons
    local landcover_fgb="$OUTPUT_DIR/landcover_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$landcover_fgb" ]]; then
        log "FlatGeoBuf file already exists: $landcover_fgb, skipping ogr2ogr -lco SPATIAL_INDEX=NO export"
    else
        log "Exporting landcover polygon data to FlatGeoBuf format..."
        ogr2ogr -lco SPATIAL_INDEX=NO -t_srs "$PROJECTION" \
            "$landcover_fgb" \
            "$DB_CONNECTION" \
            rbt.landcover \
            -skipfailures \
            >> "$OUTPUT_DIR/landcover_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export landcover data"
            return 1
        fi
        log "Data export completed: $landcover_fgb"
    fi
    
    # Landcover labels (named features only)
    local landcover_label_fgb="$OUTPUT_DIR/landcover_label_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$landcover_label_fgb" ]]; then
        log "FlatGeoBuf file already exists: $landcover_label_fgb, skipping ogr2ogr -lco SPATIAL_INDEX=NO export"
    else
        log "Exporting landcover label data to FlatGeoBuf format..."
        ogr2ogr -lco SPATIAL_INDEX=NO -t_srs "$PROJECTION" \
            "$landcover_label_fgb" \
            "$DB_CONNECTION" \
            rbt.landcover_labels \
            -skipfailures \
            >> "$OUTPUT_DIR/landcover_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export landcover label data"
            return 1
        fi
        log "Data export completed: $landcover_label_fgb"
    fi
    
    # Generate landcover tiles
    log "Generating landcover polygon tiles..."
    tippecanoe -t "$TEMP_DIR" -j "$LANDCOVER_FILTER" \
        -o "$OUTPUT_DIR/landcover_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 4 \
        -z 13 \
        --single-precision \
        --extra-detail=13 \
        --drop-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        --no-tiny-polygon-reduction-at-maximum-zoom \
        -T osm_id:int \
        -T rank:int \
        -T area:float \
        -T area_part:float \
        -n landcover \
        -l landcover \
        "$landcover_fgb" >> "$OUTPUT_DIR/landcover_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate landcover tiles"
        return 1
    fi
    
    # Generate landcover label tiles
    log "Generating landcover label tiles..."
    tippecanoe -t "$TEMP_DIR" -j "$LANDCOVER_FILTER" \
        -o "$OUTPUT_DIR/landcover_labels_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 4 \
        -z 13 \
        -pk \
        -pf \
        -r 1 \
        --single-precision \
        -T osm_id:int \
        -T rank:int \
        -T area:float \
        -T area_part:float \
        -n landcover_labels \
        -l landcover_labels \
        "$landcover_label_fgb" >> "$OUTPUT_DIR/landcover_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate landcover label tiles"
        return 1
    fi
    
    log "Landcover layers completed."
}

generate_mountain() {
    log "Generating mountain label layer..."
    
    local fgb_file="$OUTPUT_DIR/mountain_label_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$fgb_file" ]]; then
        log "FlatGeoBuf file already exists: $fgb_file, skipping ogr2ogr -lco SPATIAL_INDEX=NO export"
    else
        log "Exporting data to FlatGeoBuf format..."
        ogr2ogr -lco SPATIAL_INDEX=NO -t_srs "$PROJECTION" \
            "$fgb_file" \
            "$DB_CONNECTION" \
            rbt.mountain_label \
            -skipfailures \
            >> "$OUTPUT_DIR/mountain_label_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export mountain label data"
            return 1
        fi
        log "Data export completed: $fgb_file"
    fi
    
    log "Generating vector tiles..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/mountain_label_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 2 \
        -z 13 \
        --single-precision \
        --extra-detail=13 \
        --drop-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        -T length:float \
        -T max_label:float \
        -T min_label:float \
        -T ne_id:int \
        -T scalerank:int \
        -n mountain_label \
        -l mountain_label \
        "$fgb_file" >> "$OUTPUT_DIR/mountain_label_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate mountain label tiles"
        return 1
    fi
    
    log "Mountain label layer completed."
}

generate_park() {
    log "Generating park layer..."
    
    local fgb_file="$OUTPUT_DIR/park_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$fgb_file" ]]; then
        log "FlatGeoBuf file already exists: $fgb_file, skipping ogr2ogr -lco SPATIAL_INDEX=NO export"
    else
        log "Exporting data to FlatGeoBuf format..."
        ogr2ogr -lco SPATIAL_INDEX=NO -t_srs "$PROJECTION" "$fgb_file" \
            "$DB_CONNECTION" \
            rbt.park \
            -skipfailures \
            >> "$OUTPUT_DIR/park_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export park data"
            return 1
        fi
        log "Data export completed: $fgb_file"
    fi
    
    log "Generating vector tiles..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/park_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 6 \
        -z 13 \
        --single-precision \
        --extra-detail=13 \
        --drop-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        --no-tiny-polygon-reduction-at-maximum-zoom \
        -T area:float \
        -T osm_id:int \
        -n park \
        -l park \
        "$fgb_file" >> "$OUTPUT_DIR/park_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate park tiles"
        return 1
    fi
    
    log "Park layer completed."
}

generate_water() {
    log "Generating water layer..."
    
    local geojson_file="$OUTPUT_DIR/water_${PROJECTION_CODE}.geojson"
    local ndjson_file="$OUTPUT_DIR/water_${PROJECTION_CODE}.ndjson"
    
    # Check if NDJSON file exists (final processed file)
    if [[ -f "$ndjson_file" ]]; then
        log "NDJSON file already exists: $ndjson_file, skipping data export and conversion"
    else
        # Check if GeoJSON file exists
        if [[ -f "$geojson_file" ]]; then
            log "GeoJSON file already exists: $geojson_file, skipping ogr2ogr export"
        else
            log "Exporting data to GeoJSON format..."
            ogr2ogr -f "GeoJSON" -t_srs "$PROJECTION" "$geojson_file" \
                "$DB_CONNECTION" \
                rbt.water \
                -skipfailures \
                >> "$OUTPUT_DIR/water_${PROJECTION_CODE}.log" 2>&1
            
            if [[ $? -ne 0 ]]; then
                log "ERROR: Failed to export water data to GeoJSON"
                return 1
            fi
            log "Data export completed: $geojson_file"
        fi
        
        # Convert GeoJSON to NDJSON
        log "Converting GeoJSON to NDJSON format..."
        tippecanoe-json-tool "$geojson_file" > "$ndjson_file" 2>> "$OUTPUT_DIR/water_${PROJECTION_CODE}.log"
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to convert GeoJSON to NDJSON"
            return 1
        fi
        log "NDJSON conversion completed: $ndjson_file"
    fi
    
    log "Generating vector tiles..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/water_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -z 13 \
        --single-precision \
        --extra-detail=13 \
        --drop-smallest-as-needed \
        -M 200000 \
        -X \
        --detect-longitude-wraparound \
        --simplify-only-low-zooms \
        --reorder \
        --coalesce \
        --no-tiny-polygon-reduction-at-maximum-zoom \
        -n water \
        -l water \
        "$ndjson_file" >> "$OUTPUT_DIR/water_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate water tiles"
        return 1
    fi
    
    log "Water layer completed."
}

generate_water_label() {
    log "Generating water label layer..."
    
    local fgb_file="$OUTPUT_DIR/ne_water_label_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$fgb_file" ]]; then
        log "FlatGeoBuf file already exists: $fgb_file, skipping ogr2ogr -lco SPATIAL_INDEX=NO export"
    else
        log "Exporting data to FlatGeoBuf format..."
        ogr2ogr -lco SPATIAL_INDEX=NO -t_srs "$PROJECTION" "$fgb_file" \
            "$DB_CONNECTION" \
            rbt.ne_water_label \
            -skipfailures \
            >> "$OUTPUT_DIR/ne_water_label_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export water label data"
            return 1
        fi
        log "Data export completed: $fgb_file"
    fi
    
    log "Generating vector tiles..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/ne_water_labels_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -z 13 \
        -pk \
        -pf \
        -r 1 \
        -n ne_water_label \
        -l ne_water_label \
        "$fgb_file" >> "$OUTPUT_DIR/ne_water_label_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate water label tiles"
        return 1
    fi
    
    log "Water label layer completed."
}

generate_waterway() {
    log "Generating waterway layer..."
    
    local fgb_file="$OUTPUT_DIR/waterway_${PROJECTION_CODE}.fgb"
    
    if [[ -f "$fgb_file" ]]; then
        log "FlatGeoBuf file already exists: $fgb_file, skipping ogr2ogr -lco SPATIAL_INDEX=NO export"
    else
        log "Exporting data to FlatGeoBuf format..."
        ogr2ogr -lco SPATIAL_INDEX=NO -t_srs "$PROJECTION" "$fgb_file" \
            "$DB_CONNECTION" \
            rbt.waterway \
            -skipfailures \
            >> "$OUTPUT_DIR/waterway_${PROJECTION_CODE}.log" 2>&1
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to export waterway data"
            return 1
        fi
        log "Data export completed: $fgb_file"
    fi
    
    log "Generating vector tiles..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/waterway_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 6 \
        -z 13 \
        --single-precision \
        --extra-detail=13 \
        --drop-smallest-as-needed \
        --simplify-only-low-zooms \
        --no-simplification-of-shared-nodes \
        -T geom_len:float \
        -T intermittent:bool \
        -n waterway \
        -l waterway \
        "$fgb_file" >> "$OUTPUT_DIR/waterway_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate waterway tiles"
        return 1
    fi
    
    log "Waterway layer completed."
}

generate_inland_water_intermittent() {
    log "Generating inland water intermittent layer..."
    
    local geojson_file="$OUTPUT_DIR/inland_water_intermittent_${PROJECTION_CODE}.geojson"
    local ndjson_file="$OUTPUT_DIR/inland_water_intermittent_${PROJECTION_CODE}.ndjson"
    
    # Check if NDJSON file exists (final processed file)
    if [[ -f "$ndjson_file" ]]; then
        log "NDJSON file already exists: $ndjson_file, skipping data export and conversion"
    else
        # Check if GeoJSON file exists
        if [[ -f "$geojson_file" ]]; then
            log "GeoJSON file already exists: $geojson_file, skipping ogr2ogr export"
        else
            log "Exporting data to GeoJSON format..."
            ogr2ogr -f "GeoJSON" -t_srs "$PROJECTION" "$geojson_file" \
                "$DB_CONNECTION" \
                rbt.inland_water_intermittent_dissolved \
                -skipfailures \
                >> "$OUTPUT_DIR/inland_water_intermittent_${PROJECTION_CODE}.log" 2>&1
            
            if [[ $? -ne 0 ]]; then
                log "ERROR: Failed to export inland water intermittent data to GeoJSON"
                return 1
            fi
            log "Data export completed: $geojson_file"
        fi
        
        # Convert GeoJSON to NDJSON
        log "Converting GeoJSON to NDJSON format..."
        tippecanoe-json-tool "$geojson_file" > "$ndjson_file" 2>> "$OUTPUT_DIR/inland_water_intermittent_${PROJECTION_CODE}.log"
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to convert GeoJSON to NDJSON"
            return 1
        fi
        log "NDJSON conversion completed: $ndjson_file"
    fi
    
    log "Generating vector tiles..."
    tippecanoe -t "$TEMP_DIR" \
        -o "$OUTPUT_DIR/inland_water_intermittent_${PROJECTION_CODE}.mbtiles" \
        -P --no-progress-indicator \
        -s EPSG:3857 \
        -Z 8 \
        -z 13 \
        --single-precision \
        --extra-detail=13 \
        -X \
        --drop-smallest-as-needed \
        --detect-longitude-wraparound \
        --simplify-only-low-zooms \
        --reorder \
        --coalesce \
        --no-tiny-polygon-reduction-at-maximum-zoom \
        -n inland_water_intermittent \
        -l inland_water_intermittent \
        "$ndjson_file" >> "$OUTPUT_DIR/inland_water_intermittent_${PROJECTION_CODE}.log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to generate inland water intermittent tiles"
        return 1
    fi
    
    log "Inland water intermittent layer completed."
}

merge_all_layers() {
    log "Merging all physical layers into consolidated mbtiles file..."
    
    # Check if tile-join is available
    if ! command -v tile-join &> /dev/null; then
        log "ERROR: tile-join not found. Please install tippecanoe with tile-join support."
        exit 1
    fi
    
    # Collect all generated mbtiles files
    local mbtiles_files=()
    local expected_files=(
        "builtuparea_${PROJECTION_CODE}.mbtiles"
        "contour_${PROJECTION_CODE}.mbtiles"
        "contour_glacier_${PROJECTION_CODE}.mbtiles"
        "glacier_${PROJECTION_CODE}.mbtiles"
        "landcover_${PROJECTION_CODE}.mbtiles"
        "landcover_labels_${PROJECTION_CODE}.mbtiles"
        "mountain_label_${PROJECTION_CODE}.mbtiles"
        "park_${PROJECTION_CODE}.mbtiles"
        "water_${PROJECTION_CODE}.mbtiles"
        "ne_water_labels_${PROJECTION_CODE}.mbtiles"
        "waterway_${PROJECTION_CODE}.mbtiles"
        "inland_water_intermittent_${PROJECTION_CODE}.mbtiles"
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
    local merged_file="$OUTPUT_DIR/physical_${PROJECTION_CODE}.mbtiles"
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
    local target_file="${1:-$OUTPUT_DIR/physical_${PROJECTION_CODE}.mbtiles}"
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
    sqlite3 "$target_file" "INSERT OR REPLACE INTO metadata(name,value) VALUES('tile_origin_upper_left_x','${TILE_ORIGIN_X}');" && \
    sqlite3 "$target_file" "INSERT OR REPLACE INTO metadata(name,value) VALUES('tile_origin_upper_left_y','${TILE_ORIGIN_Y}');" && \
    
    log "Adding tile dimension metadata..."
    sqlite3 "$target_file" "INSERT OR REPLACE INTO metadata(name,value) VALUES('tile_dimension_zoom_0','${TILE_DIMENSION}');" && \
    
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
        local mbtiles_count=$(find "$OUTPUT_DIR" -name "*.mbtiles" 2>/dev/null | wc -l)
        local fgb_count=$(find "$OUTPUT_DIR" -name "*.fgb" 2>/dev/null | wc -l)
        local dir_size=$(du -sh "$OUTPUT_DIR" 2>/dev/null | cut -f1)
        
        log "MBTiles files generated: $mbtiles_count"
        log "FGB intermediate files: $fgb_count"
        log "Output directory size: $dir_size"
        
        # Check for consolidated file
        local merged_file="$OUTPUT_DIR/physical_${PROJECTION_CODE}.mbtiles"
        if [[ -f "$merged_file" ]]; then
            local merged_size=$(du -sh "$merged_file" 2>/dev/null | cut -f1)
            log "Consolidated file: physical_${PROJECTION_CODE}.mbtiles ($merged_size)"
        fi
        
        # List generated files
        log "Generated MBTiles:"
        find "$OUTPUT_DIR" -name "*.mbtiles" | sed 's|.*/||' | sed 's/^/  /' || true
        
        # Show layer categories
        log "Physical layer categories:"
        log "  - Terrain: contour, contour_glacier, mountain_label"
        log "  - Hydrology: water, waterway, inland_water_intermittent, ne_water_label"
        log "  - Land Surface: landcover, landcover_labels, glacier, builtuparea"
        log "  - Recreation: park"
    fi
    
    log "=========================="
}

# =============================================================================
# Main Execution
# =============================================================================

count_selected_layers() {
    local count=0
    [[ "$RUN_BUILTUPAREA" == "true" ]] && ((count++))
    [[ "$RUN_CONTOUR" == "true" ]] && ((count++))
    [[ "$RUN_GLACIER" == "true" ]] && ((count++))
    [[ "$RUN_LANDCOVER" == "true" ]] && ((count++))
    [[ "$RUN_MOUNTAIN" == "true" ]] && ((count++))
    [[ "$RUN_PARK" == "true" ]] && ((count++))
    [[ "$RUN_WATER" == "true" ]] && ((count++))
    [[ "$RUN_WATER_LABEL" == "true" ]] && ((count++))
    [[ "$RUN_WATERWAY" == "true" ]] && ((count++))
    [[ "$RUN_INLAND_WATER_INTERMITTENT" == "true" ]] && ((count++))
    echo $count
}

main() {
    # Parse command line arguments first
    parse_arguments "$@"
    
    # Configure projection settings
    configure_projection
    
    log "Starting unified physical MVT generation..."
    log "Script: $0"
    log "Working directory: $(pwd)"
    log "Projection: $PROJECTION"
    
    # Show which layers will be generated
    local selected_count=$(count_selected_layers)
    if [[ "$RUN_ALL" == "true" ]]; then
        log "Mode: Generate all physical layers"
    else
        log "Mode: Generate selected layers ($selected_count layers)"
        [[ "$RUN_BUILTUPAREA" == "true" ]] && log "  - builtuparea"
        [[ "$RUN_CONTOUR" == "true" ]] && log "  - contour (regular and glacier)"
        [[ "$RUN_GLACIER" == "true" ]] && log "  - glacier"
        [[ "$RUN_LANDCOVER" == "true" ]] && log "  - landcover (polygons and labels)"
        [[ "$RUN_MOUNTAIN" == "true" ]] && log "  - mountain labels"
        [[ "$RUN_PARK" == "true" ]] && log "  - park"
        [[ "$RUN_WATER" == "true" ]] && log "  - water"
        [[ "$RUN_WATER_LABEL" == "true" ]] && log "  - water labels"
        [[ "$RUN_WATERWAY" == "true" ]] && log "  - waterway"
        [[ "$RUN_INLAND_WATER_INTERMITTENT" == "true" ]] && log "  - inland water intermittent"
    fi
    
    # Pre-flight checks
    check_prerequisites
    test_database_connection
    
    # Setup
    setup_output
    
    # Generate selected layers
    log "Generating selected physical layers..."
    
    [[ "$RUN_BUILTUPAREA" == "true" ]] && generate_builtuparea
    [[ "$RUN_CONTOUR" == "true" ]] && generate_contour
    [[ "$RUN_GLACIER" == "true" ]] && generate_glacier
    [[ "$RUN_LANDCOVER" == "true" ]] && generate_landcover
    [[ "$RUN_MOUNTAIN" == "true" ]] && generate_mountain
    [[ "$RUN_PARK" == "true" ]] && generate_park
    [[ "$RUN_WATER" == "true" ]] && generate_water
    [[ "$RUN_WATER_LABEL" == "true" ]] && generate_water_label
    [[ "$RUN_WATERWAY" == "true" ]] && generate_waterway
    [[ "$RUN_INLAND_WATER_INTERMITTENT" == "true" ]] && generate_inland_water_intermittent
    
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
            local single_mbtiles=$(find "$OUTPUT_DIR" -name "*.mbtiles" -not -name "physical_${PROJECTION_CODE}.mbtiles" | head -1)
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
