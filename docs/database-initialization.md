# Database Initialization

One-time population of the PostGIS database with global datasets, orchestrated
by the `rbt` CLI. Every step is native Python: the bootstrap (database +
extensions), the four data importers under `src/rbt/importers/`, and schema
processing. External geospatial binaries (ogr2ogr, imposm, aria2c, osmium,
osmosis, aws) are invoked as subprocesses.

## 📋 Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Entry Points](#entry-points)
- [The Importer Modules](#the-importer-modules)
- [Tools and Technologies](#tools-and-technologies)
- [Database Structure](#database-structure)
- [Data Sources](#data-sources)
- [Usage](#usage)
- [Schema Processing](#schema-processing)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)

## Overview

`rbt setup --all` runs the full initialization in dependency order:

1. **Bootstrap** (`rbt setup --setup-database`) — creates the database and
   extensions (`postgis`, `postgis_raster`, `hstore`, `pg_trgm`) via psycopg
   (`src/rbt/setup_db.py`).
2. **Data import** — four native importer modules, each independently
   re-runnable via `rbt import`:
    - `rbt import osm` → `src/rbt/importers/osm.py`
    - `rbt import reference` → `src/rbt/importers/reference.py`
    - `rbt import geonames` → `src/rbt/importers/geonames.py`
    - `rbt import buildings` → `src/rbt/importers/buildings.py`
3. **Schema processing** (`rbt schema run --all`) — executes the eight
   PL/pgSQL files under `setup/data-sources/schemas/` through `psql` to build
   the `rbt.*` views consumed by tile generation.

!!! note "`rbt setup --all` returns when the initial import finishes"
    The OSM step runs the full download → import pipeline and **returns** —
    it does not start continuous replication (that is `rbt osm run`,
    started separately after setup). Use `--osm-stage <stage>` to run a
    narrower OSM stage within setup, e.g. when the planet file is already
    on disk:

    ```bash
    rbt setup --all --osm-stage import
    ```

The importers are designed for CI/CD pipelines and containerized
environments, featuring:

- ✅ Parallel processing for faster data ingestion (bounded thread pools)
- ✅ Automatic retry mechanisms with configurable attempts
- ✅ Comprehensive logging with one log file per job
- ✅ Failure collection — one bad dataset never blocks the rest
- ✅ Resume semantics — valid downloads and existing tables are skipped

## Architecture

### Processing Flow

```mermaid
flowchart TD
    A["rbt setup --all"] --> B["Bootstrap<br/>CREATE DATABASE + EXTENSIONS<br/>(psycopg)"]
    B --> C["rbt import osm<br/>src/rbt/importers/osm.py"]
    B --> D["rbt import reference<br/>src/rbt/importers/reference.py"]
    B --> E["rbt import geonames<br/>src/rbt/importers/geonames.py"]
    B --> F["rbt import buildings<br/>src/rbt/importers/buildings.py"]
    C --> G[("PostgreSQL + PostGIS")]
    D --> G
    E --> G
    F --> G
    G --> H["rbt schema run --all<br/>8 PL/pgSQL units via psql"]
    H --> I["rbt.* views ready for rbt tiles"]
```

## Entry Points

=== "rbt CLI"

    ```bash
    # Complete initialization (recommended)
    rbt setup --all

    # Run individual steps
    rbt setup --setup-database          # bootstrap only
    rbt setup --import-osm-data         # honors --osm-stage
    rbt setup --import-reference-data
    rbt setup --import-geonames
    rbt setup --import-buildings
    rbt setup --process-schemas

    # Preview the plan without executing
    rbt setup --all --dry-run
    ```

=== "Docker Compose"

    ```bash
    # The setup profile runs `rbt setup --all` against the postgres service
    docker compose --profile setup up rbt-setup

    # Re-run a single step inside the image
    docker compose run --rm rbt-setup rbt setup --import-geonames
    ```

!!! note "Replaced scripts"
    `rbt setup` replaces the former `setup/init-database.sh`, and
    `rbt schema run` replaces the `process-physical-schemas.sh` /
    `process-cultural-schemas.sh` wrappers. The four bash importers that
    previously lived under `setup/data-sources/` were ported to the native
    modules in `src/rbt/importers/`. None of those scripts exist anymore.

## The Importer Modules

**Location**: `src/rbt/importers/`

Each module declares its datasets in a registry (URLs, target tables,
ogr2ogr options) and shares one toolkit (`_support.py`): the canonical
ogr2ogr command builder, psycopg schema/table helpers, a retrying parallel
job pool, and stdlib download/extract/convert plumbing.

| Entry point | Module | Loads |
|---|---|---|
| `rbt import osm` | `src/rbt/importers/osm.py` | OpenStreetMap planet via Imposm3 |
| `rbt import reference` | `src/rbt/importers/reference.py` | FieldMaps, Natural Earth, OurAirports, MIRTA, OSM ocean/Antarctica |
| `rbt import geonames` | `src/rbt/importers/geonames.py` | NGA GNS + USGS GNIS geographic names (parallel download) |
| `rbt import buildings` | `src/rbt/importers/buildings.py` | Overture Maps building footprints from S3 |

Every subcommand takes `--dry-run` (print the external commands without
executing), and the OSM importer selects its pipeline stage with a typed
`--stage` option:

```bash
rbt import osm --dry-run
rbt import osm --stage download-planet
rbt import reference --only mirta
rbt import geonames --list
```

**Key features**:

- Independent execution capability
- Parallel processing within each importer (bounded thread pools)
- Smart table existence checking (re-runs skip completed work)
- Automatic retry mechanisms (`RETRY_COUNT` × `RETRY_DELAY`)
- Per-dataset selection (`--only`) and registry listing (`--list`)
- AWS S3 sync for the large Overture dataset, with incremental download
  support and optimized PostgreSQL COPY operations

## Tools and Technologies

### Core Dependencies

#### **ogr2ogr** (GDAL/OGR)

Primary tool for spatial data translation and loading. Key parameters used:

```bash
ogr2ogr -progress \                    # Show progress bar
    -f "PostgreSQL" \                   # Output format
    --config PG_USE_COPY YES \          # Use fast COPY instead of INSERT
    "PG:host=... dbname=... user=..." \# Connection string (password via PGPASSWORD)
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

Most remote datasets are streamed directly through GDAL's virtual
filesystems (`/vsicurl/`, `/vsizip//vsicurl/`) — no separate download step.

#### **psql** (PostgreSQL Client)

Used for:

- Schema processing — `rbt schema run` shells out to
  `psql -v ON_ERROR_STOP=1 -f <unit>.sql`

(Connectivity tests and table-existence checks that the bash importers ran
through `psql` are now direct psycopg queries.)

#### **PostGIS Extensions**

Spatial database extensions providing:

- **postgis**: Core spatial types and functions
  - Geometry types (POINT, LINESTRING, POLYGON, etc.)
  - Spatial relationship functions (ST_Intersects, ST_Contains)
  - Measurement functions (ST_Area, ST_Distance)
- **postgis_raster**: Raster data support
- **hstore**: Key-value storage for tags/attributes
- **pg_trgm**: Trigram indexes for fuzzy text matching

### Supporting Utilities

- **aria2c**: segmented multi-mirror download of the OSM planet PBF
- **osmium / osmosis**: OSM diff merging and change application
- **imposm**: OSM planet import into PostGIS
- **aws**: S3 data synchronization (Overture data)
- **Python stdlib** (`urllib`, `zipfile`, `csv`): single-URL downloads,
  archive extraction, and TSV→CSV conversion — replacing the retired bash
  importers' `wget`, `7z`, and `sed` usage. The `csv`-based conversion
  quotes fields containing commas instead of silently corrupting them.

## Database Structure

### Schemas Created

| Schema | Purpose | Tables |
|--------|---------|--------|
| **fieldmap** | Administrative boundaries | adm0, adm1, adm2, adm0_lines, adm1_lines, adm2_lines, adm0_labels, adm1_labels, adm2_labels, usa |
| **naturalearth** | Natural Earth features | ne_10m_admin_0_countries, ne_10m_populated_places, ne_10m_rivers_lake_centerlines, etc. |
| **ourairports** | Aviation data | airport, runway |
| **rbt** | Core spatial data + tile views | osm_ocean, osm_ocean_simplified, osm_antarctica_icesheet, coastline, plus the views created by `rbt schema run` |
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
| OSM Ocean/Antarctica/Coastline | OpenStreetMap | Shapefile | Periodic |
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

Configure the database connection in `config/rbt.conf` (or override via
environment variables — legacy `PG_*` names are still accepted):

```bash
DATABASE_HOST=localhost
DATABASE_USER=postgres
DATABASE_PASSWORD=password

# Optional tuning
MAX_PARALLEL_JOBS=4
RETRY_COUNT=3
```

Then verify the environment:

```bash
rbt validate
```

### Basic Execution

```bash
# Run complete database initialization (recommended)
rbt setup --all

# Or run individual importers separately
rbt import osm                    # full download → import pipeline
rbt import osm --stage import     # just the imposm import stage
rbt import reference
rbt import geonames
rbt import buildings
```

### Advanced Execution

```bash
# Preview without executing
rbt setup --all --dry-run

# Debug-level CLI logging
rbt --debug setup --all

# Run every reference dataset in one pool instead of the two-phase default
rbt import reference --parallel

# Import only named datasets (repeatable; discover names with --list)
rbt import reference --only mirta --only naturalearth
rbt import geonames --only populated_places

# Tune the job pools via config/rbt.conf or the environment
MAX_PARALLEL_JOBS=8 rbt import reference
```

## Schema Processing

Schema units are registered in the `schemas:` block of `config/layers.yml`
and executed by `rbt schema run` via `psql -v ON_ERROR_STOP=1` (a failing
statement aborts that unit — stricter than the old bash wrappers, which
continued past errors). A bare `rbt schema run` with no keys, `--type`, or
`--all` is rejected — running every schema is a maximal, mutating action and
must be requested explicitly.

```bash
# Discover the registered units
rbt schema list

# Run everything (what `rbt setup --process-schemas` does)
rbt schema run --all

# Run by layer type
rbt schema run --type physical
rbt schema run --type cultural

# Run individual units by key
rbt schema run water landcover
rbt schema run highway --dry-run
```

| Key | Type | SQL file |
|---|---|---|
| `physical` | physical | `setup/data-sources/schemas/physical/physical-core.sql` (built-up areas, glaciers, mountain labels, parks) |
| `landcover` | physical | `setup/data-sources/schemas/physical/landcover.sql` (landcover polygons + labels) |
| `water` | physical | `setup/data-sources/schemas/physical/water-features.sql` |
| `contour` | physical | `setup/data-sources/schemas/physical/terrain.sql` (contour + glacier-contour zoom views) |
| `cultural` | cultural | `setup/data-sources/schemas/cultural/cultural-core.sql` |
| `highway` | cultural | `setup/data-sources/schemas/cultural/transportation.sql` |
| `railway` | cultural | `setup/data-sources/schemas/cultural/transportation-railway.sql` |
| `aero` | cultural | `setup/data-sources/schemas/cultural/infrastructure.sql` |

Each unit logs to `output/logs/schema_<key>_<timestamp>.log`.

## Configuration

### Key Variables

Resolved by `src/rbt/config.py` with precedence: environment variables →
`config/rbt.conf` → built-in defaults. See
[configuration.md](configuration.md) for the complete reference.

| Variable | Default | Description |
|----------|---------|-------------|
| **DATABASE_HOST** | `localhost` | PostgreSQL host (legacy: `PG_HOST`) |
| **DATABASE_USER** | `postgres` | PostgreSQL username (legacy: `PG_USR`) |
| **DATABASE_PASSWORD** | *(unset)* | PostgreSQL password (legacy: `PG_PASS`) |
| **MAX_PARALLEL_JOBS** | 4 | Ingest job pool size |
| **RETRY_COUNT** | 3 | Attempts per job |
| **RETRY_DELAY** | 30 | Seconds between retries |
| **WGET_PARALLEL_JOBS** | 8 | Download pool size (name kept for compatibility) |
| **OVERTURE_RELEASE** | 2026-06-17.0 | Pinned Overture buildings release |
| **SHARED_LOG_DIR** | ./output/logs | Log file directory |
| **SHARED_TEMP_DIR** | ./output/temp | Temporary file directory |

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

## Troubleshooting

### Common Issues

#### 1. Connection Failures

```bash
# rbt validate reports each resolved connection value and tests the DB
rbt validate

# Or test manually
psql "host=$DATABASE_HOST dbname=rbt user=$DATABASE_USER password=$DATABASE_PASSWORD" -c "SELECT 1;"
```

#### 2. Missing Dependencies

```bash
# rbt validate checks every required and optional tool with versions
rbt validate
```

#### 3. Disk Space Issues

```bash
# Monitor temp directory usage
du -sh ./output/temp/
# Clean up if needed
rm -rf ./output/temp/*
```

#### 4. Failed Jobs

```bash
# Check the per-invocation CLI log
tail -n 50 output/logs/rbt_*.log
# Per-job importer logs (one file per dataset/stage)
tail -n 50 output/logs/reference_mirta_*.log
tail -n 50 output/logs/geonames_populated_places_*.log
tail -n 50 output/logs/osm_download_planet_*.log
```

### Debug Mode

Enable comprehensive debugging:

```bash
rbt --debug setup --all
```

Add `--dry-run` to any command to print the exact external commands without
executing them.

### Log Files

Logs are centralized under `$SHARED_LOG_DIR` (default `./output/logs`):

- CLI logs: `rbt_YYYYMMDD_HHMMSS.log`
- Per-job importer logs: `<importer>_<job>_YYYYMMDD_HHMMSS.log`
  (e.g. `osm_import_*.log`, `reference_fieldmaps_adm0_*.log`,
  `geonames_hydrographic_*.log`, `buildings_s3_sync_*.log`)
- Schema logs: `schema_<key>_YYYYMMDD_HHMMSS.log`

## Best Practices

1. **Pre-flight Checks**: Run `rbt validate` before running setup
2. **Incremental Loading**: Importers check for existing tables to avoid redundant work — re-running `rbt setup` is safe
3. **Resource Management**: Adjust `MAX_PARALLEL_JOBS` based on system capacity
4. **Monitoring**: Use `rbt --debug` for first-time runs
5. **Backup**: Consider backing up the database before major ingestions
6. **Post-Processing**: Run ANALYZE on tables after loading for query optimization

## 📚 Related Documentation

- **[← Back to Home](index.md)**
- **[Getting Started Guide](getting-started.md)** - Setup walkthrough and first steps
- **[Architecture Overview](architecture.md)** - System design and data flow
- **[OSM Import Pipeline](osm-import.md)** - OpenStreetMap data processing details
- **[Physical Layers](physical-layers.md)** - Natural feature processing
- **[Cultural Layers](cultural-layers.md)** - Human infrastructure processing
- **[Setup Documentation](setup-readme.md)** - Complete setup information
