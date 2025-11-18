# Cultural Data Processing Workflow

## Overview

This directory contains the complete workflow for processing cultural geospatial data and generating vector tiles in multiple projections. The workflow transforms raw OpenStreetMap (OSM) and other geospatial data stored in PostgreSQL/PostGIS into optimized Mapbox Vector Tiles (MVT) for web mapping applications.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Tools and Technologies](#tools-and-technologies)
3. [Database Schema Setup](#database-schema-setup)
4. [Processing Pipelines](#processing-pipelines)
5. [Layer Categories](#layer-categories)
6. [Detailed Layer Documentation](#detailed-layer-documentation)
7. [Command Reference](#command-reference)
8. [Performance Considerations](#performance-considerations)

## Architecture Overview

The cultural data processing workflow consists of three main components:

1. **Database Layer** (`cultural.sql`): Creates materialized views, indexes, and optimized data structures in PostgreSQL/PostGIS
2. **Tile Generation** (3 projection scripts): Exports data and generates vector tiles using different coordinate systems
3. **Configuration** (`cultural_layer_config.json`): Defines layer properties and zoom levels for tile generation

```
PostgreSQL Database (rbt schema)
        ↓
    Schema processing (via setup/data-sources/schemas/cultural/)
        ↓
    Three parallel pipelines:
    ├── generate-cultural-3857-3395.sh → EPSG:3395 (World Mercator)
    ├── generate-cultural-3857-3395.sh → EPSG:3857 (Web Mercator) 
    └── generate-cultural-4326.sh → EPSG:4326 (WGS 84)
        ↓
    MBTiles output (consolidated vector tiles)
```

## Tools and Technologies

### Core Tools

#### **ogr2ogr (GDAL)**
A command-line utility for converting between geospatial data formats. Used to:
- Export data from PostgreSQL to FlatGeoBuf (.fgb) intermediate format
- Transform coordinate systems during export
- Handle schema and table specifications

#### **tippecanoe**
A Mapbox tool for building vector tilesets from large GeoJSON/FlatGeoBuf datasets. Provides:
- Intelligent feature simplification and dropping
- Multi-zoom level optimization
- Attribute type specification and filtering

#### **tile-join**
Companion tool to tippecanoe for merging multiple MBTiles files into a single consolidated tileset.

#### **PostgreSQL/PostGIS**
- **PostgreSQL**: Relational database storing the raw geospatial data
- **PostGIS**: Spatial extension providing geographic functions and types
- Used for data storage, transformation, and optimization

### Supporting Technologies

- **FlatGeoBuf (FGB)**: High-performance binary format for geographic data, used as intermediate format
- **MBTiles**: SQLite-based container format for storing tilesets
- **Bash scripting**: Orchestrates the entire pipeline

## Database Schema Setup

The `cultural.sql` file creates an extensive set of materialized views, indexes, and optimized data structures. Here's a detailed breakdown:

### Index Creation Strategy

The script creates multiple types of indexes for optimal query performance:

#### **Spatial Indexes (GIST)**
Used for geometric operations and spatial queries:

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_highway_geometry 
ON import.highway USING gist(geometry);
```
- `CONCURRENTLY`: Allows table reads during index creation
- `GIST`: Generalized Search Tree, optimized for spatial data
- Applied to all geometry columns across tables

#### **B-tree Indexes**
For standard column lookups and filtering:

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_highway_subclass 
ON import.highway USING btree(subclass);
```
- Used for categorical data (subclass, class, type fields)
- Optimizes WHERE clauses and JOIN operations

#### **Trigram Indexes (GIN)**
For text search and pattern matching:

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_highway_ref 
ON import.highway USING gin(ref gin_trgm_ops);
```
- `gin_trgm_ops`: Trigram operations for fuzzy text matching
- Used for name and reference searches

#### **JSONB Indexes**
For querying within JSON tag fields:

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_highway_lifecycle_tags 
ON import.highway USING GIN (tags)
WHERE tags ? ANY(ARRAY['proposed','construction','disused','abandoned','demolished','razed']);
```
- Partial index only on rows with specific lifecycle tags
- Optimizes tag-based filtering

### Materialized Views

The script creates several materialized views to pre-compute complex queries:

#### **Highway Enhancement Views**

```sql
CREATE MATERIALIZED VIEW import.highway_surface_subclass AS
SELECT DISTINCT 
  h.id,
  -- Complex CASE statement for surface classification
  CASE 
    WHEN h.surface = 'concrete' THEN 'paved_smooth'
    WHEN h.surface = 'asphalt' THEN 'paved_smooth'
    -- ... more conditions
  END AS surface_subclass
FROM import.highway h;
```
- Pre-computes surface classifications
- Reduces runtime computation overhead

#### **Reference Number Extraction**

```sql
CREATE MATERIALIZED VIEW import.highway_ref AS
WITH ref_arrays AS (
  SELECT 
    id,
    string_to_array(ref, ';') AS ref_array
  FROM import.highway
  WHERE ref IS NOT NULL
)
-- Extract numeric portions from references
SELECT DISTINCT
  id,
  CAST(substring(ref_item FROM '^\d+') AS INTEGER) AS ref_number
FROM ref_arrays, unnest(ref_array) AS ref_item
WHERE substring(ref_item FROM '^\d+') IS NOT NULL;
```
- Extracts numeric route numbers from complex reference strings
- Handles semicolon-delimited multiple references

### Enhanced Tables and Views

The script creates enhanced versions of base tables with additional computed fields:

#### **Airports Enhanced**

```sql
CREATE MATERIALIZED VIEW rbt.airports_enhanced AS
WITH airport_aerodromes AS (
  -- Complex JOIN between multiple data sources
  SELECT 
    a.*,
    ap.osm_id AS osm_id_aerodrome,
    ap.area AS osm_aerodrome_area,
    -- Calculate importance ranking
    CASE
      WHEN a.use = 'Military' THEN 10
      WHEN a.airport_type = 'large_airport' THEN 9
      WHEN a.airport_type = 'medium_airport' THEN 8
      -- ... more ranking logic
    END AS rank
  FROM import.airports a
  LEFT JOIN import.aerodrome_polygon ap ON ...
)
```
- Combines airport data from multiple sources
- Calculates importance rankings for rendering prioritization

#### **Railway Enhanced**

```sql
CREATE MATERIALIZED VIEW rbt.railway_enhanced AS
WITH railway_subclass AS (
  SELECT 
    r.*,
    -- Enhance classification based on tags
    CASE
      WHEN r.subclass = 'rail' AND r.usage = 'main' THEN 'main'
      WHEN r.subclass = 'rail' AND r.usage = 'branch' THEN 'branch'
      -- ... classification logic
    END AS enhanced_class
  FROM import.railway r
)
```

## Processing Pipelines

### EPSG:3395 Pipeline (World Mercator)

The `generate-cultural-3857-3395.sh` script generates tiles in World Mercator projection (via `--projection 3395`), suitable for global datasets with better area preservation than Web Mercator.

#### Key Characteristics:
- Better for polar regions than Web Mercator
- Preserves shapes better at high latitudes
- Less distortion for global analysis

#### Pipeline Flow:
1. Export from PostgreSQL to FlatGeoBuf with projection transformation
2. Generate tiles using tippecanoe with specific parameters
3. Merge all layer tiles into single MBTiles
4. Add BTIS metadata for compliance

### EPSG:3857 Pipeline (Web Mercator)

The `generate-cultural-3857-3395.sh` script (default behavior) generates standard Web Mercator tiles, the de facto standard for web mapping.

#### Key Characteristics:
- Standard for Google Maps, OpenStreetMap, most web maps
- Optimized for web tile serving
- Fast rendering but distorts areas at high latitudes

#### Differences from 3395:
- No tile projection transformation needed (tippecanoe native)
- Different layer naming conventions (includes projection suffix)
- No BTIS metadata addition

### EPSG:4326 Pipeline (Geographic WGS 84)

The `generate-cultural-4326.sh` script uses GDAL's MVT driver for direct generation.

#### Key Characteristics:
- Uses degrees for coordinates
- No projection distortion
- Custom tiling scheme required

#### Unique Approach:
```bash
ogr2ogr \
  -f MVT \                           # Mapbox Vector Tiles format
  -t_srs EPSG:4326 \                # Target SRS
  "$OUTPUT_DIR" \
  "$DB_CONNECTION" \
  -dsco FORMAT=DIRECTORY \           # Directory-based tile structure
  -dsco TILING_SCHEME="EPSG:4326,-180,180,360"  # Custom scheme
```

## Layer Categories

### 1. Aeroway (Aviation)

**Tables:** `aeroway_surface`, `airports`, `heliports`, `runway_curve`

**Purpose:** Airport infrastructure including runways, terminals, and helipads

**Key Processing:**
- Surface polygons for runways and taxiways
- Point data for airports with ranking
- Curve geometries for runway centerlines

### 2. Boundary (Administrative)

**Tables:** `adm0_labels`, `adm0_lines`, `adm1_labels`, `adm1_lines`, `adm2_labels`, `adm2_lines`

**Purpose:** Administrative boundaries at country (ADM0), state/province (ADM1), and county (ADM2) levels

**Key Processing:**
- Separate label points and boundary lines
- Simplified geometries for low zooms
- No shared node simplification to preserve boundaries

### 3. Building

**Tables:** `building`, `building_z10`, `building_z11`, `building_z12`

**Purpose:** Building footprints with zoom-based generalization

**Key Processing:**
- Progressive detail by zoom level
- Height and area attributes preserved
- Hilbert curve ordering for efficient tiling

### 4. Transportation

**Tables:** `highway`, `railway`, `ferry`, `lock`, `port_surface`, `railway_station`, `yard_label`

**Purpose:** All transportation infrastructure

**Highway Processing:**
- Zoom-specific views (z4-z12) with different feature selection
- Reference number extraction and formatting
- Surface classification

**Railway Processing:**
- Service and usage classification
- Electrification and gauge attributes
- Station polygons and labels

### 5. Utilities

**Tables:** `dam_*`, `powerline`, `pipeline`, `power_station`, `pumping_station`, `hydrocarbon_*`, `grain_*`

**Purpose:** Energy and utility infrastructure

**Key Processing:**
- Point, line, and polygon representations
- Zoom-based filtering for different feature types
- Separate label layers for named features

### 6. Geonames

**Tables:** `geonames_hydrographic_*`, `populated_places_*`

**Purpose:** Geographic place names and hydrographic features

**Processing Strategy:**
- Zoom-specific views for density management
- Population-based ranking for places
- Feature class filtering

## Detailed Layer Documentation

### Highway Layer

The highway layer demonstrates the most complex processing:

#### Data Export (ogr2ogr)
```bash
ogr2ogr -lco SPATIAL_INDEX=NO \      # Skip FGB spatial index (not needed)
  -t_srs "$PROJECTION" \              # Transform to target projection
  "$OUTPUT_DIR/highway_3395.fgb" \    # Output file
  "$DB_CONNECTION" \                  # Database connection
  rbt.highway \                        # Source table
  -skipfailures                       # Continue on geometry errors
```

#### Tile Generation (tippecanoe)
```bash
tippecanoe -J transportation/highway/highway_filter \  # JSON filter config
  -o "$OUTPUT_DIR/highway_3395.mbtiles" \
  -s "$TILE_PROJECTION" \      # Output projection (usually 3857)
  -P \                         # Read in parallel
  -D 11 \                      # Detail level at max zoom
  -Z 6 -z 13 \                 # Zoom range
  --simplify-only-low-zooms \  # Don't simplify at high zooms
  --no-simplification-of-shared-nodes \  # Preserve topology
  --extra-detail=14 \          # Extra precision
  --single-precision \         # Use float32 for coordinates
  --no-tile-size-limit \       # Allow large tiles
  -T name_len:int \           # Type coercion for attributes
  -T ref_len:int \
  -T lane:int \
  -n highway \                # Layer name
  -l highway \                # Tileset name
  "$OUTPUT_DIR/highway_3395.fgb"
```

### Building Layer

Demonstrates zoom-based filtering and polygon optimization:

```bash
tippecanoe -J building/building_filter \
  -t /dev/shm \               # Use RAM disk for temp files
  -o "$OUTPUT_DIR/building_3395.mbtiles" \
  -P -s "$TILE_PROJECTION" \
  -Z 10 -z 13 \               # Only high zooms
  -pk \                       # Don't limit tiles by size
  --extra-detail 16 \         # Maximum detail
  --coalesce-smallest-as-needed \  # Merge small features
  --hilbert \                 # Hilbert curve ordering
  --single-precision \
  -T height:float \          # Preserve building height
  -T area:float \            # Preserve footprint area
  -x level \                 # Exclude level attribute
  -x id \                    # Exclude id attribute
  -n building -l building \
  "$OUTPUT_DIR/building_3395.fgb"
```

### Airport Layer

Shows point feature handling with ranking:

```bash
tippecanoe -o "$OUTPUT_DIR/airports_3395.mbtiles" \
  -P -s "$TILE_PROJECTION" \
  -Z 5 -z 13 \                    # Wide zoom range
  -r 1 \                          # Drop rate
  --drop-densest-as-needed \      # Smart dropping
  -T airport_id:int \             # Multiple typed attributes
  -T runway_length_ft:int \
  -T runway_width_ft:int \
  -T elevation_ft:int \
  -T category:int \
  -T rank:int \                   # Importance ranking
  -n airports -l airports \
  "$OUTPUT_DIR/airports_3395.fgb"
```

## Command Reference

### ogr2ogr Options

| Option | Description | Example |
|--------|-------------|---------|
| `-f` | Output format | `-f MVT` for Mapbox Vector Tiles |
| `-t_srs` | Target spatial reference | `-t_srs EPSG:3857` |
| `-lco` | Layer creation option | `-lco SPATIAL_INDEX=NO` |
| `-oo` | Open option | `-oo ACTIVE_SCHEMA=rbt` |
| `-dsco` | Dataset creation option | `-dsco FORMAT=DIRECTORY` |
| `-sql` | SQL query | `-sql "SELECT * FROM table"` |
| `-skipfailures` | Continue on errors | Useful for bad geometries |

### tippecanoe Options

#### Basic Options
| Option | Description |
|--------|-------------|
| `-o` | Output file |
| `-Z` / `-z` | Min/max zoom levels |
| `-l` | Layer name |
| `-n` | Name of tileset |
| `-P` | Parallel processing |

#### Quality Options
| Option | Description | Use Case |
|--------|-------------|----------|
| `--drop-densest-as-needed` | Smart feature dropping | Point features |
| `--coalesce-smallest-as-needed` | Merge small features | Polygons |
| `--simplify-only-low-zooms` | Preserve detail at high zoom | All features |
| `--no-simplification-of-shared-nodes` | Preserve topology | Boundaries |
| `--hilbert` | Hilbert curve ordering | Large datasets |
| `--single-precision` | Use 32-bit floats | Smaller file size |

#### Performance Options
| Option | Description |
|--------|-------------|
| `-t /dev/shm` | Use RAM for temp files |
| `-j` | JSON filter configuration |
| `--no-tile-size-limit` | Allow large tiles |
| `--progress-interval` | Progress reporting frequency |

#### Type Options
| Option | Description | Example |
|--------|-------------|---------|
| `-T` | Specify attribute type | `-T population:int` |
| `-x` | Exclude attribute | `-x internal_id` |

### tile-join Options

```bash
tile-join -f \           # Force overwrite
  -pk \                  # No tile size limit
  -o output.mbtiles \    # Output file
  -n layer_name \        # Layer name
  --coalesce \           # Merge features
  --no-tile-compression \ # Skip compression
  input1.mbtiles input2.mbtiles ...
```

## Performance Considerations

### Database Optimization

1. **Materialized Views**: Pre-compute expensive joins and transformations
2. **Concurrent Indexes**: Build indexes without locking tables
3. **Partial Indexes**: Index only relevant rows
4. **CLUSTER**: Physically reorder tables by spatial index

### Export Optimization

1. **Skip Spatial Index**: `-lco SPATIAL_INDEX=NO` for FlatGeoBuf when not needed
2. **Skip Failures**: `-skipfailures` to handle bad geometries
3. **Parallel Processing**: Use multiple connections when possible

### Tile Generation Optimization

1. **RAM Disk**: `-t /dev/shm` for temporary files
2. **Parallel Reading**: `-P` flag for parallel processing
3. **Progressive Enhancement**: Zoom-specific views reduce data at low zooms
4. **Smart Dropping**: Algorithm-based feature reduction

### Storage Optimization

1. **Single Precision**: Reduces coordinate storage by 50%
2. **Attribute Filtering**: Remove unnecessary attributes with `-x`
3. **Coalescing**: Merge small features to reduce feature count
4. **Compression**: MBTiles use gzip compression by default

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

This metadata ensures compatibility with BTIS-compliant tile servers and applications.

## Troubleshooting

### Common Issues

1. **Memory errors during tippecanoe**: 
   - Use `-t /dev/shm` if you have sufficient RAM
   - Reduce `--max-features` limit
   - Process in smaller geographic chunks

2. **Large tile sizes**:
   - Add `--drop-densest-as-needed` for point features
   - Use `--coalesce-smallest-as-needed` for polygons
   - Implement zoom-specific views

3. **Slow database exports**:
   - Add appropriate indexes
   - Use materialized views for complex queries
   - Consider parallel exports for independent layers

4. **Geometry errors**:
   - Add `-skipfailures` to ogr2ogr commands
   - Run `ST_MakeValid()` on geometries in database
   - Check for self-intersections and fix in PostGIS

## References

- [GDAL/OGR Documentation](https://gdal.org/programs/ogr2ogr.html)
- [Tippecanoe Documentation](https://github.com/mapbox/tippecanoe)
- [PostGIS Documentation](https://postgis.net/docs/)
- [Mapbox Vector Tile Specification](https://docs.mapbox.com/vector-tiles/specification/)
- [FlatGeoBuf Specification](https://flatgeobuf.org/)
- [MBTiles Specification](https://github.com/mapbox/mbtiles-spec)

## 📚 Related Documentation

- **[← Back to Home](index.md)**
- **[Getting Started Guide](getting-started.md)** - Setup walkthrough and first steps
- **[Architecture Overview](architecture.md)** - System design and data flow
- **[Physical Layers](physical-layers.md)** - Natural feature processing
- **[Database Initialization](database-initialization.md)** - Database setup process
- **[OSM Import Pipeline](osm-import.md)** - OpenStreetMap data processing
- **[Production Documentation](production-readme.md)** - Tile generation operations
