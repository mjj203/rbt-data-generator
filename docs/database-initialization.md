# Database Initialization Scripts

This directory contains robust, production-ready PostgreSQL database initialization scripts for populating a geospatial database with various global datasets. The scripts leverage PostGIS extensions and GDAL/OGR tools for efficient spatial data processing.

## 📋 Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Scripts](#scripts)
- [Tools and Technologies](#tools-and-technologies)
- [Database Structure](#database-structure)
- [Data Sources](#data-sources)
- [Usage](#usage)
- [Configuration](#configuration)
- [Advanced Features](#advanced-features)
- [Troubleshooting](#troubleshooting)

## Overview

The initialization suite consists of a main orchestrator script that manages different aspects of geospatial data ingestion:

1. **`init-database.sh`** - Main orchestrator for complete database initialization
2. **Individual import scripts** - Modular data import components:
   - `import-osm-data.sh` - OpenStreetMap data import using Imposm3
   - `import-reference-data.sh` - FieldMaps, Natural Earth, OurAirports data
   - `import-geonames.sh` - GeoNames geographic place data
   - `import-buildings.sh` - Overture Maps building footprint data

These scripts are designed for CI/CD pipelines and containerized environments, featuring:

- ✅ Parallel processing for faster data ingestion
- ✅ Automatic retry mechanisms with configurable attempts
- ✅ Comprehensive logging with timestamps
- ✅ Graceful error handling and cleanup
- ✅ Progress tracking and colored output
- ✅ Container-friendly signal handling

## Architecture

### Processing Flow

```text
┌─────────────────────┐
│  Environment Setup  │
│  - Validation       │
│  - Dependencies     │
└──────────┬──────────┘
           │
┌──────────▼──────────┐
│  Database Setup     │
│  - Extensions       │
│  - Schemas          │
└──────────┬──────────┘
           │
┌──────────▼──────────┐
│  Data Download      │     ┌─────────────┐
│  - Parallel jobs    │────▶│  Temp Files │
│  - Retry logic      │     └─────────────┘
└──────────┬──────────┘
           │
┌──────────▼──────────┐
│  Data Ingestion     │     ┌─────────────┐
│  - ogr2ogr          │────▶│  PostgreSQL │
│  - Spatial indexing │     │   + PostGIS │
└──────────┬──────────┘     └─────────────┘
           │
┌──────────▼──────────┐
│  Optimization       │
│  - ANALYZE tables   │
│  - Cleanup          │
└─────────────────────┘
```

## Scripts

### 1. init-database.sh

**Purpose**: Main orchestrator for complete database initialization

**Data Sources Processed**:

- OpenStreetMap planet data via Imposm3
- FieldMaps administrative boundaries
- Natural Earth vector data
- GeoNames geographic names
- Overture Maps building footprints
- OurAirports aviation data
- MIRTA US military installations

**Key Features**:

- Single command for complete setup
- Modular execution with individual component support
- Comprehensive validation and logging
- Configuration via centralized `rbt.conf` or environment variables

### 2. Individual Import Scripts

**Location**: `setup/data-sources/*/`

**Components**:

- **`osm/import-osm-data.sh`**: OpenStreetMap planet import using Imposm3
- **`reference-data/import-reference-data.sh`**: FieldMaps, Natural Earth, OurAirports
- **`reference-data/import-geonames.sh`**: GeoNames geographic place data
- **`reference-data/import-buildings.sh`**: Overture Maps building footprints

**Key Features**:

- Independent execution capability
- Parallel processing within each component
- Smart table existence checking
- Automatic retry mechanisms

**Data Sources Processed**:

- Overture Maps building geometries
- Building parts (optional)

**Key Features**:

- AWS S3 sync for large dataset handling
- Incremental download support
- Optimized PostgreSQL COPY operations

## Tools and Technologies

### Core Dependencies

#### **ogr2ogr** (GDAL/OGR)

Primary tool for spatial data translation and loading. Key parameters used:

```bash
ogr2ogr -progress \                    # Show progress bar
    -f "PostgreSQL" \                   # Output format
    --config PG_USE_COPY YES \          # Use fast COPY instead of INSERT
    "PG:host=... dbname=... user=..." \# Connection string
    -lco GEOMETRY_NAME=geometry \       # Geometry column name
    -lco DIM=2 \                        # Force 2D geometries
    -lco UNLOGGED=ON \                  # Create unlogged tables (faster)
    -nlt MULTIPOLYGON \                 # Force geometry type
    -skipfailures \                     # Continue on errors
    -overwrite \                        # Replace existing data
    input_file                          # Input data source
```

**Common Layer Creation Options (-lco)**:

- `GEOMETRY_NAME`: Name of the geometry column (default: geometry)
- `DIM`: Coordinate dimension (2 for 2D, 3 for 3D)
- `UNLOGGED`: Create unlogged tables for faster initial load
- `PRECISION`: Control coordinate precision

**Configuration Options (--config)**:

- `PG_USE_COPY`: Use PostgreSQL COPY command for bulk loading
- Thread and memory settings for performance

#### **psql** (PostgreSQL Client)

Used for:

- Database connectivity testing
- Schema and extension creation
- Direct SQL execution
- Table existence verification

#### **PostGIS Extensions**

Spatial database extensions providing:

- **postgis**: Core spatial types and functions
  - Geometry types (POINT, LINESTRING, POLYGON, etc.)
  - Spatial relationship functions (ST_Intersects, ST_Contains)
  - Measurement functions (ST_Area, ST_Distance)
- **postgis_raster**: Raster data support
- **hstore**: Key-value storage for tags/attributes

### Supporting Utilities

- **wget**: HTTP/HTTPS file downloads with retry support
- **aws**: S3 data synchronization (Overture data)
- **7z**: Archive extraction for compressed datasets
- **unzip**: ZIP file extraction
- **timeout**: Command execution time limits

## Database Structure

### Schemas Created

| Schema | Purpose | Tables |
|--------|---------|--------|
| **fieldmap** | Administrative boundaries | adm0, adm1, adm2, adm0_lines, adm1_lines, adm2_lines, adm0_labels, adm1_labels, adm2_labels, usa |
| **naturalearth** | Natural Earth features | ne_10m_admin_0_countries, ne_10m_populated_places, ne_10m_rivers_lake_centerlines, etc. |
| **ourairports** | Aviation data | airport, runway |
| **rbt** | Core spatial data | osm_ocean, osm_ocean_simplified, osm_antarctica_icesheet |
| **mirta** | Military installations | us_military_installations |
| **geonames** | Geographic names | administrative_regions, hydrographic, hypsographic, populated_places, etc. |
| **overture** | Building footprints | building, buildingpart |

### Table Details

#### FieldMaps Tables

Administrative boundary polygons and lines with hierarchical levels:

- **adm0**: Country boundaries (MULTIPOLYGON)
- **adm1**: State/province boundaries (MULTIPOLYGON)  
- **adm2**: County/district boundaries (MULTIPOLYGON)
- **adm*_lines**: Boundary lines (MULTILINESTRING)
- **adm*_labels**: Label points (POINT)

#### Natural Earth Tables

Comprehensive geographic features at multiple scales (1:10m, 1:50m, 1:110m):

- Political boundaries
- Physical features (lakes, rivers, coastlines)
- Cultural features (populated places, urban areas)
- Each table includes attributes for styling and labeling

#### GeoNames Tables

Point features with geographic names and classifications:

```sql
-- Example structure
CREATE TABLE geonames.populated_places (
    ogc_fid SERIAL PRIMARY KEY,
    geometry geometry(Point, 4326),
    name VARCHAR,
    feature_class VARCHAR,
    feature_code VARCHAR,
    country_code VARCHAR,
    population INTEGER,
    elevation INTEGER,
    -- Additional attributes...
);
```

### Spatial Indexes

All geometry columns automatically receive spatial indexes via ogr2ogr:

```sql
CREATE INDEX idx_tablename_geometry 
ON schema.tablename 
USING GIST (geometry);
```

## Data Sources

### Primary Sources

| Dataset | Provider | Format | Update Frequency |
|---------|----------|--------|------------------|
| FieldMaps | FieldMaps.io | GeoPackage | Regular |
| Natural Earth | Natural Earth Data | GeoPackage | Version releases |
| OurAirports | OurAirports Community | CSV | Daily |
| OSM Ocean/Antarctica | OpenStreetMap | Shapefile | Periodic |
| MIRTA | US DoD | File Geodatabase | Annual |
| GeoNames | NGA | CSV/TXT | Regular |
| Overture Buildings | Overture Maps | Parquet | Monthly |

### Data URLs

Data is fetched from authoritative sources:

- FieldMaps: `https://data.fieldmaps.io/`
- Natural Earth: `https://naciscdn.org/naturalearth/`
- OurAirports: `https://raw.githubusercontent.com/davidmegginson/ourairports-data/`
- OSM: `https://osmdata.openstreetmap.de/`
- GeoNames: `https://geonames.nga.mil/`
- Overture: `s3://overturemaps-us-west-2/`

## Usage

### Prerequisites

```bash
# Required environment variables
export PG_HOST=localhost
export PG_USR=postgres
export PG_PASS=password

# Optional configuration
export MAX_PARALLEL_JOBS=4
export RETRY_COUNT=3
export DEBUG=true
```

### Basic Execution

```bash
# Run complete database initialization (recommended)
./setup/init-database.sh

# Or run individual components separately
./setup/data-sources/osm/import-osm-data.sh
./setup/data-sources/reference-data/import-reference-data.sh
./setup/data-sources/reference-data/import-geonames.sh
./setup/data-sources/reference-data/import-buildings.sh
```

### Advanced Execution

```bash
# Full parallel mode (maximum speed)
PARALLEL_INGESTION=true ./setup/init-database.sh

# Debug mode with verbose output
DEBUG=true VERBOSE=true ./setup/init-database.sh

# Individual component execution with options
DEBUG=true ./setup/data-sources/reference-data/import-geonames.sh
CLEAN_TEMP_FILES=false ./setup/data-sources/reference-data/import-buildings.sh

# Custom parallel job limit
MAX_PARALLEL_JOBS=8 ./setup/init-database.sh
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| **PG_HOST** | (required) | PostgreSQL host |
| **PG_USR** | (required) | PostgreSQL username |
| **PG_PASS** | (required) | PostgreSQL password |
| **MAX_PARALLEL_JOBS** | 4 | Maximum concurrent jobs |
| **RETRY_COUNT** | 3 | Attempts per operation |
| **RETRY_DELAY** | 30 | Seconds between retries |
| **CONNECTION_TIMEOUT** | 300 | Database connection timeout (seconds) |
| **PARALLEL_INGESTION** | false | Enable full parallel mode |
| **DEBUG** | false | Enable debug output |
| **VERBOSE** | false | Enable verbose logging |
| **CLEAN_TEMP_FILES** | false | Remove temp files after completion |
| **LOG_DIR** | ./logs | Log file directory |
| **TEMP_DIR** | ./temp | Temporary file directory |

### Performance Tuning

For optimal performance, consider these PostgreSQL settings:

```sql
-- Increase work memory for sorting/indexing
SET work_mem = '256MB';

-- Increase maintenance work memory for index creation
SET maintenance_work_mem = '1GB';

-- Disable autovacuum during bulk load
ALTER TABLE schema.table SET (autovacuum_enabled = false);

-- Re-enable and analyze after load
ALTER TABLE schema.table SET (autovacuum_enabled = true);
ANALYZE schema.table;
```

## Advanced Features

### Job Management

The scripts implement sophisticated job control:

```bash
# Job states tracked internally
RUNNING_JOBS=()    # Currently executing
COMPLETED_JOBS=()  # Successfully finished
FAILED_JOBS=()     # Failed after retries
```

### Progress Tracking

Real-time progress bars for long-running operations:

```text
[PROGRESS] Jobs progress [====================----] 80% (8/10)
```

### Error Recovery

- Automatic retry with exponential backoff
- Detailed error logs per job
- Continue-on-failure mode for resilient processing

### Signal Handling

Graceful shutdown on container signals:

```bash
trap cleanup EXIT
trap 'exit 143' TERM  # SIGTERM
trap 'exit 130' INT   # SIGINT
```

## Troubleshooting

### Common Issues

#### 1. Connection Failures

```bash
# Test database connectivity
psql "host=$PG_HOST dbname=rbt user=$PG_USR password=$PG_PASS" -c "SELECT 1;"
```

#### 2. Missing Dependencies

```bash
# Check required tools
for tool in ogr2ogr psql wget aws 7z; do
    command -v $tool >/dev/null 2>&1 || echo "Missing: $tool"
done
```

#### 3. Disk Space Issues

```bash
# Monitor temp directory usage
du -sh ./temp/
# Clean up if needed
rm -rf ./temp/*
```

#### 4. Failed Jobs

```bash
# Check job logs
tail -n 50 logs/database_setup_*.log
# Review specific job output
cat temp/job_name.log
```

### Debug Mode

Enable comprehensive debugging:

```bash
DEBUG=true VERBOSE=true CLEAN_TEMP_FILES=false ./setup/init-database.sh
```

This preserves all temporary files and provides detailed execution traces.

### Log Files

Logs are stored with timestamps:

- Main logs: `logs/database_setup_YYYYMMDD_HHMMSS.log`
- GeoNames logs: `logs/geonames_setup_YYYYMMDD_HHMMSS.log`
- Overture logs: `logs/overture_buildings_YYYYMMDD_HHMMSS.log`
- Job-specific logs: `temp/job_name.log`

## Best Practices

1. **Pre-flight Checks**: Always validate environment before running
2. **Incremental Loading**: Scripts check for existing tables to avoid redundant work
3. **Resource Management**: Adjust MAX_PARALLEL_JOBS based on system capacity
4. **Monitoring**: Use DEBUG mode for first-time runs
5. **Backup**: Consider backing up database before major ingestions
6. **Post-Processing**: Run ANALYZE on tables after loading for query optimization

## 📚 Related Documentation

- **[← Back to Home](index.md)**
- **[Getting Started Guide](getting-started.md)** - Setup walkthrough and first steps
- **[Architecture Overview](architecture.md)** - System design and data flow
- **[OSM Import Pipeline](osm-import.md)** - OpenStreetMap data processing details
- **[Physical Layers](physical-layers.md)** - Natural feature processing
- **[Cultural Layers](cultural-layers.md)** - Human infrastructure processing
- **[Setup Documentation](setup-readme.md)** - Complete setup information
