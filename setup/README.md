# Database Setup and Initialization

This directory contains all scripts and configurations needed for one-time database initialization. These scripts download global datasets, import them into PostgreSQL, and create optimized database views for tile generation.

## ⚠️ Important Note

**These scripts are run ONCE when setting up a new RBT system.** After initialization is complete, you'll use the scripts in `production/` for ongoing operations.

## ✨ New Features & Enhancements

### CI/CD Optimizations

- **Modular schema processing** with independent SQL files for each layer type
- **Transaction-based execution** prevents partial failures from corrupting the database
- **Comprehensive dependency validation** ensures all prerequisites are met
- **Structured logging** with timestamps, PIDs, and severity levels
- **Progress tracking** and status reporting for long-running operations

### Performance Improvements

- **Parallel data ingestion** with configurable job limits
- **Materialized views** for frequently-accessed spatial queries
- **GIN trigram indexes** for fast fuzzy text matching and pattern searches
- **Optimized spatial indexes** with clustering and vacuum operations
- **Memory-optimized settings** for large dataset processing

### Robustness Features

- **Automatic retry mechanisms** with exponential backoff
- **Graceful error handling** with cleanup and signal management
- **Container-friendly design** with health checks and signal handling
- **Resume capability** - scripts skip already-completed steps
- **Temporary file preservation** option for debugging

### Configuration Management

- **Centralized configuration** via `config/rbt.conf` eliminates duplicate variables
- **Standardized variable naming** with `SCRIPT_*` prefix for common settings
- **Consistent behavior** across all scripts with shared retry logic and timeouts
- **Easy customization** - change settings in one place, affects all scripts
- **Centralized logging** - all script logs go to a shared directory
- **Environment override** support for per-run customizations

## 🚀 Quick Start

### Simple Setup

```bash
# From the project root directory
./setup/init-database.sh
```

This single command orchestrates the entire setup process with:

- Automatic environment validation
- Progress tracking and logging
- Error recovery capabilities
- Optimized parallel processing

### Manual Step-by-Step

If you need more control or want to run individual components:

```bash
# 1. Import OSM data (several hours)
./setup/data-sources/osm/import-osm-data.sh

# 2. Import reference datasets (1-2 hours)
./setup/data-sources/reference-data/import-reference-data.sh
./setup/data-sources/reference-data/import-geonames.sh  
./setup/data-sources/reference-data/import-buildings.sh

# 3. Process database schemas using wrapper scripts (30-60 minutes)
# Physical layers (core, landcover, water, terrain)
./setup/data-sources/schemas/physical/process-physical-schemas.sh --all

# Cultural layers (core, transportation, railway, infrastructure) 
./setup/data-sources/schemas/cultural/process-cultural-schemas.sh --all

# Or process individual schema types:
./setup/data-sources/schemas/physical/process-physical-schemas.sh --landcover
./setup/data-sources/schemas/cultural/process-cultural-schemas.sh --highway
```

### Individual Schema Processing

For fine-grained control, you can run individual SQL scripts:

```bash
cd setup/data-sources/schemas

# Physical layers
psql -f physical/physical-core.sql
psql -f physical/water-features.sql 
psql -f physical/landcover.sql
psql -f physical/terrain.sql

# Cultural layers  
psql -f cultural/cultural-core.sql
psql -f cultural/transportation.sql
psql -f cultural/transportation-railway.sql
psql -f cultural/infrastructure.sql
```

## 📁 Directory Structure

```text
setup/
├── init-database.sh              # Main setup orchestrator
├── README.md                     # This documentation
├── data-sources/                 # Data import scripts
│   ├── osm/                      # OpenStreetMap data
│   │   ├── import-osm-data.sh    # OSM planet import with diff handling
│   │   ├── imposm-config.json    # Imposm3 configuration
│   │   └── imposm-mapping.yaml   # OSM tag mappings (optimized)
│   │
│   ├── reference-data/           # Non-OSM datasets
│   │   ├── import-reference-data.sh  # FieldMaps, Natural Earth, MIRTA, OurAirports, OSM Ocean & Antarctica Glaciers
│   │   ├── import-geonames.sh        # Geographic names (parallel download)
│   │   └── import-buildings.sh       # Overture building footprints
│   │
│   └── schemas/                  # Database schema processing
│       ├── physical/             # Physical feature processing
│       │   ├── process-physical-schemas.sh  # Wrapper script for all physical layers
│       │   ├── physical-core.sql           # Core physical features (glaciers, parks, mountains)
│       │   ├── water-features.sql          # Water body processing with classification
│       │   ├── landcover.sql              # Land cover classification and zoom levels
│       │   └── terrain.sql                # Elevation contours and terrain features
│       │
│       └── cultural/             # Cultural feature processing
│           ├── process-cultural-schemas.sh   # Wrapper script for all cultural layers
│           ├── cultural-core.sql             # Core cultural features (ports, places, utilities)
│           ├── transportation.sql            # Roads and highway classification
│           ├── transportation-railway.sql    # Railway systems and stations
│           └── infrastructure.sql            # Airports and aviation infrastructure
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

Modular SQL scripts with enhanced features:

- **Transaction-based execution** with error isolation
- **Materialized views** for optimal query performance
- **GIN trigram indexes** for fuzzy text matching
- **Zoom-level views** for efficient tile generation
- **Comprehensive validation** and dependency checking
- **Parallel processing** support for large datasets
- **CI/CD optimizations** with structured logging

## 🔧 Configuration

### Centralized Configuration with `rbt.conf`

All scripts now use a centralized configuration file located at `config/rbt.conf`. This eliminates duplicate environment variables and provides consistent behavior across all scripts.

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
# All scripts automatically load configuration
./setup/init-database.sh --all
./setup/data-sources/osm/import-osm-data.sh --download-planet
./setup/data-sources/reference-data/import-geonames.sh
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
SCRIPT_DEBUG=true SCRIPT_PARALLEL_INGESTION=true ./setup/data-sources/reference-data/import-geonames.sh

# Custom data directory for OSM import
OSM_DATA_DIR=/tmp/osm-data ./setup/data-sources/osm/import-osm-data.sh --download-planet
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
| **Total** | **4-7 hours** | Complete database initialization |

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
SCRIPT_RETRY_COUNT=5 SCRIPT_RETRY_DELAY=60 ./setup/data-sources/osm/import-osm-data.sh --download-planet
```

#### 4. Database Connection Errors

```bash
# Test connection manually
psql "host=$PG_HOST dbname=rbt user=$PG_USR password=$PG_PASS" -c "SELECT version();"
```

### Enhanced Debug Mode

Enable comprehensive debugging and logging using standardized configuration:

```bash
# Method 1: Edit config/rbt.conf for persistent debug settings
vim config/rbt.conf
# Set: SCRIPT_DEBUG=true and SCRIPT_VERBOSE=true

# Method 2: Override for specific runs
# Full debug mode for all scripts
SCRIPT_DEBUG=true SCRIPT_VERBOSE=true ./setup/init-database.sh

# Debug specific components
SCRIPT_DEBUG=true SCRIPT_VERBOSE=true ./setup/data-sources/reference-data/import-geonames.sh
SCRIPT_DEBUG=true SCRIPT_VERBOSE=true ./setup/data-sources/reference-data/import-buildings.sh

# Preserve temporary files for inspection
SCRIPT_CLEAN_TEMP_FILES=false SCRIPT_DEBUG=true ./setup/data-sources/osm/import-osm-data.sh

# Enable parallel processing with debug output
SCRIPT_PARALLEL_INGESTION=true SCRIPT_DEBUG=true ./setup/data-sources/reference-data/import-reference-data.sh
```

### Schema Processing Options

Process schemas individually for troubleshooting:

```bash
# Process only specific physical layers
./setup/data-sources/schemas/physical/process-physical-schemas.sh --landcover
./setup/data-sources/schemas/physical/process-physical-schemas.sh --water

# Process only specific cultural layers  
./setup/data-sources/schemas/cultural/process-cultural-schemas.sh --cultural
./setup/data-sources/schemas/cultural/process-cultural-schemas.sh --highway
./setup/data-sources/schemas/cultural/process-cultural-schemas.sh --railway
./setup/data-sources/schemas/cultural/process-cultural-schemas.sh --aero
```

### Logging and Monitoring

All scripts provide comprehensive logging with different levels of detail:

**Log Locations** (centralized in `${SHARED_LOG_DIR}`, defaults to `./output/logs`):

```bash
# Main initialization log
./output/logs/database_init_YYYYMMDD_HHMMSS.log

# Individual script logs (all centralized)
./output/logs/osm_import.log
./output/logs/database_setup_YYYYMMDD_HHMMSS.log
./output/logs/geonames_setup_YYYYMMDD_HHMMSS.log  
./output/logs/overture_buildings_YYYYMMDD_HHMMSS.log

# Schema processing logs (centralized)
./output/logs/cultural_execution_YYYYMMDD_HHMMSS.log
./output/logs/highway_execution_YYYYMMDD_HHMMSS.log
./output/logs/railway_execution_YYYYMMDD_HHMMSS.log
./output/logs/aero_execution_YYYYMMDD_HHMMSS.log
./output/logs/physical_execution_YYYYMMDD_HHMMSS.log
./output/logs/landcover_execution_YYYYMMDD_HHMMSS.log
./output/logs/water_execution_YYYYMMDD_HHMMSS.log
./output/logs/contour_execution_YYYYMMDD_HHMMSS.log

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

1. **Check logs** in `output/logs/` and individual script temp directories
2. **Identify failed step** from structured log output
3. **Fix underlying issue** (disk space, network, permissions, etc.)
4. **Resume setup** - scripts automatically skip completed steps
5. **Use parallel mode** to speed up re-runs: `SCRIPT_PARALLEL_INGESTION=true`

**Selective Recovery**:

```bash
# Skip completed data imports and only reprocess schemas
./setup/data-sources/schemas/physical/process-physical-schemas.sh --all
./setup/data-sources/schemas/cultural/process-cultural-schemas.sh --all

# Re-import only specific reference datasets
./setup/data-sources/reference-data/import-geonames.sh

# Preserve temp files for investigation using standardized variable
SCRIPT_CLEAN_TEMP_FILES=false ./setup/data-sources/reference-data/import-buildings.sh

# Enable parallel processing to speed up re-runs
SCRIPT_PARALLEL_INGESTION=true ./setup/data-sources/reference-data/import-reference-data.sh
```

## 🔍 Validation

After setup completion, validate the installation:

```bash
# Check database schemas and tables
psql "host=$PG_HOST dbname=rbt user=$PG_USR password=$PG_PASS" -c "\dn+"  # List schemas
psql "host=$PG_HOST dbname=rbt user=$PG_USR password=$PG_PASS" -c "\dt+ rbt.*"  # List RBT tables

# Check materialized views
psql "host=$PG_HOST dbname=rbt user=$PG_USR password=$PG_PASS" -c "\dm+ rbt.*"  # List materialized views

# Validate data integrity (if available)
./tools/health-check.sh

# Test tile generation
./production/generate-tiles.sh --dry-run
```

## 🔧 Schema Processing Details

### Wrapper Scripts

The schema processing has been modularized with wrapper scripts for easier management:

**Physical Layer Processing** (`process-physical-schemas.sh`):

```bash
# Process all physical layers
./process-physical-schemas.sh --all

# Process individual layers
./process-physical-schemas.sh --physical    # Core physical features  
./process-physical-schemas.sh --landcover  # Land cover classification
./process-physical-schemas.sh --water      # Water features and waterways
./process-physical-schemas.sh --contour    # Terrain and elevation contours
```

**Cultural Layer Processing** (`process-cultural-schemas.sh`):

```bash
# Process all cultural layers
./process-cultural-schemas.sh --all

# Process individual layers
./process-cultural-schemas.sh --cultural   # Core cultural features
./process-cultural-schemas.sh --highway    # Road and highway networks
./process-cultural-schemas.sh --railway    # Railway systems and stations
./process-cultural-schemas.sh --aero       # Aviation infrastructure
```

## 📝 Next Steps

After successful setup:

1. **Start OSM updates**: `./production/update-osm.sh run &`
2. **Generate initial tiles**: `./production/generate-tiles.sh --all`
3. **Schedule tile regeneration**: Set up cron jobs or automated triggers

The setup phase is now complete! All future operations use scripts in the `production/` directory.

## 📚 Related Documentation

- **[← Back to Home](index.md)**
- **[Getting Started Guide](getting-started.md)** - Complete setup walkthrough
- **[Architecture Overview](architecture.md)** - System design and data flow
- **[Database Initialization](database-initialization.md)** - Detailed database setup
- **[OSM Import Pipeline](osm-import.md)** - OpenStreetMap data processing
- **[Production Documentation](production-readme.md)** - Continuous operations after setup
