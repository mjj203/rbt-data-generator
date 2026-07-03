# Database Setup and Initialization

This directory contains the data import scripts and schema SQL used for one-time database initialization. The phase is orchestrated entirely by the `rbt` CLI: `rbt setup --all` downloads global datasets, imports them into PostgreSQL, and creates the optimized `rbt.*` views for tile generation.

## ⚠️ Important Note

**The setup phase runs ONCE when standing up a new RBT system.** After initialization is complete, ongoing operations (`rbt osm run`, `rbt tiles`) are covered by the [Operations Guide](operations.md).

## 🧭 How the Setup Phase Is Orchestrated

`rbt setup --all` runs three stages in dependency order (`src/rbt/setup_db.py`):

1. **Bootstrap** — creates the database and extensions (`postgis`, `postgis_raster`, `hstore`, `pg_trgm`) natively via psycopg. No bash involved.
2. **Data import** — the four importers in this directory remain Bash leaf scripts by design. Each carries a `CONTRACT` header documenting its inputs, outputs, and exit behavior:
    - [`data-sources/osm/import-osm-data.sh`](https://github.com/MJJ203/rbt-data-generator/blob/main/setup/data-sources/osm/import-osm-data.sh) — invoked via `rbt import osm`
    - [`data-sources/reference-data/import-reference-data.sh`](https://github.com/MJJ203/rbt-data-generator/blob/main/setup/data-sources/reference-data/import-reference-data.sh) — invoked via `rbt import reference`
    - [`data-sources/reference-data/import-geonames.sh`](https://github.com/MJJ203/rbt-data-generator/blob/main/setup/data-sources/reference-data/import-geonames.sh) — invoked via `rbt import geonames`
    - [`data-sources/reference-data/import-buildings.sh`](https://github.com/MJJ203/rbt-data-generator/blob/main/setup/data-sources/reference-data/import-buildings.sh) — invoked via `rbt import buildings`
3. **Schema processing** — `rbt schema run --all` executes the eight PL/pgSQL files under `data-sources/schemas/` through `psql -v ON_ERROR_STOP=1`, creating the materialized views and indexes that tile generation reads.

The leaf scripts are invoked only through the `rbt` CLI, which resolves `config/rbt.conf` and exports the `DATABASE_*`/`PG*` environment they expect. Do not run them directly.

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

### Manual Step-by-Step

If you need more control or want to run individual components:

```bash
# 0. Bootstrap the database and extensions
rbt setup --setup-database

# 1. Import OSM data (several hours) — a stage flag is required
rbt import osm -- --all

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
└── data-sources/                 # Data import scripts + schema SQL
    ├── osm/                      # OpenStreetMap data
    │   ├── import-osm-data.sh    # Leaf script for `rbt import osm`
    │   ├── imposm-config.json    # Imposm3 configuration
    │   └── imposm-mapping.yaml   # OSM tag mappings (optimized)
    │
    ├── reference-data/           # Non-OSM datasets
    │   ├── import-reference-data.sh  # Leaf script for `rbt import reference`
    │   ├── import-geonames.sh        # Leaf script for `rbt import geonames`
    │   └── import-buildings.sh       # Leaf script for `rbt import buildings`
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

Each import script provides:

- **Parallel downloads** with configurable connection limits
- **Integrity validation** with size and content checks  
- **Retry mechanisms** with exponential backoff
- **Progress indicators** and structured logging
- **Container-friendly** signal handling and health checks

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
    "PG:host=$DATABASE_HOST dbname=$DATABASE_NAME user=$DATABASE_USER password=$DATABASE_PASSWORD" \
    input_data_source
```

### 3. Schema Processing

Modular SQL units dispatched by `rbt schema run`:

- **Strict execution** — each unit runs with `ON_ERROR_STOP=1`, so a failing statement aborts that unit instead of silently continuing
- **Materialized views** for optimal query performance
- **GIN trigram indexes** for fuzzy text matching
- **Zoom-level views** for efficient tile generation
- **Per-unit logs** under `output/logs/schema_<key>_<timestamp>.log`

## 🔧 Configuration

### Centralized Configuration with `rbt.conf`

All commands resolve configuration from `config/rbt.conf`, with environment variables taking precedence (`src/rbt/config.py`; legacy `PG_*` names are still accepted). The same file is sourced by the Bash leaf scripts, so a setting changed in one place affects everything.

**Required** database connection settings (configured in `config/rbt.conf`):

```bash
# Database Connection Settings
DATABASE_HOST=${PG_HOST:-localhost}     # Database host
DATABASE_PORT=${PG_PORT:-5432}          # Database port  
DATABASE_NAME=${PG_DATABASE:-rbt}       # Database name
DATABASE_USER=${PG_USR:-postgres}       # Database user
DATABASE_PASSWORD=${PG_PASS:-}          # Database password
```

**Common Script Configuration** (standardized variables):

```bash
# Logging and Temporary Directories
SHARED_LOG_DIR=${SHARED_LOG_DIR:-./output/logs}    # Centralized log directory
SHARED_TEMP_DIR=${SHARED_TEMP_DIR:-./output/temp}  # Centralized temp directory

# Processing Settings
SCRIPT_MAX_PARALLEL_JOBS=${SCRIPT_MAX_PARALLEL_JOBS:-4}      # Concurrent jobs
SCRIPT_RETRY_COUNT=${SCRIPT_RETRY_COUNT:-3}                  # Retry attempts
SCRIPT_RETRY_DELAY=${SCRIPT_RETRY_DELAY:-30}                 # Retry delay (seconds)
SCRIPT_CONNECTION_TIMEOUT=${SCRIPT_CONNECTION_TIMEOUT:-300}  # Connection timeout

# Processing Options
SCRIPT_PARALLEL_INGESTION=${SCRIPT_PARALLEL_INGESTION:-false}  # Parallel processing
SCRIPT_DEBUG=${SCRIPT_DEBUG:-false}                            # Debug mode
SCRIPT_VERBOSE=${SCRIPT_VERBOSE:-false}                        # Verbose logging
SCRIPT_CLEAN_TEMP_FILES=${SCRIPT_CLEAN_TEMP_FILES:-false}      # Cleanup temp files
```

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
WGET_PARALLEL_JOBS=${WGET_PARALLEL_JOBS:-8}                  # Parallel diff downloads

# Diff Processing Settings
DIFF_START_SEQ=${DIFF_START_SEQ:-713}                        # Start sequence
DIFF_END_SEQ=${DIFF_END_SEQ:-730}                            # End sequence

# Processing Options
OSM_CLEANUP_ON_EXIT=${OSM_CLEANUP_ON_EXIT:-true}             # Clean temp files
OSM_VALIDATE_DOWNLOADS=${OSM_VALIDATE_DOWNLOADS:-true}       # Validate downloads
```

### Configuration Usage

**Default Usage** (uses `config/rbt.conf` settings):
```bash
# All commands automatically load configuration
rbt setup --all
rbt import osm -- --download-planet
rbt import geonames
```

**Custom Configuration File**:
```bash
# Edit the configuration file to change defaults
vim config/rbt.conf

# Example customizations:
SCRIPT_DEBUG=true                        # Enable debug mode globally
SCRIPT_MAX_PARALLEL_JOBS=8               # Increase parallel jobs
SHARED_LOG_DIR=/var/log/rbt              # Custom log directory
OSM_DATA_DIR=/fast/storage/osm-data      # Use faster storage for OSM
```

**Override Individual Settings** (environment variables take precedence):
```bash
# Override specific settings for a single run
SCRIPT_DEBUG=true SCRIPT_PARALLEL_INGESTION=true rbt import geonames

# Custom data directory for OSM import
OSM_DATA_DIR=/tmp/osm-data rbt import osm -- --download-planet
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

- **Parallel mode** can reduce reference data import time by 50-70%
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
SCRIPT_RETRY_COUNT=5
SCRIPT_RETRY_DELAY=60

# Or override for a single run
SCRIPT_RETRY_COUNT=5 SCRIPT_RETRY_DELAY=60 rbt import osm -- --download-planet
```

#### 4. Database Connection Errors

```bash
# Full pre-flight report (config, tools, DB, disk, memory)
rbt validate

# Or test the connection manually
psql "host=$DATABASE_HOST dbname=rbt user=$DATABASE_USER password=$DATABASE_PASSWORD" -c "SELECT version();"
```

### Enhanced Debug Mode

Enable comprehensive debugging and logging using standardized configuration:

```bash
# Method 1: Edit config/rbt.conf for persistent debug settings
vim config/rbt.conf
# Set: SCRIPT_DEBUG=true and SCRIPT_VERBOSE=true

# Method 2: Override for specific runs
# Debug-level CLI logging plus leaf-script tracing
SCRIPT_DEBUG=true SCRIPT_VERBOSE=true rbt --debug setup --all

# Debug specific components
SCRIPT_DEBUG=true SCRIPT_VERBOSE=true rbt import geonames
SCRIPT_DEBUG=true SCRIPT_VERBOSE=true rbt import buildings

# Preserve temporary files for inspection
SCRIPT_CLEAN_TEMP_FILES=false SCRIPT_DEBUG=true rbt import osm -- --all

# Enable parallel processing with debug output
SCRIPT_PARALLEL_INGESTION=true SCRIPT_DEBUG=true rbt import reference
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

# Individual importer logs (all centralized)
./output/logs/osm_import.log
./output/logs/database_setup_YYYYMMDD_HHMMSS.log
./output/logs/geonames_setup_YYYYMMDD_HHMMSS.log  
./output/logs/overture_buildings_YYYYMMDD_HHMMSS.log

# Schema processing logs (one per unit)
./output/logs/schema_physical_YYYYMMDD_HHMMSS.log
./output/logs/schema_landcover_YYYYMMDD_HHMMSS.log
./output/logs/schema_water_YYYYMMDD_HHMMSS.log
./output/logs/schema_contour_YYYYMMDD_HHMMSS.log
./output/logs/schema_cultural_YYYYMMDD_HHMMSS.log
./output/logs/schema_highway_YYYYMMDD_HHMMSS.log
./output/logs/schema_railway_YYYYMMDD_HHMMSS.log
./output/logs/schema_aero_YYYYMMDD_HHMMSS.log

# Job-specific logs (parallel processing) in temp directory
${SHARED_TEMP_DIR}/[job_name].log  # Default: ./output/temp/[job_name].log
```

**Log Format**:

```text
[YYYY-MM-DD HH:MM:SS] [PID] [LEVEL] MESSAGE
[INFO] Job completed: fieldmaps_adm0
[ERROR] Failed to download: https://example.com/data.zip
[PROGRESS] Starting all data ingestion jobs in parallel...
```

**Monitoring During Execution**:

- **Progress bars** in terminal (when available)
- **Job status tracking** for parallel operations
- **Health check endpoints** for container orchestration
- **Structured error reporting** with context

### Recovery and Resumption

If setup fails partway through:

1. **Check logs** in `output/logs/` and the temp directory
2. **Identify failed step** from structured log output
3. **Fix underlying issue** (disk space, network, permissions, etc.)
4. **Resume setup** — re-running `rbt setup` is safe; importers skip completed work, or target the failed step directly (`rbt setup --import-geonames`)
5. **Use parallel mode** to speed up re-runs: `SCRIPT_PARALLEL_INGESTION=true`

**Selective Recovery**:

```bash
# Skip completed data imports and only reprocess schemas
rbt schema run --all

# Re-import only specific reference datasets
rbt import geonames

# Preserve temp files for investigation
SCRIPT_CLEAN_TEMP_FILES=false rbt import buildings

# Enable parallel processing to speed up re-runs
SCRIPT_PARALLEL_INGESTION=true rbt import reference
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
