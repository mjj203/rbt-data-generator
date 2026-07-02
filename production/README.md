# Production Operations

Continuous operations on an initialized RBT database: keeping OSM data current with `rbt osm run` and generating vector tiles with `rbt tiles`. Both are native `rbt` CLI commands — the Bash scripts that remain in this directory are a **deprecated escape hatch** (see [Deprecated Bash Generators](#deprecated-bash-generators)).

## ⚠️ Prerequisites

Before running production operations, ensure:

- ✅ Database has been initialized with `rbt setup --all` (see [setup documentation](setup-readme.md))
- ✅ Configuration is in place (see `config/rbt.conf`) — verify with `rbt validate`
- ✅ Required tools are installed (tippecanoe, tile-join, ogr2ogr, imposm)

## 🎯 Main Operations

### 1. OSM Updates (Continuous)

Keep OSM data current with daily updates. The CLI natively supervises `imposm run` (no bash involved), forwarding SIGTERM/SIGINT with a 30-second grace period and tracking the child via a pidfile in `$SHARED_TEMP_DIR`.

=== "rbt CLI"

    ```bash
    # Start continuous updates (blocks until stopped)
    rbt osm run

    # Check status (running? last applied OSM change?)
    rbt osm status

    # Stop updates gracefully
    rbt osm stop

    # Preview the imposm command without starting
    rbt osm run --dry-run
    ```

=== "Docker Compose"

    ```bash
    # The production profile runs `rbt osm run` as the
    # rbt-osm-updates container's main process
    docker compose --profile production up -d rbt-osm-updates

    docker compose exec rbt-osm-updates rbt osm status
    docker compose stop rbt-osm-updates
    ```

### 2. Tile Generation (On-Demand)

Generate vector tiles from the current database with the native engine:

```bash
# Generate all layers in all projections (tile joining and BTIS metadata on by default)
rbt tiles --all

# Generate specific layer types
rbt tiles --layer-type physical
rbt tiles --layer-type cultural

# Generate specific projections
rbt tiles --projection 3857  # Web Mercator (tippecanoe → MBTiles)
rbt tiles --projection 3395  # World Mercator (tippecanoe → MBTiles)
rbt tiles --projection 4326  # Geographic (GDAL MVT → tile directory)

# Combine layer type and projection
rbt tiles --layer-type physical --projection 3857

# Generate specific physical categories
rbt tiles --layer-type physical --water --landcover --contour

# Generate specific cultural categories
rbt tiles --layer-type cultural --transportation --building --boundary

# Generate one specific layer by registry key (see `rbt layers list`)
rbt tiles --layer water --projection 3857
rbt tiles layer water --projection 3857          # single layer/projection shortcut

# Disable tile joining and BTIS metadata (individual files only)
rbt tiles --all --no-tile-join --no-btis

# Re-export cached FlatGeoBuf files after a database refresh
rbt tiles --all --force

# Dry run to see what would be executed
rbt --verbose tiles --all --dry-run
```

Layer definitions (source views, zoom ranges, tippecanoe options, filters) live in `config/layers.yml`. Inspect them with:

```bash
rbt layers list
rbt layers show water
```

### Per-Projection Backends

The engine (`src/rbt/tiles/engine.py`) dispatches a different backend per projection:

**Mercator projections (3857, 3395) — tippecanoe**:

1. Each layer's source view is exported to FlatGeoBuf via `ogr2ogr` (cached — re-runs reuse the `.fgb` unless `--force` is passed).
2. `tippecanoe` builds one MBTiles per layer with the zoom range, type coercions, and feature filters from the registry.
3. `tile-join` merges the per-layer files into `physical_<proj>.mbtiles` / `cultural_<proj>.mbtiles` (`--tile-join`, default on).
4. BTIS metadata is applied to the result (`--add-btis`, default on).

**Geographic projection (4326) — GDAL MVT driver**:

- tippecanoe is **not** involved. One multi-table `ogr2ogr -f MVT` call cuts the whole dataset directly from PostGIS, using a CONF json of per-table zoom windows (the `gdal_mvt:` block in `config/layers.yml`).
- Output is a **tile directory** (`{z}/{x}/{y}.pbf` plus `metadata.json`), not MBTiles. `--tile-join`/`--add-btis` do not apply.
- Each run deletes and rewrites the tile directory to avoid mixing stale tiles.

### Deprecated Bash Generators

The scripts in this directory predate the Python engine and are kept **only** until the real-data parity check in [docs/parity-runbook.md](parity-runbook.md) confirms the native output, after which they will be removed. They are reachable solely through the CLI escape hatch:

```bash
rbt tiles --mode bash --layer-type physical --projection 3857 --water
```

Do not add new layers to the bash scripts — extend `config/layers.yml` instead.

## 📁 Directory Structure

```text
production/
├── README.md                  # This documentation file
├── generate-tiles.sh          # DEPRECATED bash orchestrator (`rbt tiles --mode bash`)
└── tile-generation/           # DEPRECATED layer-specific generators
    ├── physical/
    │   ├── generate-physical-3857-3395.sh  # Mercator projections (tippecanoe)
    │   └── generate-physical-4326.sh       # Geographic projection (GDAL MVT)
    │
    └── cultural/
        ├── generate-cultural-3857-3395.sh  # Mercator projections (tippecanoe)
        └── generate-cultural-4326.sh       # Geographic projection (GDAL MVT)
```

OSM continuous updates have no bash script anymore — `rbt osm run|status|stop` replaced `update-osm.sh`.

## 🎛️ Command Reference

### rbt tiles

| Option | Description | Default |
|--------|-------------|---------|
| `--layer-type TYPE` | Layer type: `physical`, `cultural`, `all` | `all` |
| `--projection PROJ` | Projection: `3857`, `3395`, `4326`, `all` | `all` |
| `--all` | Every layer in every projection | — |
| `--layer KEY` | Specific layer by registry key (repeatable) | — |
| `--tile-join / --no-tile-join` | Merge per-layer MBTiles into a consolidated file | enabled |
| `--add-btis / --no-btis` | Apply BTIS metadata | enabled |
| `--force` | Re-export cached FlatGeoBuf files (use after a database refresh) | disabled |
| `--mode native\|bash` | `bash` delegates to the deprecated generators | `native` |
| `--dry-run, -d` | Show commands without executing | disabled |
| Category flags | `--water`, `--building`, `--transportation`, … (see below) | — |

Global options go **before** the subcommand: `rbt --verbose tiles ...`, `rbt --debug tiles ...`, `rbt --log-file PATH tiles ...`.

### rbt tiles layer

```bash
rbt tiles layer KEY [--projection 3857|3395|4326] [--force] [--dry-run]
```

Generates a single layer in a single projection (default `3857`).

### rbt osm

| Command | Description |
|---------|-------------|
| `rbt osm run` | Start continuous updates (supervises `imposm run`; blocks) |
| `rbt osm status` | Show supervisor status + last applied OSM change (exit 1 if not running) |
| `rbt osm stop` | Stop the running supervisor (SIGTERM → SIGKILL after 30s) |
| `rbt osm import` | One-time OSM import (same as `rbt import osm`) |

### Category Flags

#### Physical (with `--layer-type physical`)

| Option | Description | Layers Included |
|--------|-------------|-----------------|
| `--builtuparea` | Built-up area layers | Urban areas from NE and OSM |
| `--contour` | Contour layers | Regular and glacier contour lines |
| `--glacier` | Glacier layer | Glacier polygons from NE and OSM |
| `--landcover` | Landcover layers | Land surface types and labels |
| `--mountain` | Mountain label layer | Mountain peak labels |
| `--park` | Park layer | Protected areas and parks |
| `--water` | Water layer | Water bodies |
| `--water-label` | Water label layer | Water feature labels |
| `--waterway` | Waterway layer | Rivers, streams, canals |
| `--inland-water` | Inland water intermittent layer | Seasonal water bodies |

#### Cultural (with `--layer-type cultural`)

| Option | Description | Layers Included |
|--------|-------------|-----------------|
| `--aeroway` | Aeroway layers | Airports, runways, heliports |
| `--boundary` | Boundary layers | Administrative boundaries (ADM0/1/2) |
| `--building` | Building layer | Building footprints |
| `--cemetery` | Cemetery layers | Cemetery polygons and labels |
| `--geonames` | Geonames layers | Hydrographic place names |
| `--transportation` | Transportation layers | Roads, railways, ports, ferries |
| `--utilities` | Utilities layers | Power, pipelines, dams, utilities |
| `--other` | Other cultural layers | Stadiums, military, radar |

The same flags select the corresponding table groups in the 4326 GDAL-MVT datasets, so one invocation works across every projection.

## 🕐 Scheduling

### Automated Tile Generation

Set up cron jobs for regular tile updates:

```bash
# Add to crontab
crontab -e

# Generate all tiles daily at 2 AM (consolidation and metadata enabled by default)
0 2 * * * cd /path/to/rbt-vector-tiles && rbt tiles --all --force

# Generate physical tiles every 6 hours (water-related layers only)
0 */6 * * * cd /path/to/rbt-vector-tiles && rbt tiles --layer-type physical --water --waterway --inland-water --force

# Generate cultural transportation tiles every 4 hours
0 */4 * * * cd /path/to/rbt-vector-tiles && rbt tiles --layer-type cultural --transportation --force
```

!!! note "`--force` in scheduled runs"
    Scheduled regeneration almost always follows fresh data (OSM updates,
    schema refreshes), so pass `--force` to invalidate the FlatGeoBuf export
    cache — otherwise the Mercator backends will reuse stale exports.

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
ExecStart=/usr/local/bin/rbt osm run
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
```

## 📊 Monitoring

### Health Checks

```bash
# Check OSM update status (exit 1 when not running — cron/monitoring friendly)
rbt osm status

# Fast database liveness probe (the Docker HEALTHCHECK command)
rbt health

# Full environment validation
rbt validate

# Check tile generation capability without writing anything
rbt --verbose tiles --all --dry-run

# Test a specific projection/category selection
rbt tiles --dry-run --layer-type physical --projection 3857 --water
```

### Log Files

Logs land in `$SHARED_LOG_DIR` (default `./output/logs`):

- `rbt_<timestamp>.log` — per-invocation CLI log (`--log-file` to override)
- Per-layer tile logs next to the tiles: `output/tiles/<type>/<proj>/<layer>_<proj>.log`, plus `merge_<proj>.log` (tile-join) and `<type>_4326_mvt.log` (4326 backend)

## 🔧 Configuration

### Processing Parameters

Adjust settings in `config/rbt.conf` (environment variables override; see [configuration.md](configuration.md)):

```bash
# Parallel processing
MAX_PARALLEL_JOBS=4

# Tile generation
DEFAULT_PROJECTION=3857
TILE_CACHE_DIR=./output/tiles   # where tiles are written
TILE_TEMP_DIR=/tmp/tiles        # tippecanoe scratch space — keep on fast storage
TILE_MIN_ZOOM=0
TILE_MAX_ZOOM=13

# Resource limits
MEMORY_REQUIRED_GB=16
DISK_SPACE_REQUIRED_GB=100
```

### Projection Methods

**Mercator Projections (3857, 3395)**:

- Uses **tippecanoe** for tile generation (via a cached FlatGeoBuf export)
- Outputs **MBTiles** files (SQLite format)
- Optimized for web mapping and serving
- Supports tile joining and BTIS metadata
- Includes advanced filtering and optimization (from `config/layers.yml`)

**Geographic Projection (4326)**:

- Uses the **GDAL MVT driver** — a single multi-table ogr2ogr call per dataset
- Outputs a **directory structure** with PBF files plus `metadata.json`
- Preserves lat/lon accuracy for analysis
- Zoom-variant views (e.g. pre-simplified `_z8`/`_z10` tables) blend into one target layer via per-table zoom windows

## 🚨 Troubleshooting

### Common Issues

#### 1. Tile generation fails

```bash
# Check database views exist (using config variables)
psql "host=${DATABASE_HOST} port=${DATABASE_PORT} dbname=${DATABASE_NAME} user=${DATABASE_USER} password=${DATABASE_PASSWORD}" -c "\dv rbt.*"

# Validate environment
rbt validate

# Run with debug output
rbt --verbose tiles --all --dry-run

# Test specific layer generation
rbt --verbose tiles --layer-type physical --water --dry-run

# Check the tippecanoe temp directory has sufficient space
df -h /tmp/tiles  # or your configured TILE_TEMP_DIR

# Tiles look stale after a database refresh? Invalidate the export cache
rbt tiles --layer-type physical --water --force

# For 4326 issues, check the backend log
tail -n 50 output/tiles/physical/4326/physical_4326_mvt.log
```

#### 2. OSM updates stop working

```bash
# Check imposm supervisor status
rbt osm status

# Restart updates
rbt osm stop
rbt osm run
```

#### 3. Performance issues

```bash
# Reduce parallel jobs for a run
MAX_PARALLEL_JOBS=2 rbt tiles --all

# Move tippecanoe scratch space to faster storage
TILE_TEMP_DIR=/mnt/nvme/tiles rbt tiles --all
```

See [troubleshooting.md](troubleshooting.md) for the full guide.

## 🔄 Update Workflows

### Regular Operations

**Daily**:

- OSM updates run automatically (if started as a service)
- Monitor logs for any errors

**Weekly**:

- Regenerate tiles: `rbt tiles --all --force`
- Check system health: `rbt validate`

**Monthly**:

- Review disk space usage
- Update documentation if needed

### Emergency Procedures

**OSM updates fail**:

1. Check network connectivity
2. Verify imposm configuration (`OSM_CONFIG_FILE`)
3. Restart: `rbt osm stop && rbt osm run`
4. Check database locks

**Tile generation fails**:

1. Validate database views exist (`rbt schema run --all` recreates them)
2. Check available disk space
3. Verify tool dependencies (`rbt validate`)
4. Generate a single layer to isolate the problem: `rbt tiles layer water --projection 3857`

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
- **Storage**: Use NVMe SSD for the database, `TILE_TEMP_DIR`, and `TILE_CACHE_DIR`
- **Network**: High-bandwidth connection for OSM updates

## 🎯 Output

Generated tiles are written to `$TILE_CACHE_DIR` (default `./output/tiles`):

```text
output/tiles/
├── physical/
│   ├── 3857/                        # Web Mercator physical tiles
│   │   ├── water_3857.mbtiles       # One MBTiles per layer (+ .fgb export + .log)
│   │   ├── ...
│   │   └── physical_3857.mbtiles    # Consolidated MBTiles (tile-join, default on)
│   ├── 3395/                        # World Mercator physical tiles
│   │   └── ... (same layout)
│   └── 4326/                        # Geographic physical tiles
│       └── physical_tiles/
│           ├── metadata.json        # Layer metadata and configuration
│           └── [z]/[x]/[y].pbf      # Directory-based tile structure
└── cultural/
    ├── 3857/
    │   ├── building_3857.mbtiles
    │   ├── ...
    │   └── cultural_3857.mbtiles
    ├── 3395/
    │   └── ... (same layout)
    └── 4326/
        └── cultural_tiles/
            ├── metadata.json
            └── [z]/[x]/[y].pbf
```

### Output Types

**MBTiles Files (3857, 3395)**:

- Individual layer files: e.g., `water_3857.mbtiles`, `highway_3857.mbtiles`
- Consolidated files: `physical_3857.mbtiles`, `cultural_3857.mbtiles` (with `--tile-join`, default)
- SQLite-based tile archives optimized for serving
- Include BTIS metadata when generated with `--add-btis` (default)

**PBF Directories (4326)**:

- Directory-based tile structure: `<dataset>_tiles/z/x/y.pbf`
- Uses the GDAL MVT driver for optimal 4326 projection handling
- Includes `metadata.json` with layer configuration and statistics
- Regenerated from scratch on every run (stale trees are removed first)

### BTIS Metadata

When `--add-btis` is active (default), MBTiles files include:

- CRS information (EPSG code)
- Tile origin coordinates
- Tile dimension at zoom 0
- BTP schema version (`meta.btp_schema_version` in `config/layers.yml`)
- Cleaned tippecanoe metadata

## 🚀 Advanced Usage Examples

### Selective Layer Generation

Generate only specific layers for targeted use cases:

```bash
# Generate only transportation infrastructure
rbt tiles --layer-type cultural --transportation --utilities --projection 3857

# Generate water-related layers for hydrological mapping
rbt tiles --layer-type physical --water --waterway --inland-water --projection all

# Generate terrain layers for topographic mapping
rbt tiles --layer-type physical --contour --glacier --mountain --projection 3857
```

### Custom Processing Workflows

```bash
# High-performance generation with custom scratch space
TILE_TEMP_DIR=/mnt/nvme/temp rbt tiles --all

# Development/testing workflow — single layer with verbose output
rbt --verbose tiles --layer-type cultural --building --projection 3857 --dry-run

# Separate output directory (e.g. for A/B comparison)
TILE_CACHE_DIR=./output/tiles-candidate rbt tiles --all
```

### Projection-Specific Workflows

```bash
# Web mapping (3857) — optimized for online maps
rbt tiles --projection 3857

# Geographic analysis (4326) — preserves lat/lon accuracy
rbt tiles --projection 4326

# Area-preserving (3395) — better for area calculations
rbt tiles --projection 3395 --layer-type physical --landcover --water
```

### Diagnostic and Troubleshooting

```bash
# Inspect what a layer will generate (zooms, filters, tippecanoe flags)
rbt layers show water

# Single layer, single projection, no side effects
rbt tiles layer water --projection 4326 --dry-run

# Compare against the deprecated bash path (see the parity runbook)
TILE_CACHE_DIR=./output/tiles-bash rbt tiles --mode bash --layer-type physical --projection 3857 --water
```

## 📚 Related Documentation

- **[← Back to Home](index.md)**
- **[Getting Started Guide](getting-started.md)** - Complete setup walkthrough
- **[Architecture Overview](architecture.md)** - System design and data flow
- **[Parity Runbook](parity-runbook.md)** - Retiring the deprecated bash generators
- **[Physical Layers](physical-layers.md)** - Natural feature processing details
- **[Cultural Layers](cultural-layers.md)** - Human infrastructure processing details
- **[Setup Documentation](setup-readme.md)** - Database initialization and setup
