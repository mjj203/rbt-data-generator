# Production Operations

This directory contains scripts for continuous operations on an initialized RBT database. These scripts handle OSM updates and vector tile generation.

## ⚠️ Prerequisites

Before using these scripts, ensure:

- ✅ Database has been initialized using `./setup/init-database.sh`
- ✅ Environment variables are configured (see `config/rbt.conf`)
- ✅ Required tools are installed (tippecanoe, ogr2ogr, imposm)

## 🎯 Main Operations

### 1. OSM Updates (Continuous)

Keep OSM data current with daily updates:

```bash
# Start continuous updates (runs indefinitely) - DEFAULT COMMAND
./production/update-osm.sh
./production/update-osm.sh run

# Run in background
nohup ./production/update-osm.sh run > osm-updates.log 2>&1 &

# Check status
./production/update-osm.sh status

# Stop updates
./production/update-osm.sh stop

# Show help
./production/update-osm.sh --help
```

### 2. Tile Generation (On-Demand)

Generate vector tiles from the current database using the main orchestrator script:

```bash
# Generate all tiles in all projections (with tile joining and BTIS metadata - DEFAULT)
./production/generate-tiles.sh
./production/generate-tiles.sh --all

# Generate specific layer types
./production/generate-tiles.sh --layer-type physical
./production/generate-tiles.sh --layer-type cultural

# Generate specific projections
./production/generate-tiles.sh --projection 3857  # Web Mercator
./production/generate-tiles.sh --projection 3395  # World Mercator  
./production/generate-tiles.sh --projection 4326  # Geographic

# Combine layer type and projection
./production/generate-tiles.sh --layer-type physical --projection 3857

# Generate specific physical layers
./production/generate-tiles.sh --layer-type physical --water --landcover --contour

# Generate specific cultural layers
./production/generate-tiles.sh --layer-type cultural --transportation --building --boundary

# Disable tile joining and BTIS metadata (generate individual files only)
./production/generate-tiles.sh --all --no-tile-join --no-btis

# Custom processing options
./production/generate-tiles.sh --all --temp-dir /mnt/fast-storage --version 2.0.0

# Dry run to see what would be executed
./production/generate-tiles.sh --dry-run --verbose --all
```

### 3. Direct Layer-Specific Scripts (Advanced)

For advanced users who need fine-grained control, you can also run the individual tile generation scripts directly:

#### Physical Layer Scripts

##### Physical Mercator Projections (3857, 3395) - Uses Tippecanoe

```bash
# Generate all physical layers in EPSG:3857 (default)
./production/tile-generation/physical/generate-physical-3857-3395.sh

# Generate all physical layers in EPSG:3395
./production/tile-generation/physical/generate-physical-3857-3395.sh --projection 3395

# Generate specific physical layers
./production/tile-generation/physical/generate-physical-3857-3395.sh --water --landcover --contour

# Generate with tile joining and BTIS metadata
./production/tile-generation/physical/generate-physical-3857-3395.sh --all --tile-join --add-btis

# Custom temp directory
./production/tile-generation/physical/generate-physical-3857-3395.sh --all --temp-dir /mnt/fast-storage
```

##### Physical Geographic Projection (4326) - Uses GDAL MVT Driver

```bash
# Generate all physical layers in EPSG:4326 (default)
./production/tile-generation/physical/generate-physical-4326.sh

# Generate specific physical layers
./production/tile-generation/physical/generate-physical-4326.sh --water --landcover

# Debug mode to see generated JSON configuration
DEBUG=1 ./production/tile-generation/physical/generate-physical-4326.sh --water

# Diagnostic mode to test each table individually
DIAGNOSTIC=1 ./production/tile-generation/physical/generate-physical-4326.sh --all
```

#### Cultural Layer Scripts

##### Cultural Mercator Projections (3857, 3395) - Uses Tippecanoe

```bash
# Generate all cultural layers in EPSG:3857 (default)
./production/tile-generation/cultural/generate-cultural-3857-3395.sh

# Generate all cultural layers in EPSG:3395
./production/tile-generation/cultural/generate-cultural-3857-3395.sh --projection 3395

# Generate specific cultural layers
./production/tile-generation/cultural/generate-cultural-3857-3395.sh --transportation --building --boundary

# Generate with tile joining and BTIS metadata
./production/tile-generation/cultural/generate-cultural-3857-3395.sh --all --tile-join --add-btis

# Custom temp directory
./production/tile-generation/cultural/generate-cultural-3857-3395.sh --all --temp-dir /mnt/fast-storage
```

##### Cultural Geographic Projection (4326) - Uses GDAL MVT Driver

```bash
# Generate all cultural layers in EPSG:4326 (default)
./production/tile-generation/cultural/generate-cultural-4326.sh

# Generate specific cultural layers
./production/tile-generation/cultural/generate-cultural-4326.sh --transportation --building

# Debug mode to see generated JSON configuration
DEBUG=1 ./production/tile-generation/cultural/generate-cultural-4326.sh --transportation

# Diagnostic mode to test each table individually
DIAGNOSTIC=1 ./production/tile-generation/cultural/generate-cultural-4326.sh --all
```

## 📁 Directory Structure

```text
production/
├── generate-tiles.sh           # Main tile generation orchestrator
├── update-osm.sh              # OSM continuous updates
├── tile-generation/           # Layer-specific generation scripts
│   ├── physical/              # Physical layer tiles
│   │   ├── generate-physical-3857-3395.sh  # Unified Mercator projections (Tippecanoe)
│   │   └── generate-physical-4326.sh       # Geographic projection (GDAL MVT)
│   │
│   └── cultural/              # Cultural layer tiles
│       ├── generate-cultural-3857-3395.sh  # Unified Mercator projections (Tippecanoe)
│       └── generate-cultural-4326.sh       # Geographic projection (GDAL MVT)
│
└── README.md                  # This documentation file
```

## 🎛️ Command Reference

### Main Scripts

#### generate-tiles.sh (Main Orchestrator)

| Option | Description | Default | Example |
|--------|-------------|---------|---------|
| `--layer-type TYPE` | Layer type: physical, cultural, all | `all` | `--layer-type physical` |
| `--projection PROJ` | Projection: 3857, 3395, 4326, all | `all` | `--projection 3857` |
| `--temp-dir DIR` | Temp directory for tippecanoe processing | `/mnt/data` | `--temp-dir /tmp/tiles` |
| `--no-tile-join` | Disable merging layers into consolidated files | tile-join enabled | `--no-tile-join` |
| `--no-btis` | Disable BTIS metadata addition | BTIS enabled | `--no-btis` |
| `--version VERSION` | Set BTP schema version | `1.0.0` | `--version 2.0.0` |
| `--verbose, -v` | Enable verbose output | disabled | `--verbose` |
| `--dry-run, -d` | Show commands without executing | disabled | `--dry-run` |
| `--help, -h` | Show help message | - | `--help` |

#### update-osm.sh (OSM Updates)

| Command | Description | Example |
|---------|-------------|---------|
| `run` (default) | Start continuous updates | `./update-osm.sh run` |
| `status` | Show current update status | `./update-osm.sh status` |
| `stop` | Stop running updates | `./update-osm.sh stop` |
| `--help, -h` | Show help message | `./update-osm.sh --help` |

### Direct Layer Scripts

#### Physical Layer Scripts Options

##### generate-physical-3857-3395.sh (Tippecanoe)

| Option | Description | Default | Example |
|--------|-------------|---------|---------|
| `--projection CODE` | Projection: 3857, 3395 | `3857` | `--projection 3395` |
| `--temp-dir DIR` | Temp directory for tippecanoe | `/mnt/data` | `--temp-dir /tmp` |
| `--all` | Generate all physical layers | enabled if no layers specified | `--all` |
| `--tile-join` | Merge layers into consolidated file | disabled | `--tile-join` |
| `--add-btis` | Add BTIS metadata | disabled | `--add-btis` |
| `--version VERSION` | Set BTP schema version | `1.0.0` | `--version 2.0.0` |

Layer-specific options: `--builtuparea`, `--contour`, `--glacier`, `--landcover`, `--mountain`, `--park`, `--water`, `--water-label`, `--waterway`, `--inland-water`

##### generate-physical-4326.sh (GDAL MVT)

| Option | Description | Example |
|--------|-------------|---------|
| `--all` | Generate all physical layers (default) | `--all` |
| Layer options | `--builtuparea`, `--contour`, `--glacier`, `--landcover`, `--mountain`, `--park`, `--water` | `--water --landcover` |
| `DEBUG=1` | Show generated JSON configuration | `DEBUG=1 ./script.sh --water` |
| `DIAGNOSTIC=1` | Test each table individually | `DIAGNOSTIC=1 ./script.sh --all` |

#### Cultural Layer Scripts Options

##### generate-cultural-3857-3395.sh (Tippecanoe)

| Option | Description | Default | Example |
|--------|-------------|---------|---------|
| `--projection CODE` | Projection: 3857, 3395 | `3857` | `--projection 3395` |
| `--temp-dir DIR` | Temp directory for tippecanoe | `/mnt/data` | `--temp-dir /tmp` |
| `--all` | Generate all cultural layers | enabled if no layers specified | `--all` |
| `--tile-join` | Merge layers into consolidated file | disabled | `--tile-join` |
| `--add-btis` | Add BTIS metadata | disabled | `--add-btis` |
| `--version VERSION` | Set BTP schema version | `1.0.0` | `--version 2.0.0` |

Layer-specific options: `--aeroway`, `--boundary`, `--building`, `--cemetery`, `--geonames`, `--transportation`, `--utilities`, `--other`

##### generate-cultural-4326.sh (GDAL MVT)

| Option | Description | Example |
|--------|-------------|---------|
| `--all` | Generate all cultural layers (default) | `--all` |
| Layer options | `--aeroway`, `--boundary`, `--building`, `--cemetery`, `--geonames`, `--populated`, `--landuse`, `--military`, `--radar`, `--transportation`, `--utilities` | `--transportation --building` |
| `DEBUG=1` | Show generated JSON configuration | `DEBUG=1 ./script.sh --transportation` |
| `DIAGNOSTIC=1` | Test each table individually | `DIAGNOSTIC=1 ./script.sh --all` |

#### Layer Details

##### Physical Layers (Available in generate-tiles.sh --layer-type physical and direct scripts)

| Option | Description | Layers Included |
|--------|-------------|-----------------|
| `--builtuparea` | Generate built-up area layer | Urban areas from NE and OSM |
| `--contour` | Generate contour layers | Regular and glacier contour lines |
| `--glacier` | Generate glacier layer | Glacier polygons from NE and OSM |
| `--landcover` | Generate landcover layers | Land surface types and labels |
| `--mountain` | Generate mountain label layer | Mountain peak labels |
| `--park` | Generate park layer | Protected areas and parks |
| `--water` | Generate water layer | Water bodies |
| `--water-label` | Generate water label layer | Water feature labels |
| `--waterway` | Generate waterway layer | Rivers, streams, canals |
| `--inland-water` | Generate inland water intermittent layer | Seasonal water bodies |

##### Cultural Layers (Available in generate-tiles.sh --layer-type cultural and direct scripts)

| Option | Description | Layers Included |
|--------|-------------|-----------------|
| `--aeroway` | Generate aeroway layers | Airports, runways, heliports |
| `--boundary` | Generate boundary layers | Administrative boundaries (ADM0/1/2) |
| `--building` | Generate building layer | Building footprints |
| `--cemetery` | Generate cemetery layers | Cemetery polygons and labels |
| `--geonames` | Generate geonames layers | Hydrographic place names |
| `--transportation` | Generate transportation layers | Roads, railways, ports, ferries |
| `--utilities` | Generate utilities layers | Power, pipelines, dams, utilities |
| `--other` | Generate other cultural layers | Stadiums, military, radar |

### Script Execution Summary

| Script | Purpose | When to Use |
|--------|---------|-------------|
| `generate-tiles.sh` | **Main orchestrator** - handles all projections and layers | **Recommended** - Use for most tile generation needs |
| `update-osm.sh` | OSM continuous updates | Keep OSM data current - run as background service |
| `generate-*-3857-3395.sh` | Direct Tippecanoe generation for Mercator projections | Advanced users needing fine control over Mercator tiles |
| `generate-*-4326.sh` | Direct GDAL MVT generation for geographic projection | Advanced users needing fine control over 4326 tiles |

## 🕐 Scheduling

### Automated Tile Generation

Set up cron jobs for regular tile updates:

```bash
# Add to crontab
crontab -e

# Generate all tiles daily at 2 AM (consolidation and metadata enabled by default)
0 2 * * * cd /path/to/rbt-vector-tiles && ./production/generate-tiles.sh --all

# Generate physical tiles every 6 hours (water-related layers only)
0 */6 * * * cd /path/to/rbt-vector-tiles && ./production/generate-tiles.sh --layer-type physical --water --waterway --inland-water

# Generate cultural transportation tiles every 4 hours
0 */4 * * * cd /path/to/rbt-vector-tiles && ./production/generate-tiles.sh --layer-type cultural --transportation
```

### Systemd Services

Create systemd services for continuous operations:

```ini
# /etc/systemd/system/rbt-osm-updates.service
[Unit]
Description=RBT OSM Continuous Updates
After=postgresql.service

[Service]
Type=simple
User=rbt
WorkingDirectory=/opt/rbt-vector-tiles
ExecStart=/opt/rbt-vector-tiles/production/update-osm.sh run
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
```

## 📊 Monitoring

### Health Checks

```bash
# Check OSM update status
./production/update-osm.sh status

# Validate database connectivity (using config from rbt.conf)
psql "host=${DATABASE_HOST} port=${DATABASE_PORT} dbname=${DATABASE_NAME} user=${DATABASE_USER} password=${DATABASE_PASSWORD}" -c "SELECT COUNT(*) FROM import.highway;"

# Check tile generation capability
./production/generate-tiles.sh --dry-run --verbose

# Test specific projection generation
./production/generate-tiles.sh --dry-run --layer-type physical --projection 3857 --water
```

### Log Files

Production logs are stored in `../output/logs/`:

- `tile_generation_*.log` - Tile generation logs
- `osm_updates_*.log` - OSM update logs
- `performance_*.log` - Performance metrics

## 🔧 Configuration

### Processing Parameters

Adjust settings in `../config/processing.conf`:

```bash
# Parallel processing
MAX_PARALLEL_JOBS=4

# Tile generation
DEFAULT_PROJECTION=3857
TILE_CACHE_DIR=./output/tiles

# Resource limits
MEMORY_REQUIRED_GB=16
DISK_SPACE_REQUIRED_GB=100
```

### Projection Methods

The tile generation system uses different approaches for different projections:

**Mercator Projections (3857, 3395)**:

- Uses **tippecanoe** for tile generation
- Outputs **MBTiles** files (SQLite format)
- Optimized for web mapping and serving
- Supports tile joining and BTIS metadata
- Includes advanced filtering and optimization

**Geographic Projection (4326)**:

- Uses **GDAL MVT driver** for tile generation
- Outputs **directory structure** with PBF files
- Preserves lat/lon accuracy for analysis
- Includes embedded JSON configuration
- Supports diagnostic mode for troubleshooting

## 🚨 Troubleshooting

### Common Issues

#### 1. Tile generation fails

```bash
# Check database views exist (using config variables)
psql "host=${DATABASE_HOST} port=${DATABASE_PORT} dbname=${DATABASE_NAME} user=${DATABASE_USER} password=${DATABASE_PASSWORD}" -c "\dv rbt.*"

# Validate environment
../tools/validate-environment.sh

# Run with debug output
./production/generate-tiles.sh --verbose --dry-run

# Test specific layer generation
./production/generate-tiles.sh --layer-type physical --water --verbose --dry-run

# Check tippecanoe temp directory has sufficient space
df -h /mnt/data  # or your custom temp directory

# For 4326 tiles, run diagnostic mode
cd production/tile-generation/physical
DIAGNOSTIC=1 ./generate-physical-4326.sh --water

# For 3857/3395 tiles, check individual layers
./production/generate-tiles.sh --layer-type cultural --building --verbose --dry-run

# Test with custom temp directory
./production/generate-tiles.sh --all --temp-dir /tmp/tiles --dry-run --verbose
```

#### 2. OSM updates stop working

```bash
# Check imposm status
./production/update-osm.sh status

# Restart updates
./production/update-osm.sh stop
./production/update-osm.sh run
```

#### 3. Performance issues

```bash
# Check system resources
../tools/troubleshooting/analyze-performance.sh

# Reduce parallel jobs
export MAX_PARALLEL_JOBS=2
```

### Debug Mode

Enable detailed logging:

```bash
# Main orchestrator script with verbose output
./production/generate-tiles.sh --all --verbose --dry-run

# For 4326 direct scripts, use DEBUG environment variable
DEBUG=1 ./production/tile-generation/physical/generate-physical-4326.sh --water
DEBUG=1 ./production/tile-generation/cultural/generate-cultural-4326.sh --transportation

# For diagnostic testing of problematic tables
DIAGNOSTIC=1 ./production/tile-generation/physical/generate-physical-4326.sh --all
DIAGNOSTIC=1 ./production/tile-generation/cultural/generate-cultural-4326.sh --all
```

## 🔄 Update Workflows

### Regular Operations

**Daily**:

- OSM updates run automatically (if started as service)
- Monitor logs for any errors

**Weekly**:

- Regenerate tiles: `./production/generate-tiles.sh --all`
- Check system health: `../tools/validate-environment.sh`

**Monthly**:

- Analyze performance: `./production/monitoring/performance-metrics.sh`
- Review disk space usage
- Update documentation if needed

### Emergency Procedures

**OSM updates fail**:

1. Check network connectivity
2. Verify imposm configuration
3. Restart update process
4. Check database locks

**Tile generation fails**:

1. Validate database views exist
2. Check available disk space
3. Verify tool dependencies
4. Run individual projection scripts for debugging

## 📈 Performance Optimization

### Database Tuning

Optimize PostgreSQL for tile generation:

```sql
-- Increase work memory for complex queries
SET work_mem = '1GB';

-- Enable parallel processing
SET max_parallel_workers_per_gather = 8;

-- Optimize for read-heavy workloads
SET random_page_cost = 1.1;
```

### Processing Optimization

- **Parallel Jobs**: Adjust `MAX_PARALLEL_JOBS` based on CPU cores
- **Memory**: Increase database memory settings for large operations
- **Storage**: Use NVMe SSD for database and temporary files
- **Network**: High-bandwidth connection for OSM updates

## 🎯 Output

Generated tiles are stored in `../output/tiles/`:

```text
output/tiles/
├── physical/
│   ├── 3857/                    # Web Mercator physical tiles
│   │   ├── individual layers/   # Individual MBTiles files per layer
│   │   └── physical_3857.mbtiles # Consolidated MBTiles (if --tile-join used)
│   ├── 3395/                    # World Mercator physical tiles
│   │   ├── individual layers/
│   │   └── physical_3395.mbtiles
│   └── 4326/                    # Geographic physical tiles
│       ├── metadata.json        # Layer metadata and configuration
│       └── [z]/[x]/[y].pbf      # Directory-based tile structure
└── cultural/
    ├── 3857/                    # Web Mercator cultural tiles
    │   ├── individual layers/   # Individual MBTiles files per layer
    │   └── cultural_3857.mbtiles # Consolidated MBTiles (if --tile-join used)
    ├── 3395/                    # World Mercator cultural tiles
    │   ├── individual layers/
    │   └── cultural_3395.mbtiles
    └── 4326/                    # Geographic cultural tiles
        ├── metadata.json        # Layer metadata and configuration
        └── [z]/[x]/[y].pbf      # Directory-based tile structure
```

### Output Types

**MBTiles Files (3857, 3395)**:

- Individual layer files: e.g., `water_3857.mbtiles`, `highway_3857.mbtiles`
- Consolidated files: `physical_3857.mbtiles`, `cultural_3857.mbtiles` (with `--tile-join`)
- SQLite-based tile archives optimized for serving
- Include BTIS metadata when generated with `--add-btis`

**PBF Directories (4326)**:

- Directory-based tile structure: `z/x/y.pbf`
- Uses GDAL MVT driver for optimal 4326 projection handling
- Includes `metadata.json` with layer configuration and statistics

### BTIS Metadata

When using `--add-btis`, MBTiles files include:

- CRS information (EPSG code)
- Tile origin coordinates
- Tile dimension at zoom 0
- BTP schema version
- Cleaned tippecanoe metadata

## 🚀 Advanced Usage Examples

### Selective Layer Generation

Generate only specific layers for targeted use cases:

```bash
# Generate only transportation infrastructure
./production/generate-tiles.sh --layer-type cultural --transportation --utilities --projection 3857

# Generate water-related layers for hydrological mapping
./production/generate-tiles.sh --layer-type physical --water --waterway --inland-water --projection all

# Generate terrain layers for topographic mapping
./production/generate-tiles.sh --layer-type physical --contour --glacier --mountain --projection 3857 --add-btis
```

### Custom Processing Workflows

```bash
# High-performance generation with custom temp directory
./production/generate-tiles.sh --all --temp-dir /mnt/nvme/temp

# Development/testing workflow - single layer with verbose output
./production/generate-tiles.sh --layer-type cultural --building --projection 3857 --verbose --dry-run

# Production deployment - all layers with full metadata and custom version
./production/generate-tiles.sh --all --version "2.0.0"
```

### Projection-Specific Workflows

```bash
# Web mapping (3857) - optimized for online maps
./production/generate-tiles.sh --projection 3857 --all --temp-dir /mnt/data

# Geographic analysis (4326) - preserves lat/lon accuracy
./production/generate-tiles.sh --projection 4326 --all

# Area-preserving (3395) - better for area calculations
./production/generate-tiles.sh --projection 3395 --layer-type physical --landcover --water
```

### Diagnostic and Troubleshooting

```bash
# Debug mode for 4326 generation
cd production/tile-generation/cultural
DEBUG=1 ./generate-cultural-4326.sh --transportation

# Test individual tables in 4326 generation
cd production/tile-generation/physical
DIAGNOSTIC=1 ./generate-physical-4326.sh --water

# Performance testing with minimal data
./production/generate-tiles.sh --layer-type cultural --building --projection 3857 --verbose
```

## 📚 Related Documentation

- **[← Back to Home](index.md)**
- **[Getting Started Guide](getting-started.md)** - Complete setup walkthrough
- **[Architecture Overview](architecture.md)** - System design and data flow
- **[Physical Layers](physical-layers.md)** - Natural feature processing details
- **[Cultural Layers](cultural-layers.md)** - Human infrastructure processing details
- **[Setup Documentation](setup-readme.md)** - Database initialization and setup