# DuckDB Overture Buildings Export

This document describes the DuckDB script for exporting Overture building data directly to FlatGeobuf format, without requiring PostgreSQL ingestion.

## Overview

The script reads Overture building data directly from cloud-hosted GeoParquet files and exports them to FlatGeobuf format in three different projections:

- **EPSG:3395** (World Mercator) → `building3395.fgb`
- **EPSG:3857** (Web Mercator) → `building3857.fgb`  
- **EPSG:4326** (WGS84) → `building4326.fgb`

## Script

### `tools/duckdb-building-export.sql`
SQL script for use directly with DuckDB CLI to process Overture building data.

```bash
# Run with DuckDB CLI
duckdb < tools/duckdb-building-export.sql

# With environment variables for configuration
OUTPUT_DIR=/path/to/output duckdb < tools/duckdb-building-export.sql
```

**Environment Variables:**
- `OUTPUT_DIR`: Directory for output files (defaults to `/data`)
- `DUCKDB_TEMP_DIRECTORY`: Temporary file directory
- `DUCKDB_MEMORY_LIMIT`: Memory limit (defaults to `200GB`)
- `DUCKDB_MAX_TEMP_SIZE`: Max temp directory size (defaults to `2900GB`)

## Area Thresholds

The scripts filter buildings based on area for different zoom levels:

| Zoom Level | Minimum Area | Use Case |
|------------|--------------|----------|
| Z10 | ≥ 5000 m² | Large buildings only |
| Z11 | ≥ 2500 m² | Medium and large buildings |
| Z12 | ≥ 1500 m² | Most buildings |

## Performance Considerations

1. **Network Speed**: Initial data download from S3 can take 10-30 minutes depending on your connection
2. **Memory Usage**: Scripts are configured to use up to 8GB RAM
3. **Processing Time**: Full global export can take 30-60 minutes
4. **Storage**: Each FlatGeobuf file can be 1-10 GB depending on filters

## Geographic Filtering

To export only a specific region, modify the bounding box filter:

```bash

# In Python script:
create_building_exports(bbox=(-125, 24, -66, 50))  # Continental US
```

## Requirements

- **DuckDB**: Version 0.10.0 or newer
- **DuckDB Extensions**: spatial, httpfs (auto-installed by scripts)
- **Memory**: 8GB+ RAM recommended
- **Storage**: 1000 GB free space for output files
- **Network**: Stable internet connection for S3 access

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

## Comparison with PostgreSQL Approach

| Aspect | DuckDB | PostgreSQL |
|--------|---------|------------|
| Setup | No database required | Requires database setup |
| Speed | Direct from cloud | Requires data ingestion |
| Memory | In-memory processing | Persistent storage |
| Flexibility | Query-time filtering | Pre-processed tables |
| Dependencies | DuckDB only | PostgreSQL + PostGIS |

## Output Files

The scripts generate FlatGeobuf files with the following attributes:

- `id`: Overture building ID
- `names`: Building names (JSON)
- `class`: Building classification
- `level`: Building level
- `has_parts`: Boolean flag for building parts
- `height`: Building height in meters
- `num_floors`: Number of floors
- `wkb_geometry`: Geometry in target projection

## Troubleshooting

**Error: "duckdb command not found"**
- Install DuckDB using the instructions above

**Error: "Out of memory"**
- Reduce memory limit in script
- Use geographic filtering to process smaller regions

**Slow download speeds**
- The initial download from S3 can be slow
- Consider running on an EC2 instance in us-west-2 for faster access

**Large output files**
- Use higher area thresholds (e.g., 5000 m² instead of 1500 m²)
- Apply geographic bounding box filters

## 📚 Related Documentation

- **[← Back to Home](index.md)**
- **[Getting Started Guide](getting-started.md)** - Setup walkthrough and first steps
- **[Database Initialization](database-initialization.md)** - Complete database setup including Overture buildings via PostgreSQL
- **[Physical Layers](physical-layers.md)** - Natural feature processing
- **[Cultural Layers](cultural-layers.md)** - Human infrastructure processing (includes buildings)
- **[Setup Documentation](setup-readme.md)** - Complete setup information