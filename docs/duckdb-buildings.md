# DuckDB Overture Buildings Export

This document describes the standalone DuckDB workflow for exporting Overture
building data directly to FlatGeobuf format, without requiring PostgreSQL
ingestion. It is unrelated to `rbt import buildings` (the PostgreSQL-based
importer used by `rbt setup` — see [Database Initialization](database-initialization.md)),
though both are pinned to the same Overture release (`2026-06-17.0`, set in
`tools/duckdb-building-export.sql` and `import-buildings.sh`) — see the
[Data Sources & Licensing](data-sources.md#overture-maps-buildings) page for
why that pin must move in lockstep across both scripts. Pick one path per
pipeline; they are not meant to be combined.

## Overview

The workflow reads Overture building data directly from cloud-hosted
GeoParquet files (`s3://overturemaps-us-west-2/`) and exports it to
FlatGeobuf in three projections, plus three area-filtered, zoom-oriented
EPSG:4326 variants:

- **EPSG:3395** (World Mercator) → `building_3395.fgb`
- **EPSG:3857** (Web Mercator) → `building_3857.fgb`
- **EPSG:4326** (WGS84) → `building_4326.fgb`
- **EPSG:4326, Z10 filter** → `building_z10_4326.fgb` (area ≥ 5000 m²)
- **EPSG:4326, Z11 filter** → `building_z11_4326.fgb` (area ≥ 2500 m²)
- **EPSG:4326, Z12 filter** → `building_z12_4326.fgb` (area ≥ 1500 m²)

## Scripts

### `tools/overture_building_processing.sh` (recommended entry point)

A bash wrapper around the SQL script below that validates dependencies
(DuckDB on `PATH`), the output directory (existence, write permissions, disk
space), and network access to the Overture S3 bucket; then runs the DuckDB
script, verifies every expected output file was created and is non-empty,
and cleans up the temporary DuckDB database file afterward.

```bash
# Requires duckdb on PATH
./tools/overture_building_processing.sh --output-dir /data

# Or via environment variables
OUTPUT_DIR=/data DUCKDB_MEMORY_LIMIT=64GB ./tools/overture_building_processing.sh
```

**CLI flags** (see `--help` for the full list): `--output-dir`,
`--database-file`, `--temp-dir`, `--memory-limit`, `--temp-size`,
`--keep-temp-files`.

**Environment variables** (each has a matching flag above):

- `OUTPUT_DIR`: Directory for output files (default `/data`)
- `DUCKDB_DATABASE`: DuckDB database file path (default `<output-dir>/overture_buildings.db`)
- `DUCKDB_TEMP_DIRECTORY`: Temporary file directory (default `<output-dir>`)
- `DUCKDB_MEMORY_LIMIT`: Memory limit (default `200GB` — lower this on smaller machines, see below)
- `DUCKDB_MAX_TEMP_SIZE`: Max temp directory size (default `2900GB`)
- `CLEANUP_TEMP_FILES`: Remove the temporary DuckDB database after a successful run (default `true`)

### `tools/duckdb-building-export.sql` (driven by the script above)

Can also be run directly with the DuckDB CLI if you don't need the wrapper's
validation/cleanup steps:

```bash
OUTPUT_DIR=/path/to/output duckdb < tools/duckdb-building-export.sql
```

## Area Thresholds

The zoom-filtered EPSG:4326 exports use these area cutoffs (matching
`config/layers.yml`'s `building` filters):

| Zoom Level | Minimum Area | Use Case |
|------------|--------------|----------|
| Z10 | ≥ 5000 m² | Large buildings only |
| Z11 | ≥ 2500 m² | Medium and large buildings |
| Z12 | ≥ 1500 m² | Most buildings |

The unfiltered `building_3395.fgb`/`building_3857.fgb`/`building_4326.fgb`
exports contain every building regardless of area.

## Performance Considerations

1. **Network Speed**: Initial data download from S3 can take 10-30 minutes depending on your connection
2. **Memory Usage**: `DUCKDB_MEMORY_LIMIT` defaults to `200GB`, sized for a large dedicated machine — lower it (e.g. `16GB`–`64GB`) to match your available RAM; DuckDB spills to `DUCKDB_TEMP_DIRECTORY` when it exceeds the limit
3. **Processing Time**: Full global export can take 30-60 minutes or more, depending on the memory limit and disk speed
4. **Storage**: Each FlatGeobuf file can be 1-10 GB depending on filters; budget well below the wrapper's default `DUCKDB_MAX_TEMP_SIZE` (`2900GB`) ceiling based on your actual disk size

## Geographic Filtering

There is no built-in bounding-box flag. To export only a specific region,
edit `tools/duckdb-building-export.sql` directly and add a `WHERE
ST_Intersects(...)` (or a bounding-box comparison) clause to the
`rbt_building` table definition before the `COPY` statements.

## Requirements

- **DuckDB**: CLI (no minimum version pinned by the scripts; `v1.0.0`+ is known to work — see the install command below)
- **DuckDB Extensions**: `spatial`, `httpfs` (auto-installed by the SQL script via `INSTALL`/`LOAD`)
- **Memory**: sized to `DUCKDB_MEMORY_LIMIT` (default assumes 200GB+ available; lower it for smaller machines)
- **Storage**: several hundred GB free for the temp directory and output files on a full global run
- **Network**: stable internet connection for S3 access

## Installation

### Installing DuckDB

**macOS:**
```bash
brew install duckdb
```

**Linux:**
```bash
wget https://github.com/duckdb/duckdb/releases/download/v1.0.0/duckdb_cli-linux-amd64.zip
unzip duckdb_cli-linux-amd64.zip
sudo mv duckdb /usr/local/bin/
```

**Python:**
```bash
pip install duckdb
```

The Python package is only needed if you want to drive DuckDB from your own
scripts — there is no `rbt`-provided Python API for this workflow (see
below).

## Comparison with the PostgreSQL Approach (`rbt import buildings`)

| Aspect | DuckDB (`tools/`) | PostgreSQL (`rbt import buildings`) |
|--------|---------|------------|
| Setup | No database required | Requires PostGIS + `rbt setup --setup-database` |
| Speed | Direct from cloud to FlatGeobuf | Ingests into `overture.building`/`buildingpart` first |
| Output | Standalone `.fgb` files | Tables joined into `rbt.building*` by `cultural-core.sql` (currently commented out there — see [Database Schema](database-schema.md#buildings-land-use)) |
| Overture release pinned | `2026-06-17.0` (kept in sync with the importer) | `2026-06-17.0` |
| Dependencies | DuckDB only | PostgreSQL + PostGIS + GDAL/ogr2ogr |

## Output Files

The exported FlatGeobuf files carry these attributes (matching the `COPY`
statements in `tools/duckdb-building-export.sql`):

- `id`: Overture building ID
- `subtype`: Overture building subtype
- `class`: Building classification
- `has_parts`: Boolean flag for whether the building has associated `building_part` records
- `height`: Building height in meters
- `area`: Precomputed area in m² (projected to EPSG:3857 for the calculation, regardless of the output file's own projection)
- `geometry`: Geometry in the target projection

Note: the intermediate `rbt_building` table also computes a `name` column
(from Overture's `names.primary`), but the final `COPY` exports do not
include it — add `name` to the `SELECT` lists in the SQL script if you need
building names in the output.

## Troubleshooting

**Error: "duckdb command not found"**
- Install DuckDB using the instructions above

**Error: "Out of memory"**
- Lower `DUCKDB_MEMORY_LIMIT` (e.g. `--memory-limit 16GB`)
- Edit the SQL script to add a geographic filter and process smaller regions

**Slow download speeds**
- The initial download from S3 can be slow
- Consider running on an EC2 instance in us-west-2 for faster access

**Large output files**
- Use higher area thresholds by editing the `WHERE area >=` clauses in `tools/duckdb-building-export.sql`
- Add a geographic bounding-box filter (see above)

## 📚 Related Documentation

- **[← Back to Home](index.md)**
- **[Getting Started Guide](getting-started.md)** - Setup walkthrough and first steps
- **[Database Initialization](database-initialization.md)** - Complete database setup including Overture buildings via PostgreSQL
- **[Database Schema](database-schema.md)** - `rbt.building*` views and their (currently disabled) DDL
- **[Physical Layers](physical-layers.md)** - Natural feature processing
- **[Cultural Layers](cultural-layers.md)** - Human infrastructure processing (includes buildings)
- **[Setup Documentation](setup-readme.md)** - Complete setup information
