#!/bin/bash
set -euo pipefail

# =============================================================================
# RBT Vector Tiles Generation Script — DEPRECATED
# =============================================================================
# DEPRECATED: the Python engine (`rbt tiles`) is the primary tile generator.
# This script and the generators under production/tile-generation/ are kept
# only as the `rbt tiles --mode bash` escape hatch until a real-data parity
# check (see docs/parity-runbook.md) confirms the native output, after which
# they will be removed. Do not add new layers here — extend config/layers.yml.
#
# This script generates vector tiles from the prepared RBT database.
# It supports multiple projections and selective layer generation.
# =============================================================================

# Script metadata
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly START_TIME=$(date +%s)
readonly TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

source "${PROJECT_ROOT}/scripts/lib/config.sh"
rbt_config_load

RBT_DB_CONN="$(rbt_psql_conn_string)"
readonly RBT_DB_CONN

# Configuration
readonly LOG_DIR="${SHARED_LOG_DIR:-${PROJECT_ROOT}/output/logs}"
readonly LOG_FILE="${LOG_DIR}/tile_generation_${TIMESTAMP}.log"
readonly OUTPUT_DIR="${TILE_CACHE_DIR:-${PROJECT_ROOT}/output/tiles}"

# Ensure directories exist
mkdir -p "${LOG_DIR}" "${OUTPUT_DIR}"

source "${PROJECT_ROOT}/scripts/lib/logging.sh"
rbt_log_init "${LOG_FILE}"

# Default options (using config values with fallbacks)
LAYER_TYPE="all"
PROJECTION="${DEFAULT_PROJECTION:-all}"
VERBOSE=false
DRY_RUN=false
TILE_JOIN=true
ADD_BTIS=true
TEMP_DIR="${TILE_TEMP_DIR:-/tmp/tiles}"
BTP_SCHEMA_VERSION="1.0.0"

# Layer-specific selection flags for cultural
CULTURAL_AEROWAY=false
CULTURAL_BOUNDARY=false
CULTURAL_BUILDING=false
CULTURAL_CEMETERY=false
CULTURAL_GEONAMES=false
CULTURAL_TRANSPORTATION=false
CULTURAL_UTILITIES=false
CULTURAL_OTHER=false

# Layer-specific selection flags for physical
PHYSICAL_BUILTUPAREA=false
PHYSICAL_CONTOUR=false
PHYSICAL_GLACIER=false
PHYSICAL_LANDCOVER=false
PHYSICAL_MOUNTAIN=false
PHYSICAL_PARK=false
PHYSICAL_WATER=false
PHYSICAL_WATER_LABEL=false
PHYSICAL_WATERWAY=false
PHYSICAL_INLAND_WATER=false

declare -A CULTURAL_LAYER_CAPABILITIES=(
    [--aeroway]="all"
    [--boundary]="all"
    [--building]="all"
    [--cemetery]="all"
    [--geonames]="all"
    [--transportation]="all"
    [--utilities]="all"
    [--other]="all"
)

declare -A CULTURAL_LAYER_MAPPING_4326=(
    [--geonames]="--geonames --populated"
    [--other]="--landuse --military --radar"
)

declare -A PHYSICAL_LAYER_CAPABILITIES=(
    [--builtuparea]="all"
    [--contour]="all"
    [--glacier]="all"
    [--landcover]="all"
    [--mountain]="all"
    [--park]="all"
    [--water]="all"
    [--water-label]="mercator"
    [--waterway]="mercator"
    [--inland-water]="mercator"
)

# =============================================================================
# Logging Functions
# =============================================================================

log() {
    rbt_log "$@"
}

show_progress() {
    rbt_log_progress "$@"
}

# =============================================================================
# Usage and Argument Parsing
# =============================================================================

show_usage() {
    cat << EOF
RBT Vector Tiles Generation Script

USAGE:
    $SCRIPT_NAME [OPTIONS]

DESCRIPTION:
    Generates vector tiles from the RBT database in multiple projections.
    This script should be run after database initialization is complete.

OPTIONS:
    --layer-type TYPE    Layer type to generate: physical, cultural, all (default: all)
    --projection PROJ    Projection to generate: 3857, 3395, 4326, all (default: all)
    --temp-dir DIR       Temp directory for tippecanoe processing (default: /mnt/data)
    --no-tile-join       Don't merge multiple layers into consolidated MBTiles files
    --no-btis            Don't add BTIS metadata to MBTiles files
    --version VERSION    Set BTP schema version (default: 1.0.0)
    --verbose, -v        Enable verbose output
    --dry-run, -d        Show what would be executed without running
    --help, -h           Show this help message

CULTURAL LAYER OPTIONS:
    --aeroway            Generate aeroway layers (surface, airports, heliports, curves)
    --boundary           Generate boundary layers (adm0/adm1/adm2 labels and lines)
    --building           Generate building layer
    --cemetery           Generate cemetery layers (polygons and labels)
    --geonames           Generate geonames layers (hydrographic, populated places)
    --transportation     Generate transportation layers (highway, railway, ferry, ports, stations)
    --utilities          Generate utilities layers (dam, grain, hydrocarbon, powerline, pipeline)
    --other              Generate other cultural layers (stadium, military, radar)

PHYSICAL LAYER OPTIONS:
    --builtuparea        Generate builtuparea layer
    --contour            Generate contour layers (regular and glacier contours)
    --glacier            Generate glacier layer
    --landcover          Generate landcover layers (polygons and labels)
    --mountain           Generate mountain label layer
    --park               Generate park layer
    --water              Generate water layer
    --water-label        Generate water label layer
    --waterway           Generate waterway layer
    --inland-water       Generate inland water intermittent layer

EXAMPLES:
    # Generate all tiles in all projections with consolidation and metadata
    $SCRIPT_NAME --all

    # Generate only physical tiles in Web Mercator
    $SCRIPT_NAME --layer-type physical --projection 3857

    # Generate specific cultural layers in EPSG:3395
    $SCRIPT_NAME --layer-type cultural --projection 3395 --transportation --building --boundary

    # Generate water-related physical layers with custom temp directory
    $SCRIPT_NAME --layer-type physical --water --waterway --inland-water --temp-dir /tmp/tiles

    # Generate without consolidation and metadata
    $SCRIPT_NAME --no-tile-join --no-btis

    # Generate with custom BTP schema version
    $SCRIPT_NAME --version 2.0.0

    # Dry run to see what would be executed
    $SCRIPT_NAME --dry-run --verbose

PROJECTIONS:
    3857    Web Mercator (EPSG:3857) - Standard web mapping
    3395    World Mercator (EPSG:3395) - Better area preservation
    4326    Geographic WGS84 (EPSG:4326) - Latitude/longitude

LAYER TYPES:
    physical    Terrain, hydrology, land cover, parks
    cultural    Transportation, boundaries, infrastructure, buildings

OUTPUT:
    Tiles are generated in: ${OUTPUT_DIR}
    Logs are written to: ${LOG_DIR}

EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --layer-type)
                LAYER_TYPE="$2"
                shift 2
                ;;
            --projection)
                PROJECTION="$2"
                shift 2
                ;;
            --temp-dir)
                TEMP_DIR="$2"
                shift 2
                ;;
            --no-tile-join)
                TILE_JOIN=false
                shift
                ;;
            --no-btis)
                ADD_BTIS=false
                shift
                ;;
            --version)
                if [[ -z "$2" ]]; then
                    log "ERROR" "--version requires a value"
                    exit 1
                fi
                BTP_SCHEMA_VERSION="$2"
                shift 2
                ;;
            --verbose|-v)
                # shellcheck disable=SC2034  # accepted for CLI compatibility
                VERBOSE=true
                shift
                ;;
            --dry-run|-d)
                DRY_RUN=true
                shift
                ;;
            --all)
                LAYER_TYPE="all"
                PROJECTION="all"
                shift
                ;;
            # Cultural layer options
            --aeroway)
                CULTURAL_AEROWAY=true
                shift
                ;;
            --boundary)
                CULTURAL_BOUNDARY=true
                shift
                ;;
            --building)
                CULTURAL_BUILDING=true
                shift
                ;;
            --cemetery)
                CULTURAL_CEMETERY=true
                shift
                ;;
            --geonames)
                CULTURAL_GEONAMES=true
                shift
                ;;
            --transportation)
                CULTURAL_TRANSPORTATION=true
                shift
                ;;
            --utilities)
                CULTURAL_UTILITIES=true
                shift
                ;;
            --other)
                CULTURAL_OTHER=true
                shift
                ;;
            # Physical layer options
            --builtuparea)
                PHYSICAL_BUILTUPAREA=true
                shift
                ;;
            --contour)
                PHYSICAL_CONTOUR=true
                shift
                ;;
            --glacier)
                PHYSICAL_GLACIER=true
                shift
                ;;
            --landcover)
                PHYSICAL_LANDCOVER=true
                shift
                ;;
            --mountain)
                PHYSICAL_MOUNTAIN=true
                shift
                ;;
            --park)
                PHYSICAL_PARK=true
                shift
                ;;
            --water)
                PHYSICAL_WATER=true
                shift
                ;;
            --water-label)
                PHYSICAL_WATER_LABEL=true
                shift
                ;;
            --waterway)
                PHYSICAL_WATERWAY=true
                shift
                ;;
            --inland-water)
                PHYSICAL_INLAND_WATER=true
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Validate arguments
    case "$LAYER_TYPE" in
        physical|cultural|all) ;;
        *) log "ERROR" "Invalid layer type: $LAYER_TYPE"; exit 1 ;;
    esac
    
    case "$PROJECTION" in
        3857|3395|4326|all) ;;
        *) log "ERROR" "Invalid projection: $PROJECTION"; exit 1 ;;
    esac
}

# =============================================================================
# Helper Functions
# =============================================================================

build_cultural_args() {
    local args=()
    
    # Add specific layer selections if any are specified
    if [[ "$CULTURAL_AEROWAY" == "true" ]]; then
        args+=(--aeroway)
    fi
    if [[ "$CULTURAL_BOUNDARY" == "true" ]]; then
        args+=(--boundary)
    fi
    if [[ "$CULTURAL_BUILDING" == "true" ]]; then
        args+=(--building)
    fi
    if [[ "$CULTURAL_CEMETERY" == "true" ]]; then
        args+=(--cemetery)
    fi
    if [[ "$CULTURAL_GEONAMES" == "true" ]]; then
        args+=(--geonames)
    fi
    if [[ "$CULTURAL_TRANSPORTATION" == "true" ]]; then
        args+=(--transportation)
    fi
    if [[ "$CULTURAL_UTILITIES" == "true" ]]; then
        args+=(--utilities)
    fi
    if [[ "$CULTURAL_OTHER" == "true" ]]; then
        args+=(--other)
    fi
    
    # If no specific layers selected, use --all
    if [[ ${#args[@]} -eq 0 ]]; then
        args+=(--all)
    fi
    
    # Add processing options
    if [[ "$TILE_JOIN" == "true" ]]; then
        args+=(--tile-join)
    fi
    if [[ "$ADD_BTIS" == "true" ]]; then
        args+=(--add-btis)
    fi
    
    # Add temp directory and version
    args+=(--temp-dir "$TEMP_DIR")
    args+=(--version "$BTP_SCHEMA_VERSION")
    
    echo "${args[@]}"
}

build_physical_args() {
    local args=()
    
    # Add specific layer selections if any are specified
    if [[ "$PHYSICAL_BUILTUPAREA" == "true" ]]; then
        args+=(--builtuparea)
    fi
    if [[ "$PHYSICAL_CONTOUR" == "true" ]]; then
        args+=(--contour)
    fi
    if [[ "$PHYSICAL_GLACIER" == "true" ]]; then
        args+=(--glacier)
    fi
    if [[ "$PHYSICAL_LANDCOVER" == "true" ]]; then
        args+=(--landcover)
    fi
    if [[ "$PHYSICAL_MOUNTAIN" == "true" ]]; then
        args+=(--mountain)
    fi
    if [[ "$PHYSICAL_PARK" == "true" ]]; then
        args+=(--park)
    fi
    if [[ "$PHYSICAL_WATER" == "true" ]]; then
        args+=(--water)
    fi
    if [[ "$PHYSICAL_WATER_LABEL" == "true" ]]; then
        args+=(--water-label)
    fi
    if [[ "$PHYSICAL_WATERWAY" == "true" ]]; then
        args+=(--waterway)
    fi
    if [[ "$PHYSICAL_INLAND_WATER" == "true" ]]; then
        args+=(--inland-water)
    fi
    
    # If no specific layers selected, use --all
    if [[ ${#args[@]} -eq 0 ]]; then
        args+=(--all)
    fi
    
    # Add processing options
    if [[ "$TILE_JOIN" == "true" ]]; then
        args+=(--tile-join)
    fi
    if [[ "$ADD_BTIS" == "true" ]]; then
        args+=(--add-btis)
    fi
    
    # Add temp directory and version
    args+=(--temp-dir "$TEMP_DIR")
    args+=(--version "$BTP_SCHEMA_VERSION")
    
    echo "${args[@]}"
}

# =============================================================================
# Tile Generation Functions
# =============================================================================

generate_physical_tiles() {
    local projection="$1"
    
    log "INFO" "Generating physical tiles for projection: $projection"
    
    local script_path="${PROJECT_ROOT}/production/tile-generation/physical"
    local args=($(build_physical_args))
    
    case "$projection" in
        3857|3395)
            local cmd="${script_path}/generate-physical-3857-3395.sh --projection $projection ${args[*]}"
            if [[ "$DRY_RUN" == "true" ]]; then
                log "INFO" "[DRY RUN] Would execute: $cmd"
            else
                log "INFO" "Executing: $cmd"
                cd "$script_path"
                ./generate-physical-3857-3395.sh --projection "$projection" "${args[@]}"
            fi
            ;;
        4326)
            local args_4326=()
            local skip_next=false
            for arg in "${args[@]}"; do
                if [[ "$skip_next" == "true" ]]; then
                    skip_next=false
                    continue
                fi

                case "$arg" in
                    --temp-dir|--version)
                        skip_next=true
                        continue
                        ;;
                    --tile-join|--add-btis)
                        continue
                        ;;
                    --all)
                        args_4326+=(--all)
                        ;;
                    *)
                        if [[ "$arg" =~ ^/ ]]; then
                            continue
                        fi
                        local capability="${PHYSICAL_LAYER_CAPABILITIES[$arg]:-mercator}"
                        if [[ "$capability" == "all" || "$capability" == "4326" ]]; then
                            args_4326+=("$arg")
                        fi
                        ;;
                esac
            done

            if [[ ${#args_4326[@]} -eq 0 ]]; then
                args_4326=(--all)
            fi
            
            local cmd="${script_path}/generate-physical-4326.sh ${args_4326[*]}"
            if [[ "$DRY_RUN" == "true" ]]; then
                log "INFO" "[DRY RUN] Would execute: $cmd"
            else
                log "INFO" "Executing: $cmd"
                cd "$script_path"
                ./generate-physical-4326.sh "${args_4326[@]}"
            fi
            ;;
    esac
}

generate_cultural_tiles() {
    local projection="$1"
    
    log "INFO" "Generating cultural tiles for projection: $projection"
    
    local script_path="${PROJECT_ROOT}/production/tile-generation/cultural"
    local args=($(build_cultural_args))
    
    case "$projection" in
        3857|3395)
            local cmd="${script_path}/generate-cultural-3857-3395.sh --projection $projection ${args[*]}"
            if [[ "$DRY_RUN" == "true" ]]; then
                log "INFO" "[DRY RUN] Would execute: $cmd"
            else
                log "INFO" "Executing: $cmd"
                cd "$script_path"
                ./generate-cultural-3857-3395.sh --projection "$projection" "${args[@]}"
            fi
            ;;
        4326)
            local args_4326=()
            local skip_next=false
            for arg in "${args[@]}"; do
                if [[ "$skip_next" == "true" ]]; then
                    skip_next=false
                    continue
                fi

                case "$arg" in
                    --temp-dir|--version)
                        skip_next=true
                        continue
                        ;;
                    --tile-join|--add-btis)
                        continue
                        ;;
                    --all)
                        args_4326+=(--all)
                        ;;
                    *)
                        if [[ "$arg" =~ ^/ ]]; then
                            continue
                        fi
                        local mapped="${CULTURAL_LAYER_MAPPING_4326[$arg]:-}"
                        if [[ -n "$mapped" ]]; then
                            # shellcheck disable=SC2206
                            local mapped_tokens=($mapped)
                            args_4326+=("${mapped_tokens[@]}")
                            continue
                        fi
                        local capability="${CULTURAL_LAYER_CAPABILITIES[$arg]:-all}"
                        if [[ "$capability" == "all" || "$capability" == "4326" ]]; then
                            args_4326+=("$arg")
                        fi
                        ;;
                esac
            done
            
            if [[ ${#args_4326[@]} -eq 0 ]]; then
                args_4326=(--all)
            fi
            
            local cmd="${script_path}/generate-cultural-4326.sh ${args_4326[*]}"
            if [[ "$DRY_RUN" == "true" ]]; then
                log "INFO" "[DRY RUN] Would execute: $cmd"
            else
                log "INFO" "Executing: $cmd"
                cd "$script_path"
                ./generate-cultural-4326.sh "${args_4326[@]}"
            fi
            ;;
    esac
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
    # Parse arguments first
    parse_arguments "$@"
    
    log "INFO" "🎯 Starting RBT Vector Tiles Generation"
    log "INFO" "Layer type: $LAYER_TYPE"
    log "INFO" "Projection: $PROJECTION"
    log "INFO" "Tile joining: $TILE_JOIN"
    log "INFO" "BTIS metadata: $ADD_BTIS"
    log "INFO" "BTP schema version: $BTP_SCHEMA_VERSION"
    log "INFO" "Temp directory: $TEMP_DIR"
    log "INFO" "Log file: $LOG_FILE"
    
    # Validate environment
    if ! psql "${RBT_DB_CONN}" -c "SELECT 1" >/dev/null 2>&1; then
        log "ERROR" "Cannot connect to RBT database. Please ensure database is initialized."
        log "ERROR" "Run: rbt setup --all"
        exit 1
    fi
    
    # Determine projections to process
    local projections=()
    case "$PROJECTION" in
        all) projections=(3857 3395 4326) ;;
        *) projections=("$PROJECTION") ;;
    esac
    
    # Calculate steps based on layer types to be generated
    local step=0
    local total_steps=0
    
    # Count physical steps
    if [[ "$LAYER_TYPE" == "all" || "$LAYER_TYPE" == "physical" ]]; then
        total_steps=$((total_steps + ${#projections[@]}))
    fi
    
    # Count cultural steps
    if [[ "$LAYER_TYPE" == "all" || "$LAYER_TYPE" == "cultural" ]]; then
        total_steps=$((total_steps + ${#projections[@]}))
    fi
    
    # Generate tiles
    for proj in "${projections[@]}"; do
        if [[ "$LAYER_TYPE" == "all" || "$LAYER_TYPE" == "physical" ]]; then
            ((step++))
            show_progress $step $total_steps "Physical tiles $proj"
            generate_physical_tiles "$proj"
        fi
        
        if [[ "$LAYER_TYPE" == "all" || "$LAYER_TYPE" == "cultural" ]]; then
            ((step++))
            show_progress $step $total_steps "Cultural tiles $proj"
            generate_cultural_tiles "$proj"
        fi
    done
    
    # Final summary
    local end_time=$(date +%s)
    local total_duration=$((end_time - START_TIME))
    local hours=$((total_duration / 3600))
    local minutes=$(((total_duration % 3600) / 60))
    
    log "INFO" "✅ Tile generation completed successfully!"
    log "INFO" "Total time: ${hours}h ${minutes}m"
    log "INFO" "Output directory: ${OUTPUT_DIR}"
    log "INFO" "Generated tiles for:"
    log "INFO" "  - Layer types: $LAYER_TYPE"
    log "INFO" "  - Projections: ${projections[*]}"
    
    # Show specific layer information if granular selection was used
    if [[ "$CULTURAL_AEROWAY" == "true" || "$CULTURAL_BOUNDARY" == "true" || "$CULTURAL_BUILDING" == "true" || 
          "$CULTURAL_CEMETERY" == "true" || "$CULTURAL_GEONAMES" == "true" || "$CULTURAL_TRANSPORTATION" == "true" || 
          "$CULTURAL_UTILITIES" == "true" || "$CULTURAL_OTHER" == "true" ]]; then
        log "INFO" "  - Cultural layers: $(build_cultural_args | grep -E '^--' | grep -v -E '^--(temp-dir|tile-join|add-btis)' | tr '\n' ' ')"
    fi
    
    if [[ "$PHYSICAL_BUILTUPAREA" == "true" || "$PHYSICAL_CONTOUR" == "true" || "$PHYSICAL_GLACIER" == "true" || 
          "$PHYSICAL_LANDCOVER" == "true" || "$PHYSICAL_MOUNTAIN" == "true" || "$PHYSICAL_PARK" == "true" || 
          "$PHYSICAL_WATER" == "true" || "$PHYSICAL_WATER_LABEL" == "true" || "$PHYSICAL_WATERWAY" == "true" || 
          "$PHYSICAL_INLAND_WATER" == "true" ]]; then
        log "INFO" "  - Physical layers: $(build_physical_args | grep -E '^--' | grep -v -E '^--(temp-dir|tile-join|add-btis)' | tr '\n' ' ')"
    fi
}

# Execute main function
main "$@"
