# DuckDB Overture Buildings Export

This document describes the DuckDB workflow for exporting Overture building
data directly to FlatGeobuf format, without requiring PostgreSQL ingestion. It
is run by `rbt export buildings` and is unrelated to `rbt import buildings` (the
PostgreSQL-based importer used by `rbt setup` — see
[Database Initialization](database-initialization.md)). Both paths read the same
`OVERTURE_RELEASE` / `OVERTURE_S3_BUCKET` at run time (from `config/rbt.conf` or
`--release`), so they stay pinned to the same Overture release automatically —
there is no longer a manual pin to keep in sync. Pick one path per pipeline;
they are not meant to be combined.

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

## Running it

### `rbt export buildings` (recommended entry point)

The native command (a port of the retired `tools/overture_building_processing.sh`
wrapper) removes any prior outputs, runs the DuckDB script, verifies every
expected output file was created and is non-empty, and cleans up the temporary
DuckDB database file afterward (kept on failure for debugging).

```bash
# Requires duckdb on PATH
rbt export buildings

# To a specific directory, with a lower memory ceiling
DUCKDB_MEMORY_LIMIT=64GB rbt export buildings --output-dir /data
```

**CLI flags:** `--output-dir` (default `$OVERTURE_EXPORT_DIR`, i.e.
`./output/buildings`), `--release` (default the pinned `OVERTURE_RELEASE`),
`--keep-db` (retain the scratch DuckDB database after a successful run),
`--dry-run` (log the command without running it).

**Environment variables:**

- `OVERTURE_EXPORT_DIR`: Directory for output files (default `./output/buildings`)
- `OVERTURE_RELEASE` / `OVERTURE_S3_BUCKET`: Overture release + bucket to read
- `DUCKDB_MEMORY_LIMIT`: Memory limit (default `200GB` — lower this on smaller machines, see below)
- `DUCKDB_MAX_TEMP_SIZE`: Max temp directory size (default `2900GB`)
- `DUCKDB_TEMP_DIRECTORY`: Temporary file directory (default = the export dir)

The scratch DuckDB database is written to `<output-dir>/overture_buildings.db`.
Note the export **always regenerates** — unlike `rbt import buildings`, it has
no "skip if already present" short-circuit.

### `setup/data-sources/overture/duckdb-building-export.sql` (the underlying script)

Can also be run directly with the DuckDB CLI if you don't need the command's
validation/cleanup steps:

```bash
OUTPUT_DIR=/path/to/output duckdb -f setup/data-sources/overture/duckdb-building-export.sql
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
4. **Storage**: Each FlatGeobuf file can be 1-10 GB depending on filters; budget well below the default `DUCKDB_MAX_TEMP_SIZE` (`2900GB`) ceiling based on your actual disk size

## Geographic Filtering

There is no built-in bounding-box flag. To export only a specific region,
edit `setup/data-sources/overture/duckdb-building-export.sql` directly and add a `WHERE
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

The DuckDB Python package is only needed if you want to drive DuckDB from your
own scripts; `rbt export buildings` shells out to the `duckdb` CLI, so the CLI
is what needs to be on `PATH`.

## Comparison with the PostgreSQL Approach (`rbt import buildings`)

| Aspect | DuckDB (`rbt export buildings`) | PostgreSQL (`rbt import buildings`) |
|--------|---------|------------|
| Setup | No database required | Requires PostGIS + `rbt setup --setup-database` |
| Speed | Direct from cloud to FlatGeobuf | Ingests into `overture.building`/`buildingpart` first |
| Output | Standalone `.fgb` files | Tables joined into `rbt.building*` by `cultural-core.sql` (currently commented out there — see [Database Schema](database-schema.md#buildings-land-use)) |
| Overture release | `OVERTURE_RELEASE` (shared with the importer) | `OVERTURE_RELEASE` |
| Dependencies | DuckDB only | PostgreSQL + PostGIS + GDAL/ogr2ogr |

## Output Files

The exported FlatGeobuf files carry these attributes (matching the `COPY`
statements in `setup/data-sources/overture/duckdb-building-export.sql`):

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
- Lower `DUCKDB_MEMORY_LIMIT` (e.g. `DUCKDB_MEMORY_LIMIT=16GB rbt export buildings`)
- Edit the SQL script to add a geographic filter and process smaller regions

**Slow download speeds**
- The initial download from S3 can be slow
- Consider running on an EC2 instance in us-west-2 for faster access

**Large output files**
- Use higher area thresholds by editing the `WHERE area >=` clauses in `setup/data-sources/overture/duckdb-building-export.sql`
- Add a geographic bounding-box filter (see above)

## 📚 Related Documentation

- **[← Back to Home](index.md)**
- **[Getting Started Guide](getting-started.md)** - Setup walkthrough and first steps
- **[Database Initialization](database-initialization.md)** - Complete database setup including Overture buildings via PostgreSQL
- **[Database Schema](database-schema.md)** - `rbt.building*` views and their (currently disabled) DDL
- **[Physical Layers](physical-layers.md)** - Natural feature processing
- **[Cultural Layers](cultural-layers.md)** - Human infrastructure processing (includes buildings)
- **[Setup Documentation](setup-readme.md)** - Complete setup information
