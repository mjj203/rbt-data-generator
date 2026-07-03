# Database Setup and Initialization

This directory contains the configuration and SQL consumed during one-time database initialization. The phase is orchestrated entirely by the `rbt` CLI: `rbt setup --all` downloads global datasets, imports them into PostgreSQL, and creates the optimized `rbt.*` views for tile generation.

## ⚠️ Important Note

**The setup phase runs ONCE when standing up a new RBT system.** After initialization is complete, ongoing operations (`rbt osm run`, `rbt tiles`) are covered by the [Operations Guide](operations.md).

## 🧭 How the Setup Phase Is Orchestrated

`rbt setup --all` runs three stages in dependency order (`src/rbt/setup_db.py`):

1. **Bootstrap** — creates the database and extensions (`postgis`, `postgis_raster`, `hstore`, `pg_trgm`) natively via psycopg.
2. **Data import** — four native Python importers under [`src/rbt/importers/`](https://github.com/MJJ203/rbt-data-generator/tree/main/src/rbt/importers), each independently re-runnable via `rbt import`:
    - `rbt import osm` — `src/rbt/importers/osm.py`
    - `rbt import reference` — `src/rbt/importers/reference.py`
    - `rbt import geonames` — `src/rbt/importers/geonames.py`
    - `rbt import buildings` — `src/rbt/importers/buildings.py`
3. **Schema processing** — `rbt schema run --all` executes the eight PL/pgSQL files under `data-sources/schemas/` through `psql -v ON_ERROR_STOP=1`, creating the materialized views and indexes that tile generation reads.

The importers share one toolkit (`src/rbt/importers/_support.py`): declarative dataset registries, a canonical ogr2ogr command builder (`PG_USE_COPY`, unlogged 2D `geometry` tables, password via `PGPASSWORD` — never argv), a retrying parallel job pool, and stdlib downloads/extraction. There is no bash in the runtime path; external binaries (ogr2ogr, imposm, aria2c, osmium, osmosis, aws) are invoked as subprocesses.

## 🚀 Quick Start

=== "rbt CLI"

    ```bash
    # From the project root directory
    rbt setup --all
    ```

=== "Docker Compose"

    ```bash
    # The setup profile runs `rbt setup --all` against the postgres service
    docker compose --profile setup up rbt-setup
    ```

This single command orchestrates the entire setup process with:

- Automatic environment validation (run `rbt validate` first for a full pre-flight report)
- Progress tracking and logging
- Error recovery capabilities
- Optimized parallel processing

`rbt setup --all` runs the complete OSM workflow and **returns** when the initial import finishes — continuous replication is a separate concern started afterwards with `rbt osm run`. Use `--osm-stage <stage>` to run a narrower OSM stage within setup (e.g. `rbt setup --all --osm-stage import` when the planet file is already on disk).

### Manual Step-by-Step

If you need more control or want to run individual components:

```bash
# 0. Bootstrap the database and extensions
rbt setup --setup-database

# 1. Import OSM data (several hours) — full pipeline by default
rbt import osm
# ... or a single stage
rbt import osm --stage import

# 2. Import reference datasets (1-2 hours)
rbt import reference
rbt import geonames
rbt import buildings

# 3. Process database schemas (30-60 minutes)
rbt schema run --all

# Or process by layer type / individual unit:
rbt schema run --type physical
rbt schema run --type cultural
rbt schema run landcover
rbt schema run highway
```

## 📦 The Four Importers

Every importer follows the same conventions: work that is already done is
**skipped** (re-running is safe), failures are retried `RETRY_COUNT` times with
`RETRY_DELAY` seconds between attempts, a failing dataset never blocks the
rest (failures are collected and raised at the end), and each job writes its
own log to `$SHARED_LOG_DIR` (default `./output/logs`) as
`<importer>_<job>_<timestamp>.log`. Add `--dry-run` to any command to print
the external commands without executing them.

### `rbt import osm` — OpenStreetMap planet

Pipeline: aria2c races the planet PBF across nine mirrors → daily replication
diffs are downloaded in parallel → `osmium merge-changes` consolidates them →
`osmosis` applies the changeset to the planet → `imposm import` loads the
result into PostGIS using `data-sources/osm/imposm-mapping.yaml`.

- `--stage all` (the default) runs the whole pipeline and returns; it does
  **not** start continuous replication (that is `rbt osm run`).
- `--stage download-planet|download-diffs|merge-diffs|apply-changes|import|import-diff`
  runs one stage; single-stage runs keep their outputs on disk.
- `--start-seq` / `--end-seq` override the diff sequence range
  (`DIFF_START_SEQ` / `DIFF_END_SEQ`).
- Resume: an existing valid planet file or diff skips its download; merged
  intermediates are removed only after a *successful* full run (and only when
  `OSM_CLEANUP_ON_EXIT=true`).
- Logs: `osm_<stage>_<timestamp>.log`.

### `rbt import reference` — reference datasets

Streams FieldMaps ADM0/1/2 boundaries (remote GeoParquet), Natural Earth
(zipped GeoPackage), OurAirports CSVs, and the OSM water/coastline/Antarctica
shapefiles straight from their remote sources into PostGIS via ogr2ogr
(`/vsicurl/` / `/vsizip//vsicurl/`). MIRTA is the one download-first source
(FileGDB zip, with a documented TLS exception — see
[SECURITY.md](https://github.com/MJJ203/rbt-data-generator/blob/main/SECURITY.md)).
The `fieldmap.usa` subset table is derived after the FieldMaps phase.

- Default mode runs the nine FieldMaps datasets first, then the USA subset,
  then the independent sources; `--parallel` collapses everything into one
  pool.
- `--only NAME` (repeatable) imports a subset; `--list` prints the registry.
- Resume: a dataset whose target table already exists is skipped.
- Logs: `reference_<dataset>_<timestamp>.log`.

### `rbt import geonames` — NGA GNS + USGS GNIS gazetteers

Eleven point datasets into the `geonames` schema: nine NGA GNS feature-class
zips and two USGS national files. Phase 1 downloads each zip, extracts the
data `.txt`, and converts tab-separated text to CSV (parallel, sized by
`WGET_PARALLEL_JOBS`); phase 2 ogr2ogr-loads each CSV (parallel, sized by
`MAX_PARALLEL_JOBS`).

- `--only NAME` (repeatable) imports a subset; `--list` prints the registry.
- Resume: a valid CSV on disk skips the download; an existing
  `geonames.<table>` skips the ingest. A dataset that failed to prepare is
  never ingested.
- Logs: `geonames_<dataset>_<timestamp>.log`.

### `rbt import buildings` — Overture Maps buildings

Skips entirely if `overture.building` already exists. Otherwise: `aws s3 sync`
(unsigned) the pinned release's buildings theme from the public Overture
bucket → ogr2ogr `type=building` into `overture.building` → optionally
`type=building_part` into `overture.buildingpart` (failures there warn but
don't fail the import) → `ANALYZE`.

- `--release TEXT` overrides the pinned release (`OVERTURE_RELEASE`,
  default `2026-06-17.0`); `--skip-parts` skips the optional building-parts
  ingest.
- Resume: the S3 sync is incremental, and the table-existence check makes
  re-runs cheap.
- Logs: `buildings_s3_sync_<timestamp>.log`,
  `buildings_ingest_building_<timestamp>.log`.

### Individual Schema Processing

`rbt schema list` shows the registered units (defined in the `schemas:` block of `config/layers.yml`):

| Key | Type | SQL file | Description |
|---|---|---|---|
| `physical` | physical | `physical/physical-core.sql` | Core physical views (built-up areas, glaciers, mountain labels, parks) |
| `landcover` | physical | `physical/landcover.sql` | Landcover polygon and label views |
| `water` | physical | `physical/water-features.sql` | Water bodies, waterways, and water labels |
| `contour` | physical | `physical/terrain.sql` | Contour and glacier-contour zoom views |
| `cultural` | cultural | `cultural/cultural-core.sql` | Core cultural views (boundaries, buildings, places, cemeteries, ports, utilities, military) |
| `highway` | cultural | `cultural/transportation.sql` | Road network views (highway zoom variants) |
| `railway` | cultural | `cultural/transportation-railway.sql` | Railways, stations, and yard labels |
| `aero` | cultural | `cultural/infrastructure.sql` | Aviation views (airports, heliports, runways, aeroway surfaces) |

For the lowest-level escape hatch, the SQL files can still be fed to `psql` by hand from their own directory, but `rbt schema run` adds `ON_ERROR_STOP`, per-unit logs under `output/logs/`, and the resolved connection environment.

## 📁 Directory Structure

```text
setup/
├── README.md                     # This documentation
└── data-sources/                 # Importer configuration + schema SQL
    ├── osm/                      # OpenStreetMap import configuration
    │   ├── imposm-config.json    # Imposm3 configuration
    │   └── imposm-mapping.yaml   # OSM tag mappings (optimized)
    │
    └── schemas/                  # SQL units executed by `rbt schema run`
        ├── physical/             # Physical feature processing
        │   ├── physical-core.sql           # Core physical features (glaciers, parks, mountains)
        │   ├── water-features.sql          # Water body processing with classification
        │   ├── landcover.sql               # Land cover classification and zoom levels
        │   └── terrain.sql                 # Elevation contours and terrain features
        │
        └── cultural/             # Cultural feature processing
            ├── cultural-core.sql             # Core cultural features (ports, places, utilities)
            ├── transportation.sql            # Roads and highway classification
            ├── transportation-railway.sql    # Railway systems and stations
            └── infrastructure.sql            # Airports and aviation infrastructure
```

The importer *logic* lives in the Python package (`src/rbt/importers/`); this
directory holds only the imposm configuration files and the schema SQL.

## 🗃️ Data Sources

### OpenStreetMap (OSM)

- **Source**: OpenStreetMap planet file (~83GB)
- **Update**: Continuous via daily diffs (configurable sequence range)
- **Import Tool**: Imposm3 with optimized mapping configuration
- **Schema**: `import.*` tables with enhanced tag processing
- **Features**: Multi-mirror downloads, integrity validation, diff merging

### Reference Datasets

**Administrative & Political**:

- **FieldMaps**: Global administrative boundaries (ADM0/1/2 polygons, lines, labels)
- **Natural Earth**: Cartographic reference data (1:10m scale, 160+ layers)
- **MIRTA**: US military installations and facilities

**Geographic Names**:

- **GeoNames (NGA)**: 11 datasets including administrative regions, hydrographic features
- **USGS Geographic Names**: US populated places and historical features

**Aviation & Transportation**:

- **OurAirports**: Global aviation facilities with runway details and surface mapping
- **OSM Transportation**: Enhanced highway/railway classification

**Water & Coastlines**:

- **OSM Ocean**: Water polygons with simplified versions for different zoom levels
- **OSM Coastlines**: High-precision coastline data  
- **OSM Antarctica**: Ice sheet polygons

**Building Data**:

- **Overture Maps**: Global building footprints with parts/levels (2024+ release)

## ⚙️ Processing Pipeline

### 1. Data Download and Validation

Each importer provides:

- **Parallel downloads** with configurable pool sizes
- **Integrity validation** with size and content checks  
- **Retry mechanisms** with configurable attempts and delay
- **Resume semantics** — valid files on disk and existing tables are skipped
- **Structured logging** with one log file per job

### 2. Database Import

Using GDAL/OGR with CI/CD optimized settings:

```bash
ogr2ogr -progress \
    --config PG_USE_COPY YES \
    -f PostgreSQL \
    -lco GEOMETRY_NAME=geometry \
    -lco DIM=2 \
    -lco UNLOGGED=ON \
    -skipfailures \
    "PG:host=$DATABASE_HOST dbname=$DATABASE_NAME user=$DATABASE_USER" \
    input_data_source
```

The password never appears in the command line: ogr2ogr reads it from
`PGPASSWORD`, supplied per process by the CLI.

### 3. Schema Processing

Modular SQL units dispatched by `rbt schema run`:

- **Strict execution** — each unit runs with `ON_ERROR_STOP=1`, so a failing statement aborts that unit instead of silently continuing
- **Materialized views** for optimal query performance
- **GIN trigram indexes** for fuzzy text matching
- **Zoom-level views** for efficient tile generation
- **Per-unit logs** under `output/logs/schema_<key>_<timestamp>.log`

## 🔧 Configuration

### Centralized Configuration with `rbt.conf`

All commands resolve configuration from `config/rbt.conf`, with environment variables taking precedence (`src/rbt/config.py`; legacy `PG_*` names are still accepted). A setting changed in one place affects every importer.

**Required** database connection settings (configured in `config/rbt.conf`):

```bash
# Database Connection Settings
DATABASE_HOST=${PG_HOST:-localhost}     # Database host
DATABASE_PORT=${PG_PORT:-5432}          # Database port  
DATABASE_NAME=${PG_DATABASE:-rbt}       # Database name
DATABASE_USER=${PG_USR:-postgres}       # Database user
DATABASE_PASSWORD=${PG_PASS:-}          # Database password
```

**Common processing settings**:

```bash
# Logging and Temporary Directories
SHARED_LOG_DIR=${SHARED_LOG_DIR:-./output/logs}    # Centralized log directory
SHARED_TEMP_DIR=${SHARED_TEMP_DIR:-./output/temp}  # Centralized temp directory

# Processing Settings
MAX_PARALLEL_JOBS=${MAX_PARALLEL_JOBS:-4}   # Concurrent ingest jobs
RETRY_COUNT=${RETRY_COUNT:-3}               # Retry attempts per job
RETRY_DELAY=${RETRY_DELAY:-30}              # Retry delay (seconds)

# Processing Options
DEBUG=${DEBUG:-false}                        # Debug mode
VERBOSE=${VERBOSE:-false}                    # Verbose logging
CLEAN_TEMP_FILES=${CLEAN_TEMP_FILES:-false}  # Cleanup temp files
```

The former `SCRIPT_*`-prefixed aliases (`SCRIPT_MAX_PARALLEL_JOBS`,
`SCRIPT_RETRY_COUNT`, …) are retired along with the bash importers — see the
[Configuration Reference](configuration.md#retired-script_-aliases) for the
migration table. `SCRIPT_DEBUG`/`SCRIPT_VERBOSE` remain accepted as aliases of
`DEBUG`/`VERBOSE`.

**OSM-Specific Configuration**:

```bash
# OSM Data Import Configuration
OSM_DATA_DIR=${OSM_DATA_DIR:-/mnt/data}                      # Data directory
OSM_CACHE_DIR=${OSM_CACHE_DIR:-/mnt/cache}                   # Cache directory
OSM_DIFF_DIR=${OSM_DIFF_DIR:-/mnt/diff}                      # Diff directory

# Download Settings
ARIA2C_MAX_DOWNLOADS=${ARIA2C_MAX_DOWNLOADS:-12}             # Parallel downloads
ARIA2C_MAX_CONNECTIONS=${ARIA2C_MAX_CONNECTIONS:-16}         # Connections per server
ARIA2C_SPLITS=${ARIA2C_SPLITS:-9}                            # Download splits
WGET_PARALLEL_JOBS=${WGET_PARALLEL_JOBS:-8}                  # Download pool size (name kept for compatibility)

# Diff Processing Settings
DIFF_START_SEQ=${DIFF_START_SEQ:-713}                        # Start sequence
DIFF_END_SEQ=${DIFF_END_SEQ:-730}                            # End sequence

# Processing Options
OSM_CLEANUP_ON_EXIT=${OSM_CLEANUP_ON_EXIT:-true}             # Clean intermediates after a full run
OSM_VALIDATE_DOWNLOADS=${OSM_VALIDATE_DOWNLOADS:-true}       # Validate downloads
```

**Overture Buildings Configuration**:

```bash
OVERTURE_RELEASE=${OVERTURE_RELEASE:-2026-06-17.0}                   # Pinned release
OVERTURE_S3_BUCKET=${OVERTURE_S3_BUCKET:-s3://overturemaps-us-west-2/}  # Public bucket
```

### Configuration Usage

**Default Usage** (uses `config/rbt.conf` settings):
```bash
# All commands automatically load configuration
rbt setup --all
rbt import osm --stage download-planet
rbt import geonames
```

**Custom Configuration File**:
```bash
# Edit the configuration file to change defaults
vim config/rbt.conf

# Example customizations:
DEBUG=true                               # Enable debug mode globally
MAX_PARALLEL_JOBS=8                      # Increase parallel jobs
SHARED_LOG_DIR=/var/log/rbt              # Custom log directory
OSM_DATA_DIR=/fast/storage/osm-data      # Use faster storage for OSM
```

**Override Individual Settings** (environment variables take precedence):
```bash
# Override specific settings for a single run
DEBUG=true rbt import geonames

# Custom data directory for OSM import
OSM_DATA_DIR=/tmp/osm-data rbt import osm --stage download-planet
```

### Resource Requirements

**Minimum**:

- 32GB RAM
- 8c CPU
- 3TB disk space for database
- 2TB disk space for processing
- Stable internet connection (multi-GB downloads)

**Recommended**:

- 512GB+ RAM
- 64+ cores CPU
- 6TB NVMe SSD storage for database with separate NVMe volumes for `pg_wal` and `logs`
- 6TB NVMe SSD for raw data storage of reference data and imposm3 cache
- 6TB NVMe SSD for Tile generation output
- 6TB NVMe SSD for temp directory storage used by duckdb and tippecanoe
- High-bandwidth internet connection 10GbE+ for fast downloads and transfers to S3

## 🕐 Timing Expectations

With recommended hardware and parallel processing enabled:

| Phase | Duration | Description |
|-------|----------|-------------|
| OSM Import | 24 hours | Multi-mirror download + diff processing + import |
| Reference Data | 60-90 minutes | Parallel import of all reference datasets |
| GeoNames Data | 60-90 minutes | Parallel download and ingestion (11 datasets) |
| Buildings Data | 24 hours | Overture Maps building data from S3 |
| Schema Processing | 2-4 hours | Materialized views and indexes |

**Performance Notes**:

- **`rbt import reference --parallel`** can reduce reference data import time by 50-70%
- **SSD storage** significantly improves schema processing speed
- **High-bandwidth internet** critical for large dataset downloads
- **Memory allocation** affects materialized view creation time

## 🐛 Troubleshooting

### Common Issues

#### 1. Insufficient Memory

```bash
# Symptoms: Out of memory errors during processing
# Solution: Increase PostgreSQL memory settings
export DATABASE_WORK_MEM=64GB
export DATABASE_MAINTENANCE_WORK_MEM=128GB
```

#### 2. Disk Space Issues

```bash
# Check available space
df -h .
# Clean up temporary files (default location)
rm -rf ./output/temp/
# Or check configured temp directory
echo "Temp directory: ${SHARED_TEMP_DIR:-./output/temp}"
rm -rf "${SHARED_TEMP_DIR:-./output/temp}/*"
```

#### 3. Network Timeouts

```bash
# Edit config/rbt.conf to increase retry settings
RETRY_COUNT=5
RETRY_DELAY=60

# Or override for a single run
RETRY_COUNT=5 RETRY_DELAY=60 rbt import osm --stage download-planet
```

#### 4. Database Connection Errors

```bash
# Full pre-flight report (config, tools, DB, disk, memory)
rbt validate

# Or test the connection manually
psql "host=$DATABASE_HOST dbname=rbt user=$DATABASE_USER password=$DATABASE_PASSWORD" -c "SELECT version();"
```

### Enhanced Debug Mode

Enable comprehensive debugging and logging:

```bash
# Method 1: Edit config/rbt.conf for persistent debug settings
vim config/rbt.conf
# Set: DEBUG=true and VERBOSE=true

# Method 2: Override for specific runs
rbt --debug setup --all

# Debug specific components
rbt --debug import geonames
rbt --debug import buildings

# Preview the exact external commands without executing anything
rbt import osm --dry-run
rbt import reference --dry-run
```

### Schema Processing Options

Process schema units individually for troubleshooting:

```bash
# Process only specific physical units
rbt schema run landcover
rbt schema run water

# Process only specific cultural units
rbt schema run cultural
rbt schema run highway
rbt schema run railway
rbt schema run aero

# Inspect the unit registry and preview without executing
rbt schema list
rbt schema run water --dry-run
```

### Logging and Monitoring

All commands provide comprehensive logging with different levels of detail.

**Log Locations** (centralized in `${SHARED_LOG_DIR}`, defaults to `./output/logs`):

```bash
# Per-invocation rbt CLI log
./output/logs/rbt_YYYYMMDD_HHMMSS.log

# Per-job importer logs (one file per dataset/stage)
./output/logs/osm_download_planet_YYYYMMDD_HHMMSS.log
./output/logs/osm_import_YYYYMMDD_HHMMSS.log
./output/logs/reference_fieldmaps_adm0_YYYYMMDD_HHMMSS.log
./output/logs/geonames_populated_places_YYYYMMDD_HHMMSS.log
./output/logs/buildings_s3_sync_YYYYMMDD_HHMMSS.log

# Schema processing logs (one per unit)
./output/logs/schema_physical_YYYYMMDD_HHMMSS.log
./output/logs/schema_landcover_YYYYMMDD_HHMMSS.log
./output/logs/schema_water_YYYYMMDD_HHMMSS.log
./output/logs/schema_contour_YYYYMMDD_HHMMSS.log
./output/logs/schema_cultural_YYYYMMDD_HHMMSS.log
./output/logs/schema_highway_YYYYMMDD_HHMMSS.log
./output/logs/schema_railway_YYYYMMDD_HHMMSS.log
./output/logs/schema_aero_YYYYMMDD_HHMMSS.log
```

**Monitoring During Execution**:

- **Progress output** in terminal (ogr2ogr/aria2c progress where available)
- **Job status tracking** for parallel operations (completed/failed per job)
- **Structured error reporting** — all failed jobs are listed at the end of a run

### Recovery and Resumption

If setup fails partway through:

1. **Check logs** in `output/logs/` (per-job files pinpoint the failing dataset)
2. **Identify failed step** from structured log output — failed job names are summarized at the end of the run
3. **Fix underlying issue** (disk space, network, permissions, etc.)
4. **Resume setup** — re-running `rbt setup` is safe; importers skip completed work, or target the failed step directly (`rbt setup --import-geonames`)

**Selective Recovery**:

```bash
# Skip completed data imports and only reprocess schemas
rbt schema run --all

# Re-import only a specific dataset by name
rbt import geonames --only populated_places
rbt import reference --only mirta

# Run every reference dataset in one pool to speed up re-runs
rbt import reference --parallel
```

## 🔍 Validation

After setup completion, validate the installation:

```bash
# Full validation: config, tools, database, extensions, schemas, disk, memory
rbt validate

# End-to-end sanity check (validate, bootstrap, schemas, tile dry-runs)
rbt smoke

# Inspect schemas and views manually
psql "host=$DATABASE_HOST dbname=rbt user=$DATABASE_USER password=$DATABASE_PASSWORD" -c "\dn+"      # List schemas
psql "host=$DATABASE_HOST dbname=rbt user=$DATABASE_USER password=$DATABASE_PASSWORD" -c "\dt+ rbt.*"  # List RBT tables
psql "host=$DATABASE_HOST dbname=rbt user=$DATABASE_USER password=$DATABASE_PASSWORD" -c "\dm+ rbt.*"  # List materialized views

# Test tile generation
rbt tiles --all --dry-run
```

## 📝 Next Steps

After successful setup:

1. **Start OSM updates**: `rbt osm run` (or `docker compose --profile production up -d rbt-osm-updates`)
2. **Generate initial tiles**: `rbt tiles --all`
3. **Schedule tile regeneration**: Set up cron jobs or automated triggers

The setup phase is now complete! All future operations use the `rbt` commands described in the [Operations Guide](operations.md).

## 📚 Related Documentation

- **[← Back to Home](index.md)**
- **[Getting Started Guide](getting-started.md)** - Complete setup walkthrough
- **[Architecture Overview](architecture.md)** - System design and data flow
- **[Database Initialization](database-initialization.md)** - Detailed database setup
- **[OSM Import Pipeline](osm-import.md)** - OpenStreetMap data processing
- **[Operations Guide](operations.md)** - Continuous operations after setup
