# RBT Vector Tiles

A comprehensive, open-source system for generating multi-projection vector tiles from authoritative geospatial data sources including OpenStreetMap, Natural Earth, GeoNames, and Overture Maps.

## 🌟 Features

- **Multi-projection support**: Web Mercator (3857), World Mercator (3395), and Geographic (4326)
- **Authoritative data sources**: OSM, Natural Earth, GeoNames, Overture Maps, FieldMaps
- **Production-ready**: Continuous OSM updates and automated tile generation
- **Container-friendly**: Docker and Kubernetes deployment support
- **Highly optimized**: Parallel processing and performance-tuned database operations
- **Modular architecture**: Separate processing for physical and cultural features
- **Granular control**: Generate specific layers or projections as needed
- **CI/CD optimized**: Transaction-based execution with comprehensive error handling
- **Advanced metadata**: BTIS metadata support with BTP schema versioning
- **Community-focused**: Clear documentation and contribution guidelines

## ✨ Recent Enhancements

### Configuration Management

- **🎯 Centralized Configuration** - Single `rbt.conf` file for all settings
- **🔄 Backward Compatibility** - Environment variables still supported
- **🛡️ Reduced Duplication** - Consistent configuration across all scripts
- **📝 Self-Documenting** - Clear variable descriptions and logical groupings

### Setup Optimizations
- **Modular schema processing** with independent SQL files for each layer type
- **Transaction-based execution** prevents partial failures from corrupting the database
- **Parallel data ingestion** with configurable job limits for faster imports
- **Comprehensive error handling** with retry mechanisms and graceful recovery
- **Container-friendly design** with health checks and signal handling

### Production Features
- **Granular layer selection** - generate specific physical or cultural layers
- **Multi-format output** - MBTiles for web serving, PBF directories for analysis
- **BTIS metadata support** with CRS information and tile origins
- **Tile consolidation** - merge multiple layers into single MBTiles files
- **BTP schema versioning** for consistent metadata standards

### Performance Improvements
- **Materialized views** for frequently-accessed spatial queries
- **GIN trigram indexes** for fast fuzzy text matching and pattern searches
- **Optimized spatial indexes** with clustering and vacuum operations
- **Memory-optimized settings** for large dataset processing
- **Resume capability** - scripts skip already-completed steps

## 🚀 Quick Start

### Prerequisites

- PostgreSQL 17+ with PostGIS 3.5+
- GDAL/OGR 3.11+ with MVT driver
- Imposm3 (latest version)
- Tippecanoe (latest version)
- Minimum 16GB RAM, 100GB disk space

### Installation

1. **Clone and configure**:
```bash
git clone https://github.com/your-org/rbt-vector-tiles.git
cd rbt-vector-tiles

# Configuration is centralized in config/rbt.conf
# Edit database credentials and processing settings
vi config/rbt.conf

# Or use environment variables for compatibility
cp env.example .env
# Edit .env with your database credentials (optional)
```

2. **Validate environment**:

```bash
./tools/validate-environment.sh
```

3. **Initialize database** (one-time setup):

```bash
./setup/init-database.sh
```

*This step takes several hours as it downloads and processes global datasets*

4. **Start continuous operations**:
```bash
# Start OSM updates (background process)
nohup ./production/update-osm.sh run > osm-updates.log 2>&1 &

# Generate vector tiles (consolidation and metadata enabled by default)
./production/generate-tiles.sh --all
```

### Advanced Setup

For more control over the setup process:

```bash
# High-performance parallel setup
PARALLEL_INGESTION=true ./setup/init-database.sh

# Debug mode for troubleshooting
DEBUG=true VERBOSE=true ./setup/init-database.sh

# Individual data source processing
./setup/data-sources/osm/import-osm-data.sh
./setup/data-sources/reference-data/import-reference-data.sh  
./setup/data-sources/reference-data/import-geonames.sh
./setup/data-sources/reference-data/import-buildings.sh

# Modular schema processing
./setup/data-sources/schemas/physical/process-physical-schemas.sh --all
./setup/data-sources/schemas/cultural/process-cultural-schemas.sh --all
```

## ⚙️ Configuration System

The RBT Vector Tiles system uses a **centralized configuration file** (`config/rbt.conf`) to manage all settings, eliminating duplication and providing a single source of truth for configuration.

### Key Benefits

- **🎯 Centralized Management**: All configuration in one place
- **🔄 Backward Compatible**: Existing environment variables still work
- **🛡️ Error Reduction**: Consistent configuration across all scripts
- **📝 Self-Documenting**: Clear variable descriptions and groupings
- **🔧 Easy Maintenance**: Change settings once, affects all components

### Configuration Structure

The `rbt.conf` file is organized into logical sections:

```bash
# General Processing Settings
MAX_PARALLEL_JOBS=4
RETRY_COUNT=3
LOG_LEVEL=INFO

# Database Configuration
DATABASE_HOST=localhost
DATABASE_PORT=5432
DATABASE_NAME=rbt
DATABASE_USER=postgres
DATABASE_PASSWORD=your_password

# Tile Generation Settings
TILE_CACHE_DIR=./output/tiles
TILE_TEMP_DIR=/mnt/data
TILE_MAX_ZOOM=13
DEFAULT_PROJECTION=3857

# OSM Data Import Configuration
OSM_DATA_DIR=/mnt/data
OSM_CACHE_DIR=/mnt/cache
OSM_CONNECTION=postgis://postgres:pass@localhost/rbt?prefix=NONE
```

### Environment Variable Compatibility

The configuration system maintains **full backward compatibility** with existing environment variables:

```bash
# These environment variables still work and take precedence
export PG_HOST=database-server
export PG_USR=rbt_user
export PG_PASS=secure_password

# But the centralized config provides defaults and consistency
DATABASE_HOST=${PG_HOST:-localhost}
DATABASE_USER=${PG_USR:-postgres}
DATABASE_PASSWORD=${PG_PASS:-}
```

## 📁 Project Structure

```
rbt-vector-tiles/
├── setup/                    # 🔧 One-time initialization
│   ├── init-database.sh      # Main setup orchestrator
│   ├── data-sources/         # Modular data import scripts
│   │   ├── osm/              # OpenStreetMap import with Imposm3
│   │   ├── reference-data/   # FieldMaps, Natural Earth, GeoNames, Buildings
│   │   └── schemas/          # Database schema processing
│   │       ├── physical/     # Physical feature processing (modular SQL)
│   │       └── cultural/     # Cultural feature processing (modular SQL)
│   └── README.md            # Detailed setup documentation
├── production/               # 🏭 Continuous operations  
│   ├── generate-tiles.sh     # Unified tile generation with granular control
│   ├── update-osm.sh         # OSM continuous updates
│   ├── tile-generation/      # Projection and layer-specific scripts
│   │   ├── physical/         # Physical tiles (3857/3395/4326)
│   │   └── cultural/         # Cultural tiles (3857/3395/4326)
│   └── README.md            # Production operations guide
├── config/                   # ⚙️ Configuration files
│   └── rbt.conf              # Centralized configuration (database, processing, OSM)
├── tools/                    # 🛠️ Utilities and maintenance
│   └── validate-environment.sh
├── docs/                     # 📚 Documentation
└── output/                   # 📤 Generated outputs
    ├── tiles/                # Vector tiles (organized by projection)
    ├── logs/                 # Processing logs with timestamps
    └── metrics/              # Performance metrics
```

## 🎯 Usage Examples

### Basic Operations

```bash
# Generate all tiles in all projections with consolidation and metadata
./production/generate-tiles.sh --all

# Generate only physical tiles in Web Mercator
./production/generate-tiles.sh --layer-type physical --projection 3857

# Generate cultural tiles in all projections
./production/generate-tiles.sh --layer-type cultural --projection all

# Check what would be generated (dry run)
./production/generate-tiles.sh --dry-run --verbose
```

### Granular Layer Control

```bash
# Generate specific physical layers
./production/generate-tiles.sh --layer-type physical --water --waterway --landcover

# Generate specific cultural layers with metadata
./production/generate-tiles.sh --layer-type cultural --transportation --building --boundary --add-btis

# Generate water-related layers for hydrological mapping
./production/generate-tiles.sh --layer-type physical --water --waterway --inland-water --projection all

# Generate terrain layers for topographic mapping  
./production/generate-tiles.sh --layer-type physical --contour --glacier --mountain --tile-join
```

### Advanced Processing

```bash
# High-performance generation with custom temp directory
./production/generate-tiles.sh --all --temp-dir /mnt/nvme/temp --tile-join --add-btis

# Development workflow - single layer with verbose output  
./production/generate-tiles.sh --layer-type cultural --building --projection 3857 --verbose --dry-run

# Production deployment with full metadata and custom version
./production/generate-tiles.sh --all --tile-join --add-btis --version "2.0.0"
```

### OSM Updates

```bash
# Start continuous OSM updates (background process)
nohup ./production/update-osm.sh run > osm-updates.log 2>&1 &

# Check update status
./production/update-osm.sh status

# Stop updates
./production/update-osm.sh stop

# Run once for testing
./production/update-osm.sh run
```

## 🗺️ Generated Tile Layers

### Physical Layers
- **Terrain**: Contour lines, mountain labels, elevation data
- **Hydrology**: Water bodies, waterways, coastal features
- **Land Cover**: Vegetation, land use, glaciers, urban areas
- **Recreation**: Parks, protected areas, recreational facilities

### Cultural Layers
- **Transportation**: Roads, railways, airports, ferry routes
- **Boundaries**: Administrative boundaries (country, state, county)
- **Infrastructure**: Utilities, power lines, pipelines, communication
- **Buildings**: Building footprints with height and classification
- **Points of Interest**: Populated places, landmarks, facilities

## 📤 Output Structure

Vector tiles are organized by projection and layer type in `output/tiles/`:

```
output/tiles/
├── physical/
│   ├── 3857/                          # Web Mercator physical tiles
│   │   ├── water_3857.mbtiles         # Individual layer files
│   │   ├── waterway_3857.mbtiles
│   │   ├── landcover_3857.mbtiles
│   │   └── physical_3857.mbtiles      # Consolidated file (--tile-join)
│   ├── 3395/                          # World Mercator physical tiles
│   │   └── physical_3395.mbtiles      # Better area preservation
│   └── 4326/                          # Geographic physical tiles
│       ├── metadata.json              # Layer metadata and configuration
│       └── [z]/[x]/[y].pbf            # Directory-based tile structure
└── cultural/
    ├── 3857/                          # Web Mercator cultural tiles
    │   ├── highway_3857.mbtiles       # Individual transportation layers
    │   ├── railway_3857.mbtiles
    │   ├── building_3857.mbtiles
    │   └── cultural_3857.mbtiles      # Consolidated file (--tile-join)
    ├── 3395/                          # World Mercator cultural tiles
    │   └── cultural_3395.mbtiles
    └── 4326/                          # Geographic cultural tiles
        ├── metadata.json              # Layer metadata and configuration
        └── [z]/[x]/[y].pbf            # Directory-based tile structure
```

### Output Formats

**MBTiles (3857, 3395)**:
- SQLite-based archives optimized for web serving
- Support for BTIS metadata with CRS and tile origin information
- Individual layer files and optional consolidated files
- Compatible with standard tile servers

**PBF Directories (4326)**:
- Standard Mapbox Vector Tile format in directories
- Preserves lat/lon accuracy for analysis applications
- Includes embedded metadata.json configuration
- GDAL MVT driver optimized for geographic projection

## 🐳 Docker Deployment

```bash
# Step 1: One-time database initialization
docker-compose --profile setup up rbt-setup

# Step 2: Start production services (OSM updates + tile generation)
docker-compose --profile production up -d

# Step 3 (Optional): Start with tile server
docker-compose --profile production --profile serve up -d

# Generate tiles manually
docker-compose exec rbt-tiles ./production/generate-tiles.sh --all

# Check OSM update status
docker-compose exec rbt-osm-updates ./production/update-osm.sh status
```

### Docker Configuration

Configuration can be provided via environment variables in `.env` file or mounted `config/` directory:

```bash
# Mount config directory
-v ./config:/app/config

# Or use environment variables
PG_USR=rbt_user
PG_PASS=rbt_password
```

## 🧪 Smoke Test

Quickly verify the toolchain without processing full datasets:

- Local: `./tools/smoke-test.sh`
- Docker Compose: `docker-compose --profile smoke up rbt-smoke`

The smoke test validates environment settings, ensures the database and schemas exist, runs tile-generation dry runs, and performs a basic `psql` connectivity check. Logs are stored in `output/logs/`.

## ⚙️ Configuration Management

### Centralized Configuration (Recommended)

The primary configuration method uses the centralized `config/rbt.conf` file:

```bash
# Edit the main configuration file
vi config/rbt.conf
```

Key configuration sections in `rbt.conf`:

```bash
# General Processing Settings
MAX_PARALLEL_JOBS=4
RETRY_COUNT=3
RETRY_DELAY=30
LOG_LEVEL=INFO

# Tile Generation Settings
TILE_CACHE_DIR=./output/tiles
TILE_TEMP_DIR=/mnt/data
TILE_MAX_ZOOM=13
TILE_MIN_ZOOM=0
DEFAULT_PROJECTION=3857

# Database Configuration
DATABASE_HOST=localhost
DATABASE_PORT=5432
DATABASE_NAME=rbt
DATABASE_USER=postgres
DATABASE_PASSWORD=your_password

# Database Performance Settings
DATABASE_WORK_MEM=32GB
DATABASE_MAINTENANCE_WORK_MEM=64GB
DATABASE_MAX_PARALLEL_WORKERS=8

# OSM Data Import Configuration
OSM_DATA_DIR=/mnt/data
OSM_CACHE_DIR=/mnt/cache
OSM_CONFIG_FILE=./setup/data-sources/osm/imposm-config.json

# Resource Limits
DISK_SPACE_REQUIRED_GB=100
MEMORY_REQUIRED_GB=16

# Health Check Settings
HEALTH_CHECK_PORT=8080
HEALTH_CHECK_INTERVAL=30
```

### Environment Variables (Backward Compatible)

Legacy environment variables are still supported for backward compatibility:

```bash
# Database connection (legacy support)
PG_HOST=localhost
PG_USR=postgres
PG_PASS=your_password

# Processing settings (can override config file)
MAX_PARALLEL_JOBS=4
DEFAULT_PROJECTION=3857
LOG_LEVEL=INFO

# Advanced processing control
PARALLEL_INGESTION=true      # Enable full parallel data ingestion (setup)
DEBUG=false                 # Enable debug output and error details
VERBOSE=false              # Enable verbose progress logging
CLEAN_TEMP_FILES=false     # Preserve temp files for debugging
```

### Configuration Priority

Configuration values are resolved in this order (highest priority first):
1. **Environment variables** - Override everything else
2. **config/rbt.conf** - Centralized configuration file  
3. **Script defaults** - Built-in fallback values

This allows flexible deployment while maintaining consistency.

### Advanced Setup Options

The setup system supports several specialized processing modes:

```bash
# Parallel data ingestion for faster setup
PARALLEL_INGESTION=true ./setup/init-database.sh

# Debug mode with preserved temporary files
DEBUG=true VERBOSE=true CLEAN_TEMP_FILES=false ./setup/init-database.sh

# Individual data source processing
./setup/data-sources/osm/import-osm-data.sh
./setup/data-sources/reference-data/import-reference-data.sh
./setup/data-sources/reference-data/import-geonames.sh
./setup/data-sources/reference-data/import-buildings.sh

# Modular schema processing
./setup/data-sources/schemas/physical/process-physical-schemas.sh --landcover --water
./setup/data-sources/schemas/cultural/process-cultural-schemas.sh --transportation --infrastructure
```

## 📊 Performance

### System Requirements

**Minimum**:
- 16 cores, 32GB RAM, 6000GB SSD
- PostgreSQL 17+ with PostGIS 3.5+

**Recommended**:
- 64 cores, 512GB RAM, 4x 4TB NVMe SSD
- Dedicated PostgreSQL server with optimized configuration

### Processing Times

With recommended hardware and parallel processing enabled:

**Database Initialization** (one-time):
- **OSM Import**: 24-48 hours (multi-mirror download + diff processing + import)
- **Reference Data**: 2-4 hours (parallel import of all reference datasets)  
- **GeoNames Data**: 1-2 hours (parallel download and ingestion)
- **Buildings Data**: 4-6 hours (Overture Maps building data from S3)
- **Schema Processing**: 6-12 minutes (materialized views and indexes)
- **Total**: 36-72 hours (complete database initialization)

**Tile Generation**:
- **Full tile generation**: 6-12 hours (all layers, all projections)
- **Single projection**: 2-4 hours
- **Specific layers**: 30 minutes - 2 hours
- **OSM updates**: Real-time (continuous)

## 🆘 Troubleshooting

### Common Issues

1. **Database connection fails**:
   ```bash
   # Check configuration file
   cat config/rbt.conf | grep DATABASE_
   
   # Validate environment
   ./tools/validate-environment.sh
   ```

2. **Setup failures**:
   ```bash
   # Debug mode with detailed logging
   DEBUG=true VERBOSE=true ./setup/init-database.sh
   
   # Check individual components
   DEBUG=true ./setup/data-sources/reference-data/import-geonames.sh
   DEBUG=true ./setup/data-sources/reference-data/import-buildings.sh
   
   # Preserve temporary files for inspection
   CLEAN_TEMP_FILES=false DEBUG=true ./setup/data-sources/osm/import-osm-data.sh
   ```

3. **Tile generation issues**:
   ```bash
   # Check database views exist (uses config from rbt.conf)
   source config/rbt.conf
   psql "host=$DATABASE_HOST dbname=$DATABASE_NAME user=$DATABASE_USER password=$DATABASE_PASSWORD" -c "\dv rbt.*"
   
   # Or use legacy environment variables
   psql "host=$PG_HOST dbname=rbt user=$PG_USR password=$PG_PASS" -c "\dv rbt.*"
   
   # Debug specific layer generation
   ./production/generate-tiles.sh --layer-type cultural --building --verbose --dry-run
   
   # Test 4326 generation with diagnostic mode
   cd production/tile-generation/cultural
   DIAGNOSTIC=1 ./generate-cultural-4326.sh --transportation
   ```

4. **Insufficient resources**:
   - Check disk space and memory requirements
   - Adjust `MAX_PARALLEL_JOBS` in `config/rbt.conf` or via environment variable
   - Use `PARALLEL_INGESTION=false` for lower memory usage
   
5. **Configuration issues**:
   ```bash
   # Check if config file is being loaded properly
   source config/rbt.conf && echo "DATABASE_HOST: $DATABASE_HOST"
   
   # Verify all required variables are set
   grep -E "(DATABASE_|TILE_|OSM_)" config/rbt.conf
   
   # Test config with production scripts
   ./production/generate-tiles.sh --dry-run --verbose
   ```

### Advanced Debugging

```bash
# Schema processing debug mode
DEBUG=true ./setup/data-sources/schemas/physical/process-physical-schemas.sh --water
DEBUG=true ./setup/data-sources/schemas/cultural/process-cultural-schemas.sh --transportation

# Container health check monitoring
curl http://localhost:8080/health

# Performance monitoring during setup
VERBOSE=true PARALLEL_INGESTION=true ./setup/init-database.sh
```

## 📚 Documentation

### Core Documentation

- **[📖 Getting Started Guide](getting-started.md)** - Complete setup walkthrough with prerequisites, installation, and first steps
- **[🏗️ Architecture Overview](architecture.md)** - System design, data flow, and deployment architecture
- **[🔧 Setup Guide](setup-readme.md)** - Detailed setup documentation for database initialization
- **[🏭 Production Guide](production-readme.md)** - Continuous operations, OSM updates, and tile generation

### Layer Processing Documentation

- **[🌍 Physical Layers](physical-layers.md)** - Terrain, hydrology, land cover, and natural feature processing
- **[🏙️ Cultural Layers](cultural-layers.md)** - Transportation, buildings, boundaries, and infrastructure processing
- **[🗄️ Database Initialization](database-initialization.md)** - Database setup scripts and data source processing
- **[📥 OSM Import Pipeline](osm-import.md)** - Imposm3 OSM data processing and import workflow

### Specialized Processing

- **[🏢 DuckDB Buildings Export](duckdb-buildings.md)** - Alternative Overture building data processing using DuckDB
