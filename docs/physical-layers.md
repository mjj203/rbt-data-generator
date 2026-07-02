# Physical Data Processing Workflow

!!! warning "Script names below are historical"
    This page predates the `rbt` Python CLI and still describes the original
    standalone script names (`process-physical-schemas.sh`, `physical.sql`,
    `water.sql`, `contour.sql`, `tiles.sh`, `4326_tiles.sh`). **None of those
    files exist anymore.** The underlying SQL algorithms and processing
    concepts described here are still broadly accurate, but to actually run
    anything, use today's commands:

    - Schema processing: `rbt schema list` / `rbt schema run physical` (dispatches
      the real files under
      [`setup/data-sources/schemas/physical/`](https://github.com/MJJ203/rbt-data-generator/tree/main/setup/data-sources/schemas/physical)
      — `physical-core.sql`, `landcover.sql`, `water-features.sql`, `terrain.sql`).
    - Tile generation: `rbt tiles --layer-type physical --projection <3857|3395|4326> [--water|--landcover|...]`
      (see the [CLI Reference](cli.md) and [`config/layers.yml`](https://github.com/MJJ203/rbt-data-generator/blob/main/config/layers.yml)
      for the declarative layer/filter definitions that replaced the JSON
      configs and per-layer bash flags below).

## Overview

This directory contains the complete workflow for processing physical (natural features) geospatial data and generating vector tiles in multiple projections. The workflow transforms raw OpenStreetMap (OSM) and Natural Earth data stored in PostgreSQL/PostGIS into optimized Mapbox Vector Tiles (MVT) for web mapping applications, focusing on terrain, hydrology, land cover, and natural features.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Script Overview](#script-overview)
3. [Database Schema Setup](#database-schema-setup)
4. [Processing Pipelines](#processing-pipelines)
5. [Layer Categories](#layer-categories)
6. [Command Reference](#command-reference)
7. [Performance Optimizations](#performance-optimizations)
8. [Troubleshooting](#troubleshooting)

## Architecture Overview

The physical data processing workflow consists of modular components for flexible processing:

1. **Database Layer**: Modular SQL scripts create materialized views, indexes, and optimized data structures
2. **Tile Generation**: Unified script with configurable projection and layer selection
3. **Configuration**: JSON-based layer configuration for tile generation

```
PostgreSQL Database (rbt schema)
        ↓
    Modular SQL Processing:
    └── process-physical-schemas.sh --all (runs all SQL scripts)
        ├── --physical-core (core physical layers)
        ├── --landcover (landcover processing)
        ├── --water-features (water processing)
        └── --terrain (terrain/contour processing)
        ↓
    Unified Tile Generation:
    ├── generate-physical-3857-3395.sh --projection 3857 (Web Mercator)
    ├── generate-physical-3857-3395.sh --projection 3395 (World Mercator)
    └── generate-physical-4326.sh (Geographic WGS 84 - GDAL MVT)
        ↓
    MBTiles output (individual or consolidated)
```

## Script Overview

### SQL Processing Scripts

#### **`process-physical-schemas.sh`** - Modular SQL Processing
A unified script for running modular SQL processing with selective execution:

```bash
# Process all SQL scripts
./setup/data-sources/schemas/physical/process-physical-schemas.sh --all

# Process individual components
./setup/data-sources/schemas/physical/process-physical-schemas.sh --physical-core    # Core physical layers
./setup/data-sources/schemas/physical/process-physical-schemas.sh --landcover       # Landcover processing
./setup/data-sources/schemas/physical/process-physical-schemas.sh --water-features  # Water processing
./setup/data-sources/schemas/physical/process-physical-schemas.sh --terrain         # Terrain/contour processing
```

**Key Features:**
- **Modular Architecture**: Each layer type has its own SQL script for maintainability
- **Selective Processing**: Run only the components you need
- **Error Handling**: Robust error handling with detailed logging
- **Transaction Management**: Each script uses transactions with intermediate commits
- **Performance Optimization**: Memory settings optimized for large datasets
- **CI/CD Ready**: Structured logging and validation for automated processing

#### **Individual SQL Scripts**
- **`physical.sql`**: Core physical layers (builtuparea, glacier, mountain_label, park)
- **`landcover.sql`**: Comprehensive landcover processing with zoom-level views and label generation
- **`water.sql`**: Advanced water processing with clustering, classification, and utility functions
- **`contour.sql`**: Contour processing with conditional table handling and zoom-level views

### Tile Generation Scripts

#### **`generate-physical-3857-3395.sh`** - Unified Tile Generation
A comprehensive script for generating vector tiles with configurable options:

```bash
# Generate all layers in Web Mercator (default)
./production/tile-generation/physical/generate-physical-3857-3395.sh --all

# Generate specific layers with projection selection
./production/tile-generation/physical/generate-physical-3857-3395.sh --projection 3395 --water --landcover --glacier

# Generate with tile joining and BTIS metadata
./production/tile-generation/physical/generate-physical-3857-3395.sh --all --tile-join --add-btis

# Generate single layer in specific projection
./production/tile-generation/physical/generate-physical-3857-3395.sh --projection 3857 --builtuparea
```

**Key Features:**
- **Projection Support**: EPSG:3857 (Web Mercator) and EPSG:3395 (World Mercator)
- **Selective Layer Generation**: Choose specific layers or generate all
- **Tile Joining**: Consolidate multiple layers into single MBTiles file
- **BTIS Metadata**: Add Background Tile Information Standard metadata
- **Built-in Filters**: JSON-based filters for zoom-level feature selection
- **Parallel Processing**: Optimized for performance with parallel execution
- **Resume Capability**: Skips existing intermediate files for faster re-runs

**Layer Options:**
- `--builtuparea`: Urban areas from OSM and Natural Earth
- `--contour`: Regular and glacier contours with zoom-based density
- `--glacier`: Glacier polygons from multiple sources
- `--landcover`: Land cover polygons and labels with progressive zoom
- `--mountain`: Mountain label lines from medial axis generation
- `--park`: Parks and protected areas
- `--water`: Water bodies with clustering and simplification
- `--water-label`: Water body labels from Natural Earth
- `--waterway`: Linear water features (rivers, streams, canals)
- `--inland-water`: Intermittent water features

#### **`generate-physical-4326.sh`** - Geographic Coordinate Tiles
Specialized script using GDAL's MVT driver for EPSG:4326 tiles:

```bash
# Generate all physical layers in EPSG:4326
./production/tile-generation/physical/generate-physical-4326.sh
```

**Key Features:**
- **Direct MVT Generation**: Uses ogr2ogr with MVT format for direct PostgreSQL to MVT conversion
- **Custom Tiling Scheme**: EPSG:4326 with custom geographic tiling
- **Unified Processing**: Processes all layers in a single ogr2ogr command
- **JSON Configuration**: Uses `physical_layer_config.json` for layer definitions
- **Directory Output**: Creates directory-based tile structure

## Tools and Technologies

### Core Tools

#### **ogr2ogr (GDAL)**
A command-line utility for converting between geospatial data formats. Used in two approaches:

**FlatGeoBuf Export Approach** (`generate-physical-3857-3395.sh`):
- Export data from PostgreSQL to FlatGeoBuf (.fgb) intermediate format
- Transform coordinate systems during export
- Apply SQL filters for selective data export
- Handle Natural Earth and OSM data sources

**Direct MVT Approach** (`generate-physical-4326.sh`):
- Direct PostgreSQL to MVT conversion using GDAL's MVT driver
- Custom tiling schemes with geographic coordinates
- JSON-based layer configuration
- Directory-based tile output structure

#### **tippecanoe**
A Mapbox tool for building vector tilesets from large GeoJSON/FlatGeoBuf datasets. Provides:
- Intelligent feature simplification at different zoom levels
- Polygon-to-label-point conversion for text rendering
- Feature clustering and merging
- JSON-based filter configurations
- Parallel processing capabilities
- Built-in filters for zoom-based feature selection

#### **tile-join**
Companion tool to tippecanoe for merging multiple MBTiles files into a single consolidated tileset.
- Consolidates individual layer MBTiles into unified files
- Preserves layer metadata and zoom level configurations
- Enables single-file distribution of multi-layer tilesets

#### **PostgreSQL/PostGIS**
- **PostgreSQL**: Relational database storing the raw geospatial data
- **PostGIS**: Spatial extension providing geographic functions
- **CG_ApproximateMedialAxis**: Special PostGIS function for generating label lines
- **pg_trgm**: Trigram extension for fuzzy text matching and search functions

### Supporting Technologies

- **FlatGeoBuf (FGB)**: High-performance binary format for geographic data
- **MBTiles**: SQLite-based container format for storing tilesets
- **MVT (Mapbox Vector Tiles)**: Protocol buffer format for vector tiles
- **Natural Earth**: Public domain map dataset at various scales
- **OSM Ocean**: Water polygon dataset derived from OpenStreetMap
- **BTIS (Background Tile Information Standard)**: Metadata standard for tile compatibility

## Database Schema Setup

The modular SQL processing approach creates an extensive set of materialized views, indexes, and optimized data structures with enhanced CI/CD support and error handling. Each script focuses on specific layer types for maintainability and selective processing.

### Transaction Management and Error Handling

```sql
BEGIN;
SET LOCAL work_mem = '1GB';
SET LOCAL maintenance_work_mem = '2GB';
SET LOCAL max_parallel_workers_per_gather = 4;
```
- Wraps entire script in transaction for atomicity
- Configures memory settings for heavy spatial operations
- Enables parallel processing for performance

### Dependency Validation

The script validates all required source tables exist before proceeding:

```sql
DO $$
DECLARE
    table_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO table_count FROM import.landcover LIMIT 1;
    IF table_count = 0 THEN
        RAISE EXCEPTION 'Source table import.landcover is empty or missing';
    END IF;
    -- Validates: import.water, import.waterway, import.park_polygon, 
    -- import.builtup_area, naturalearth schema, rbt.osm_ocean
END $$;
```

### Index Creation Strategy

#### **Spatial Indexes (GIST)**
```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_landcover_geometry 
ON import.landcover USING gist(geometry);
```
- Used for all geometry columns
- Enables fast spatial queries and joins
- `CONCURRENTLY` prevents table locking

#### **B-tree Indexes for Attributes**
```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_landcover_subclass 
ON import.landcover USING btree(subclass);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_landcover_area 
ON import.landcover USING btree(ST_Area(geometry));
```
- Optimizes filtering by classification
- Speeds up area-based queries

#### **Conditional and Expression Indexes**
```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_landcover_wetland_no_natural 
ON import.landcover ((tags->'wetland')) 
WHERE NOT exist(tags, 'natural') OR (tags->'natural') != 'wetland';
```
- Partial indexes for specific query patterns
- JSONB expression indexes for tag filtering

### Modular SQL Architecture

The physical data processing now uses a modular approach with separate SQL scripts for different layer types:

#### **`physical.sql`** - Core Physical Layers
- **Builtuparea**: Combines OSM and Natural Earth urban areas
- **Glacier**: Merges glacier data from multiple sources including Antarctic ice shelves
- **Mountain Labels**: Generates label lines using medial axis from geographic regions
- **Park**: Processes parks and protected areas

#### **`landcover.sql`** - Comprehensive Landcover Processing
- **Complex Classification**: Leaf type/cycle normalization and wetland subtype classification
- **Zoom-Level Views**: Progressive feature display (z4, z6, z9, z10, z12+)
- **Label Generation**: Creates point labels from named landcover polygons
- **Multipolygon Handling**: Decomposes and ranks multipolygon features
- **Performance Optimized**: Uses 32GB work_mem for large dataset processing

#### **`water.sql`** - Advanced Water Processing
- **Water Classification**: Normalizes 40+ water subtypes using pattern matching
- **Clustering and Simplification**: Groups nearby features with ST_ClusterWithin
- **Utility Functions**: Includes diagnostic and search functions for data analysis
- **Trigram Search**: Fuzzy text matching for water feature names
- **Transaction Safety**: Multiple transaction boundaries to preserve partial work

#### **`contour.sql`** - Contour Processing
- **Conditional Processing**: Handles optional contour and glacier contour tables
- **Zoom-Level Views**: Creates z8, z10, z12 views with nth_line filtering
- **Performance Tuned**: Optimized memory settings for contour line processing
- **Error Resilient**: Continues processing even if some contour tables are missing

### Utility Functions

#### **Water Type Classification** (`water.sql`)
```sql
CREATE OR REPLACE FUNCTION classify_water_type(subclass_input TEXT) 
RETURNS TEXT AS $$
BEGIN
  RETURN CASE
    WHEN subclass_input ~ '^bas' THEN 'basin'
    WHEN subclass_input ~ 'bayou' THEN 'bayou'
    WHEN subclass_input ~ 'can[ao]l' THEN 'canal'
    WHEN subclass_input ~ 'lake' THEN 'lake'
    -- ... pattern matching for 30+ water types using regex
  END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;
```
- Normalizes diverse water body classifications using regex patterns
- Handles fuzzy matching for inconsistent OSM tagging
- Used in materialized views for consistent water type classification

#### **Search and Diagnostic Functions** (`water.sql`)
```sql
-- Fuzzy name search across water features
SELECT * FROM search_water_features_fuzzy('mississippi', 0.3);

-- Find subclass variations for normalization
SELECT * FROM find_subclass_variations('lake', 'lak');

-- Analyze subclass patterns for optimization
SELECT * FROM analyze_subclass_patterns(10);
```
- **Trigram-powered search**: Uses pg_trgm extension for typo-tolerant searches
- **Data quality tools**: Functions to discover and analyze data patterns
- **Performance optimized**: Leverages GIN trigram indexes for fast text matching

### Materialized Views

#### **BUILTUPAREA Materialized View**
Combines OSM and Natural Earth urban areas:

```sql
CREATE MATERIALIZED VIEW rbt.builtuparea AS
WITH builtuparea_osm AS (
    SELECT
        'osm' AS class,
        subclass,
        ST_Area(geometry) AS area,
        geometry
    FROM import.builtup_area
    WHERE class = 'landuse' 
       OR (class = 'place' AND subclass IN ('city', 'town', 'village', 'hamlet'))
),
builtuparea_ne AS (
    SELECT
        'ne' AS class,
        featurecla AS subclass,
        ST_Area(geometry) AS area,
        geometry
    FROM naturalearth.ne_10m_urban_areas
)
SELECT * FROM builtuparea_osm
UNION ALL
SELECT * FROM builtuparea_ne;
```

#### **GLACIER Materialized View**
Merges multiple glacier data sources:

```sql
CREATE MATERIALIZED VIEW rbt.glacier AS
WITH glacier_ne AS (
    -- Antarctic ice shelves
    SELECT name, featurecla as subclass, 'ne' as source, geometry
    FROM naturalearth.ne_10m_antarctic_ice_shelves_polys
    UNION ALL
    -- Glaciated areas
    SELECT name, featurecla as subclass, 'ne' as source, geometry
    FROM naturalearth.ne_10m_glaciated_areas
),
glacier_osm AS (
    SELECT name, subclass, 'osm' as source, geometry
    FROM import.landcover 
    WHERE subclass = 'glacier'
)
SELECT * FROM glacier_ne UNION ALL SELECT * FROM glacier_osm;
```

#### **LANDCOVER Materialized View**
Complex processing with leaf type/cycle classification:

```sql
CREATE MATERIALIZED VIEW rbt.landcover AS
WITH leafcycle AS (
    SELECT
        -- Normalize leaf types
        CASE
            WHEN leaf_type ILIKE 'broad%' THEN 'broadleaved'
            WHEN leaf_type ILIKE 'con%' THEN 'coniferous'
            WHEN leaf_type ILIKE 'needle%' THEN 'needleleaved'
            -- ...
        END AS leaf_type,
        -- Classify wetland subtypes
        CASE
            WHEN subclass IN ('wetland') AND (tags -> 'wetland' ILIKE 'mangr%ve') 
                THEN 'mangrove'
            WHEN subclass IN ('wetland') AND (tags -> 'wetland' ILIKE '%bog%') 
                THEN 'bog'
            -- ... 10+ wetland classifications
        END AS subclass,
        -- Handle multipolygon decomposition
        CASE
            WHEN ST_GeometryType(geometry) = 'ST_MultiPolygon' THEN
                ROW_NUMBER() OVER (PARTITION BY osm_id 
                    ORDER BY ST_Area(geom) DESC)
        END AS rank
        -- ...
```

#### **WATER Materialized View**
Advanced clustering and union operations:

```sql
CREATE MATERIALIZED VIEW rbt.water AS
WITH clustered_inland AS (
  SELECT
    subclass,
    unnest(ST_ClusterWithin(
      ST_SimplifyPreserveTopology(ST_MakeValid(geometry), 0.0001), 
      500  -- 500m clustering distance
    )) as cluster_geom
  FROM rbt.water_surface
  WHERE geometry IS NOT NULL AND ST_IsValid(geometry)
  GROUP BY subclass
),
water_inland AS (
  SELECT subclass, ST_Union(cluster_geom) AS geometry
  FROM clustered_inland
  GROUP BY subclass
)
-- Similar processing for ocean polygons with 1.5km clustering
```
- Uses ST_ClusterWithin for intelligent polygon merging
- Simplifies geometries while preserving topology
- Separate clustering distances for inland vs ocean

#### **MOUNTAIN_LABEL Materialized View**
Generates label lines using medial axis:

```sql
CREATE MATERIALIZED VIEW rbt.mountain_label AS
WITH medial_axis AS (
    SELECT 
        *,
        CG_ApproximateMedialAxis(geometry) as medial_geom
    FROM naturalearth.ne_10m_geography_regions_polys
),
ranked_lines AS (
    SELECT 
        *,
        ST_Length(line_segment) as segment_length,
        ROW_NUMBER() OVER (PARTITION BY ne_id 
            ORDER BY ST_Length(line_segment) DESC) as rn
    FROM medial_lines
)
SELECT * FROM ranked_lines WHERE rn = 1;
```
- Uses CG_ApproximateMedialAxis for centerline generation
- Selects longest segment for label placement
- Preserves multilingual name attributes

## Processing Pipelines

The physical data processing workflow now uses unified, configurable scripts that support multiple projections and selective layer processing.

### Unified Tile Generation Pipeline (`tiles.sh`)

The unified `tiles.sh` script supports both EPSG:3857 (Web Mercator) and EPSG:3395 (World Mercator) projections with selective layer processing.

#### Key Features:
- **Configurable Projections**: Support for EPSG:3857 and EPSG:3395
- **Selective Layer Processing**: Choose specific layers or process all
- **Built-in Filters**: JSON-based zoom-level feature selection
- **Tile Consolidation**: Optional tile-join for unified MBTiles output
- **BTIS Metadata Support**: Add Background Tile Information Standard metadata
- **Resume Capability**: Skip existing intermediate files for faster re-runs

#### Common Usage Patterns:

**Generate All Layers (Default Web Mercator):**
```bash
./tiles.sh --all
# Equivalent to: ./tiles.sh --projection 3857 --all
```

**Selective Layer Generation:**
```bash
# Generate specific layers in World Mercator
./tiles.sh --projection 3395 --water --landcover --glacier

# Generate terrain-related layers with consolidation
./tiles.sh --contour --glacier --mountain --tile-join --add-btis

# Generate single layer with BTIS metadata
./tiles.sh --projection 3857 --builtuparea --add-btis
```

#### Layer Processing Functions:

**Builtuparea Generation:**
```bash
# Export to FlatGeoBuf with projection transformation
ogr2ogr -lco SPATIAL_INDEX=NO -t_srs "$PROJECTION" "$fgb_file" \
    "$DB_CONNECTION" rbt.builtuparea -skipfailures

# Generate tiles with built-in filter
tippecanoe -j "$BUILTUP_FILTER" \
    -o "$OUTPUT_DIR/builtuparea_${PROJECTION_CODE}.mbtiles" \
    -P -s EPSG:3857 -Z 3 -z 13 \
    --single-precision --extra-detail=14 \
    --simplify-only-low-zooms \
    -n builtuparea -l builtuparea "$fgb_file"
```

**Water Processing with Smart Reduction:**
```bash
tippecanoe \
    -o "$OUTPUT_DIR/water_${PROJECTION_CODE}.mbtiles" \
    -P -s EPSG:3857 -z 13 \
    --drop-smallest-as-needed \    # Smart feature reduction
    -M 200000 \                    # Max tile size limit
    --detect-longitude-wraparound \ # Handle antimeridian
    --hilbert --coalesce \         # Optimize tile organization
    -n water -l water "$fgb_file"
```

**Landcover with Progressive Zoom:**
```bash
# Built-in landcover filter handles zoom-based feature selection
tippecanoe -j "$LANDCOVER_FILTER" \
    -o "$OUTPUT_DIR/landcover_${PROJECTION_CODE}.mbtiles" \
    -P -s EPSG:3857 -Z 4 -z 13 \
    --drop-smallest-as-needed \
    -T osm_id:int -T rank:int -T area:float \
    -n landcover -l landcover "$fgb_file"
```

#### Built-in Filter Examples:

**Contour Filter (Progressive Line Display):**
```json
{
  "*": [
    "any",
    ["all", [">=", "$zoom", 8], ["==", "nth_line", 10]],
    ["all", [">=", "$zoom", 10], ["in", "nth_line", 5, 10]],
    ["all", [">=", "$zoom", 12], ["in", "nth_line", 5, 10, 2]],
    ["all", [">=", "$zoom", 13]]
  ]
}
```

**Glacier Filter (Source Switching):**
```json
{
  "*": [
    "any",
    ["all", ["<=", "$zoom", 7], ["==", "source", "ne"]],
    ["all", [">=", "$zoom", 7], ["==", "source", "osm"]]
  ]
}
```

### EPSG:4326 Pipeline (Geographic WGS 84)

The `4326_tiles.sh` script uses GDAL's MVT driver for direct PostgreSQL to MVT conversion.

#### Unique Approach:
```bash
ogr2ogr \
    -f MVT \                           # Direct MVT format output
    -t_srs EPSG:4326 \                # Geographic coordinates
    "$OUTPUT_DIR" \
    "$DB_CONNECTION" \
    -oo ACTIVE_SCHEMA=rbt \           # Schema specification
    -oo TABLES="$ALL_PHYSICAL_TABLES" \ # All tables at once
    -dsco FORMAT=DIRECTORY \          # Directory tile structure
    -dsco CONF="$LAYER_CONFIG" \      # JSON configuration
    -dsco TILING_SCHEME="EPSG:4326,-180,180,360" \ # Custom scheme
    -dsco MINZOOM="$MIN_ZOOM" \
    -dsco MAXZOOM="$MAX_ZOOM" \
    -dsco MAX_SIZE="$MAX_TILE_SIZE" \
    -dsco MAX_FEATURES="$MAX_FEATURES"
```

#### Key Characteristics:
- **Single Command Processing**: Processes all layers in one ogr2ogr command
- **JSON Configuration**: Uses `physical_layer_config.json` for layer definitions
- **Directory Output**: Creates directory-based tile structure instead of MBTiles
- **Custom Tiling**: EPSG:4326 geographic coordinate tiling scheme
- **Layer Grouping**: Organizes tables by logical categories

#### Table Organization:
```bash
BUILTUPAREA_TABLES="rbt.builtuparea_ne,rbt.builtuparea_osm"
CONTOUR_TABLES="rbt.contour_z8,rbt.contour_z10,rbt.contour_z12,rbt.contour,rbt.contour_glacier_z8,rbt.contour_glacier_z10,rbt.contour_glacier_z12,rbt.contour_glacier"
GLACIER_TABLES="rbt.glacier_ne,rbt.glacier_osm"
LANDCOVER_TABLES="rbt.landcover_z4,rbt.landcover_z6,rbt.landcover_z9,rbt.landcover_z10,rbt.landcover"
MOUNTAIN_TABLES="rbt.mountain_label"
PARK_TABLES="rbt.park"
WATER_TABLES="rbt.inland_water_intermittent_dissolved,rbt.water_simplified,rbt.water,rbt.ne_water_label,rbt.waterway"
```

### Tile Consolidation and Metadata

#### Tile Joining:
```bash
# Consolidate multiple layer MBTiles into single file
tile-join -f -pk \
    -o "$OUTPUT_DIR/physical_${PROJECTION_CODE}.mbtiles" \
    "$OUTPUT_DIR/builtuparea_${PROJECTION_CODE}.mbtiles" \
    "$OUTPUT_DIR/water_${PROJECTION_CODE}.mbtiles" \
    "$OUTPUT_DIR/landcover_${PROJECTION_CODE}.mbtiles"
```

#### BTIS Metadata Addition:
```bash
# Add Background Tile Information Standard metadata
sqlite3 "$target_file" "INSERT OR REPLACE INTO metadata(name,value) VALUES('crs','EPSG:${PROJECTION_CODE}');"
sqlite3 "$target_file" "INSERT OR REPLACE INTO metadata(name,value) VALUES('tile_origin_upper_left_x','${TILE_ORIGIN_X}');"
sqlite3 "$target_file" "INSERT OR REPLACE INTO metadata(name,value) VALUES('btp_schema_version','1.0.0');"
```

## Layer Categories

### 1. Terrain

**Tables:** `contour`, `contour_glacier`, `mountain_label`

**Purpose:** Elevation data and terrain features

**Processing Details:**
- Contours filtered by `nth_line` for zoom-based density
- Separate glacier contours for ice-covered areas
- Mountain labels generated from medial axis of geographic regions

**Zoom Strategy:**
- Z8: Every 10th contour line (nth_line = 10)
- Z10: Every 5th contour line (nth_line = 5)
- Z12: Every 2nd contour line (nth_line = 2)
- Z13: All contour lines

### 2. Hydrology

**Tables:** `water`, `water_simplified`, `waterway`, `inland_water_intermittent`, `ne_water_label`

**Purpose:** All water features including oceans, lakes, rivers, and intermittent water

**Processing Details:**
- Water bodies clustered and merged by proximity
- Simplified version for low zoom levels (area > 5,000,000)
- Intermittent water stored separately with dissolved boundaries
- Marine labels from Natural Earth

**Key Features:**
- 500m clustering for inland water
- 1.5km clustering for ocean polygons
- 2km clustering for simplified ocean
- Waterway classification into 40+ subtypes

### 3. Land Surface

**Tables:** `landcover`, `landcover_labels`, `glacier`, `builtuparea`

**Purpose:** Natural land cover, glaciers, and urban areas

**Landcover Processing:**
- Progressive zoom levels (z4, z6, z9, z10, z12+)
- Leaf type/cycle classification for forests
- Wetland subtype classification
- Multipolygon decomposition with ranking

**Zoom-based Filtering:**
```sql
-- Z4: Only large sandy/beach areas
WHERE area >= 15625000 AND subclass IN ('sand', 'dune', 'beach')

-- Z6: Add wetlands
WHERE area >= 15625000 AND subclass IN (..., 'bog', 'mangrove', 'marsh')

-- Z10: Add forests and agriculture
WHERE subclass IN (..., 'forest', 'wood', 'farm', 'farmland')
```

### 4. Recreation

**Tables:** `park`

**Purpose:** Parks and protected areas

**Classification:**
```sql
WHERE subclass IN ('national_park', 'nature_reserve', 'protected_area',
                   'state_park', 'regional', 'golf_course', ...)
```

## Detailed Layer Documentation

### Water Layer Processing

The water layer demonstrates complex spatial processing:

#### Data Flow:
1. **Import** → `import.water` table with raw OSM data
2. **Classification** → `classify_water_type()` function normalizes subtypes
3. **Surface Creation** → `water_surface` materialized view filters permanent water
4. **Clustering** → `water` view clusters and merges nearby polygons
5. **Simplification** → `water_simplified` for low zoom levels

#### Clustering Algorithm:
```sql
unnest(ST_ClusterWithin(
    ST_SimplifyPreserveTopology(ST_MakeValid(geometry), 0.0001), 
    500  -- clustering distance in meters
))
```
- Groups nearby water features within 500m
- Simplifies boundaries while preserving topology
- Validates and repairs geometries

### Landcover Layer Processing

Complex multi-stage processing:

#### Attribute Processing:
1. **Leaf Type Normalization**:
   - `broad%` → `broadleaved`
   - `con%` → `coniferous`
   - `needle%` → `needleleaved`

2. **Leaf Cycle Inference**:
   - Coniferous defaults to evergreen
   - Broadleaved defaults to deciduous
   - Mixed remains mixed

3. **Wetland Classification**:
   - Extracts from JSONB tags
   - 10+ wetland subtypes identified
   - Fallback to `unknown_wetland`

#### Multipolygon Handling:
```sql
CASE
    WHEN is_multipolygon = 'yes' THEN
        ROW_NUMBER() OVER (PARTITION BY osm_id 
            ORDER BY ST_Area(geom) DESC)
END AS rank
```
- Decomposes multipolygons
- Ranks parts by area
- Preserves largest features

### Mountain Label Generation

Uses advanced PostGIS functions:

```sql
CG_ApproximateMedialAxis(geometry) as medial_geom
```
- Generates centerline through polygon
- Extracts line segments
- Selects longest segment for label
- Preserves 28 language variants

### Contour Processing

Elevation-based filtering:

```bash
tippecanoe -J contour/contour_filter \
    -o "$OUTPUT_DIR/contour_3395.mbtiles" \
    -Z 8 -z 13  # Contours only at high zoom
```

Filter configuration controls:
- Elevation intervals
- Line weight by importance
- Negative elevation handling
- Glacier overlay separation

## Command Reference

### SQL Processing Commands

#### **`process-physical-schemas.sh` Usage**
```bash
# Process all SQL scripts
./setup/data-sources/schemas/physical/process-physical-schemas.sh --all

# Process individual components
./setup/data-sources/schemas/physical/process-physical-schemas.sh --physical-core    # Core layers
./setup/data-sources/schemas/physical/process-physical-schemas.sh --landcover       # Landcover with zoom-level views
./setup/data-sources/schemas/physical/process-physical-schemas.sh --water-features  # Water processing with clustering
./setup/data-sources/schemas/physical/process-physical-schemas.sh --terrain         # Terrain/contour processing

# Help and options
./setup/data-sources/schemas/physical/process-physical-schemas.sh --help
```

**Environment Variables Required:**
- `PG_USR`: PostgreSQL username
- `PG_PASS`: PostgreSQL password

### Tile Generation Commands

#### **`generate-physical-3857-3395.sh` Usage**
```bash
# Generate all layers (default Web Mercator)
./production/tile-generation/physical/generate-physical-3857-3395.sh --all

# Projection selection
./production/tile-generation/physical/generate-physical-3857-3395.sh --projection 3857 --all    # Web Mercator (default)
./production/tile-generation/physical/generate-physical-3857-3395.sh --projection 3395 --all    # World Mercator

# Selective layer generation
./production/tile-generation/physical/generate-physical-3857-3395.sh --water --landcover --glacier
./production/tile-generation/physical/generate-physical-3857-3395.sh --projection 3395 --builtuparea --contour

# Consolidation and metadata options
./production/tile-generation/physical/generate-physical-3857-3395.sh --all --tile-join                    # Merge layers into single MBTiles
./production/tile-generation/physical/generate-physical-3857-3395.sh --all --tile-join --add-btis         # Add BTIS metadata
./production/tile-generation/physical/generate-physical-3857-3395.sh --projection 3395 --water --add-btis # Single layer with metadata

# Help and options
./production/tile-generation/physical/generate-physical-3857-3395.sh --help
```

**Layer Options:**
- `--builtuparea`: Urban areas (OSM + Natural Earth)
- `--contour`: Regular and glacier contours
- `--glacier`: Glacier polygons from multiple sources
- `--landcover`: Land cover polygons and labels
- `--mountain`: Mountain label lines
- `--park`: Parks and protected areas
- `--water`: Water bodies with clustering
- `--water-label`: Water body labels
- `--waterway`: Linear water features
- `--inland-water`: Intermittent water features

#### **`generate-physical-4326.sh` Usage**
```bash
# Generate all layers in EPSG:4326 using GDAL MVT driver
./production/tile-generation/physical/generate-physical-4326.sh
```

**Environment Variables Required:**
- `PG_HOST`: PostgreSQL host
- `PG_USR`: PostgreSQL username
- `PG_PASS`: PostgreSQL password

### ogr2ogr Options for Physical Data

#### FlatGeoBuf Export (`tiles.sh`)
| Option | Description | Physical Example |
|--------|-------------|------------------|
| `-lco SPATIAL_INDEX=NO` | Skip FGB spatial index | Used for temporary files |
| `-t_srs` | Target projection | `-t_srs EPSG:3395` |
| `-skipfailures` | Continue on geometry errors | Essential for OSM data |

#### Direct MVT Generation (`4326_tiles.sh`)
| Option | Description | Physical Example |
|--------|-------------|------------------|
| `-f MVT` | Output format | Direct MVT generation |
| `-oo ACTIVE_SCHEMA=rbt` | Schema specification | PostgreSQL schema |
| `-oo TABLES="table1,table2"` | Table list | Comma-separated table names |
| `-dsco CONF="config.json"` | Layer configuration | JSON-based layer definitions |
| `-dsco TILING_SCHEME="EPSG:4326,-180,180,360"` | Custom tiling | Geographic coordinate tiling |

### tippecanoe Options for Physical Features

#### Universal Options
| Option | Use Case | Example |
|--------|----------|---------|
| `-j "$FILTER"` | Built-in JSON filter | Zoom-based feature selection |
| `-P` | Parallel processing | Faster tile generation |
| `-s EPSG:3857` | Output projection | Web Mercator tiles |
| `--single-precision` | 32-bit coordinates | Smaller tile sizes |
| `--extra-detail=14` | Preserve precision | For accurate contours |

#### Terrain-Specific Options
| Option | Use Case | Example |
|--------|----------|---------|
| `-Z 8 -z 13` | Contour zoom range | Start contours at zoom 8 |
| `-T elevation:int` | Elevation attribute | Integer elevation values |
| `-T nth_line:int` | Line density control | nth_line filtering |

#### Hydrology Options
| Option | Use Case | Example |
|--------|----------|---------|
| `--drop-smallest-as-needed` | Smart feature reduction | Remove small features at low zoom |
| `-M 200000` | Max tile size | Limit water polygon complexity |
| `--detect-longitude-wraparound` | Antimeridian handling | Global water bodies |
| `--hilbert --coalesce` | Tile optimization | Better spatial organization |

#### Landcover Options
| Option | Use Case | Example |
|--------|----------|---------|
| `-Z 4 -z 13` | Progressive zoom | Start landcover at zoom 4 |
| `-T osm_id:int` | Feature ID preservation | Maintain OSM identifiers |
| `-T rank:int` | Feature ranking | Multipolygon part ranking |
| `-T area:float` | Area attributes | Area-based filtering |

### Built-in Filter Configurations

The unified `tiles.sh` script includes built-in JSON filters for zoom-based feature selection:

**Builtup Area Filter:**
```json
{
  "*": [
    "any",
    ["all", ["<=", "$zoom", 8], ["==", "class", "ne"]],
    ["all", [">=", "$zoom", 8], ["==", "class", "osm"]]
  ]
}
```
- Switches from Natural Earth (low zoom) to OSM (high zoom) at zoom level 8

**Landcover Filter:**
```json
{
  "*": [
    "any",
    ["all", [">=", "$zoom", 4], [">=", "area", 15625000], ["in", "subclass", "sand", "dune", "beach"]],
    ["all", [">=", "$zoom", 6], [">=", "area", 15625000], ["in", "subclass", "sand", "bog", "marsh", "wetland"]],
    ["all", [">=", "$zoom", 9], ["in", "subclass", "sand", "bog", "marsh", "wetland"]],
    ["all", [">=", "$zoom", 10], ["in", "subclass", "forest", "wood", "farm", "grassland"]],
    ["all", [">=", "$zoom", 12]]
  ]
}
```
- Progressive feature display based on zoom level and area
- Starts with large sandy/beach areas at zoom 4
- Adds wetlands at zoom 6, forests and agriculture at zoom 10

**Glacier Filter:**
```json
{
  "*": [
    "any",
    ["all", ["<=", "$zoom", 7], ["==", "source", "ne"]],
    ["all", [">=", "$zoom", 7], ["==", "source", "osm"]]
  ]
}
```
- Switches from Natural Earth to OSM glacier data at zoom level 7

## Workflow Examples

### Complete Processing Workflow

**1. Database Setup (Run SQL Processing):**
```bash
# Process all SQL components
./sql.sh --all

# Or process selectively
./sql.sh --physical --landcover --water
```

**2. Generate Tiles for Different Projections:**
```bash
# Web Mercator tiles with all layers
./tiles.sh --all --tile-join --add-btis

# World Mercator tiles for specific layers
./tiles.sh --projection 3395 --water --landcover --glacier --tile-join

# Geographic coordinate tiles
./4326_tiles.sh
```

**3. Selective Layer Processing:**
```bash
# Generate only water-related layers
./tiles.sh --water --waterway --inland-water --tile-join

# Generate terrain layers in World Mercator
./tiles.sh --projection 3395 --contour --glacier --mountain --add-btis
```

### Development and Testing Workflow

**1. Test Single Layer:**
```bash
# Test landcover processing
./sql.sh --landcover
./tiles.sh --landcover

# Test water processing with specific projection
./sql.sh --water
./tiles.sh --projection 3395 --water --add-btis
```

**2. Incremental Processing:**
```bash
# Add new layer type without reprocessing existing
./sql.sh --contour
./tiles.sh --contour --tile-join  # Joins with existing tiles
```

**3. Performance Testing:**
```bash
# Generate with different projections for comparison
./tiles.sh --projection 3857 --all --tile-join
./tiles.sh --projection 3395 --all --tile-join
./4326_tiles.sh
```

### Production Deployment Workflow

**1. Full Processing Pipeline:**
```bash
#!/bin/bash
set -e

# Set environment variables
export PG_HOST="your-postgres-host"
export PG_USR="your-username"
export PG_PASS="your-password"

# Process all SQL components
echo "Processing database layers..."
./sql.sh --all

# Generate tiles for all projections
echo "Generating Web Mercator tiles..."
./tiles.sh --all --tile-join --add-btis

echo "Generating World Mercator tiles..."
./tiles.sh --projection 3395 --all --tile-join --add-btis

echo "Generating geographic coordinate tiles..."
./4326_tiles.sh

echo "Physical tile processing completed successfully!"
```

**2. Layer-Specific Updates:**
```bash
# Update only landcover data
./sql.sh --landcover
./tiles.sh --landcover --tile-join  # Updates existing consolidated tiles

# Update water processing with new classification
./sql.sh --water
./tiles.sh --water --waterway --inland-water --tile-join
```

## Performance Optimizations

### Database Optimizations

1. **Materialized Views**: Pre-compute expensive operations
   - Water clustering
   - Landcover classification
   - Glacier merging

2. **Strategic Indexing**:
   ```sql
   -- Compound index for common queries
   CREATE INDEX idx_landcover_subclass_area 
   ON rbt.landcover(subclass, area);
   
   -- Partial index for filtered queries
   CREATE INDEX idx_water_named 
   ON rbt.water_surface(name) 
   WHERE name IS NOT NULL;
   ```

3. **Memory Configuration**:
   ```sql
   SET LOCAL work_mem = '1GB';
   SET LOCAL maintenance_work_mem = '2GB';
   ```

### Processing Optimizations

1. **Parallel Execution**: All layer generation functions run independently
2. **RAM Disk Usage**: `-t /dev/shm` for temporary files (if available)
3. **Progressive Enhancement**: Zoom-specific views reduce low-zoom data
4. **Clustering Strategy**: Pre-merge nearby features in database

### Tile Generation Optimizations

1. **Filter Early**: Use SQL WHERE clauses before export
2. **Simplify Appropriately**: `--simplify-only-low-zooms`
3. **Smart Dropping**: Algorithm-based feature reduction
4. **Type Coercion**: Specify data types to reduce storage

## Troubleshooting

### Common Issues and Solutions

#### 1. Contour Data Missing
**Issue**: Contour views fail to create
```sql
ERROR: relation "rbt.contour" does not exist
```

**Solution**: Script checks for contour tables:
```sql
IF EXISTS (SELECT 1 FROM information_schema.tables 
           WHERE table_schema = 'rbt' AND table_name = 'contour') THEN
    -- Create contour views
END IF;
```

#### 2. Invalid Geometries
**Issue**: Clustering fails with invalid geometry errors

**Solution**: Pre-validate and repair:
```sql
ST_MakeValid(geometry)
WHERE ST_IsValid(geometry)
```

#### 3. Memory Errors
**Issue**: Out of memory during materialized view creation

**Solutions**:
- Increase work_mem: `SET work_mem = '2GB';`
- Process in smaller chunks
- Use partial materialization

#### 4. Slow Landcover Processing
**Issue**: Landcover materialized view takes hours

**Solutions**:
- Ensure indexes exist before creation
- Analyze source tables first
- Consider partitioning by area

#### 5. Water Polygon Gaps
**Issue**: Gaps between water polygons at tile boundaries

**Solution**: Increase clustering distance:
```sql
ST_ClusterWithin(geometry, 1000)  -- Increase from 500m
```

### Validation Queries

Check materialized view row counts:
```sql
SELECT 'landcover' as view_name, COUNT(*) as rows FROM rbt.landcover
UNION ALL
SELECT 'water_surface', COUNT(*) FROM rbt.water_surface
UNION ALL
SELECT 'glacier', COUNT(*) FROM rbt.glacier;
```

Verify zoom level coverage:
```sql
-- Check landcover zoom distribution
SELECT 'z4' as zoom, COUNT(*) FROM rbt.landcover_z4
UNION ALL SELECT 'z6', COUNT(*) FROM rbt.landcover_z6
UNION ALL SELECT 'z9', COUNT(*) FROM rbt.landcover_z9
UNION ALL SELECT 'z10', COUNT(*) FROM rbt.landcover_z10;
```

### Performance Monitoring

Monitor materialized view refresh times:
```sql
\timing on
REFRESH MATERIALIZED VIEW CONCURRENTLY rbt.landcover;
```

Check index usage:
```sql
SELECT schemaname, tablename, indexname, idx_scan
FROM pg_stat_user_indexes
WHERE schemaname = 'rbt'
ORDER BY idx_scan DESC;
```

## BTIS Metadata

The 3395 pipeline adds BTIS (Background Tile Information Standard) metadata:

```sql
-- CRS metadata
INSERT OR REPLACE INTO metadata(name,value) VALUES('crs','EPSG:3395');

-- Tile origin (upper-left corner in projection units)
INSERT OR REPLACE INTO metadata(name,value) 
VALUES('tile_origin_upper_left_x','-20037508.343');
INSERT OR REPLACE INTO metadata(name,value) 
VALUES('tile_origin_upper_left_y','20037508.343');

-- Tile dimension at zoom 0
INSERT OR REPLACE INTO metadata(name,value) 
VALUES('tile_dimension_zoom_0','40075016.686');

-- Schema version
INSERT OR REPLACE INTO metadata(name,value) 
VALUES('btp_schema_version','1.0.0');
```

## Best Practices

1. **Always validate geometries** before processing with ST_IsValid()
2. **Use materialized views** for complex spatial operations
3. **Create indexes CONCURRENTLY** to avoid locking
4. **Test with regional extracts** before processing global data
5. **Monitor disk space** - water processing can generate large intermediate files
6. **Version control** filter configurations and SQL modifications
7. **Document** any deviations from standard Natural Earth attributes
8. **Validate** zoom level transitions for smooth rendering

## Data Sources and Attribution

### OpenStreetMap
- Primary source for detailed landcover, water, and waterway features
- License: ODbL (Open Database License)
- Update frequency: Continuous

### Natural Earth
- Source for generalized features at low zoom levels
- Includes: urban areas, glaciers, geographic regions, marine polygons
- License: Public domain
- Version: 10m resolution datasets

### OSM Ocean
- Derived water polygons from OSM coastlines
- Pre-processed for efficient rendering
- Updated periodically

### Contour Data
- Source varies by implementation
- May include: SRTM, ASTER GDEM, or custom DEMs
- Check `rbt.contour` table for elevation units and intervals

## References

- [GDAL/OGR Documentation](https://gdal.org/programs/ogr2ogr.html)
- [Tippecanoe Documentation](https://github.com/mapbox/tippecanoe)
- [PostGIS Documentation](https://postgis.net/docs/)
- [PostGIS Clustering Functions](https://postgis.net/docs/ST_ClusterWithin.html)
- [Natural Earth Data](https://www.naturalearthdata.com/)
- [OpenStreetMap Water Wiki](https://wiki.openstreetmap.org/wiki/Water)
- [Mapbox Vector Tile Specification](https://docs.mapbox.com/vector-tiles/specification/)
- [FlatGeoBuf Specification](https://flatgeobuf.org/)
- [MBTiles Specification](https://github.com/mapbox/mbtiles-spec)

## 📚 Related Documentation

- **[← Back to Home](index.md)**
- **[Getting Started Guide](getting-started.md)** - Setup walkthrough and first steps
- **[Architecture Overview](architecture.md)** - System design and data flow
- **[Cultural Layers](cultural-layers.md)** - Human infrastructure processing
- **[Database Initialization](database-initialization.md)** - Database setup process
- **[OSM Import Pipeline](osm-import.md)** - OpenStreetMap data processing
- **[Production Documentation](production-readme.md)** - Tile generation operations
