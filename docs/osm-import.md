# Imposm3 OSM Data Processing Pipeline

## Overview

This directory contains the infrastructure for importing and maintaining OpenStreetMap (OSM) data into a PostGIS-enabled PostgreSQL database using Imposm3. The pipeline is designed for large-scale, production-ready OSM data processing with support for continuous updates.

## Table of Contents

1. [Architecture](#architecture)
2. [Tools and Technologies](#tools-and-technologies)
3. [Configuration Files](#configuration-files)
4. [Database Schema](#database-schema)
5. [Processing Workflow](#processing-workflow)
6. [Script Features](#script-features)
7. [Usage](#usage)
8. [Monitoring and Health Checks](#monitoring-and-health-checks)

## Architecture

The system follows a multi-stage pipeline architecture:

```text
OSM Planet File → Download → Diff Application → Import → PostGIS Database → Continuous Updates
```

## Tools and Technologies

### aria2c - High-Speed Download Manager

**Purpose**: Multi-threaded download of large OSM planet files (~70GB)

**Key Configuration**:

- `--split=9`: Splits each file into 9 segments for parallel downloading
- `--max-connection-per-server=16`: Maximum 16 connections per server
- `--max-concurrent-downloads=12`: Up to 12 concurrent file downloads
- `--file-allocation=falloc`: Pre-allocates disk space for better performance

The script uses multiple mirror servers for redundancy:

- ftp.spline.de
- ftp5.gwdg.de
- ftp.fau.de
- ftpmirror.your.org
- download.bbbike.org
- ftp.nluug.nl
- ftp.osuosl.org
- planet.openstreetmap.org

### osmium - OSM Data Manipulation Tool

**Purpose**: Merges multiple OSM change files (.osc.gz) into a single changeset

**Command Used**:

```bash
osmium merge-changes -o osm.osc.gz -s [0-9]*.osc.gz
```

- `-o`: Output file
- `-s`: Sort changesets by timestamp
- Processes diff files from sequence 713 to 730 by default

### osmosis - OSM Data Processor

**Purpose**: Applies accumulated changesets to the base planet file

**Command Used**:

```bash
osmosis --read-xml-change file="osm.osc.gz" \
        --read-pbf file="planet-latest-v2.osm.pbf" \
        --apply-change \
        --write-pbf file="planet.osm.pbf"
```

- Reads change file in OSC format
- Reads base planet file in PBF format
- Applies changes and outputs updated PBF

### imposm3 - OSM to PostGIS Importer

**Purpose**: Imports OSM data into PostgreSQL with custom schema optimized for rendering

**Key Features**:

- Parallel processing using multiple CPU cores
- Custom tag filtering and transformation
- Generalization support for multi-scale rendering
- Continuous replication support

**Commands Used**:

```bash
# Initial import
imposm import -config config.json -read planet.osm.pbf -write -diff -optimize

# Continuous updates
imposm run -config config.json
```

### PostGIS - Spatial Database Extension

**Purpose**: Provides spatial data types and functions in PostgreSQL

**Database Configuration**:

- Host: 10.232.234.30
- Database: rbt
- SRID: 4326 (WGS84 coordinate system)
- No table prefix (prefix=NONE)

## Configuration Files

### imposm-config.json

Located at: `setup/data-sources/osm/imposm-config.json`

```json
{
    "replication_url": "https://planet.openstreetmap.org/replication/day/",
    "replication_interval": "24h",
    "diff_state_before": "24h"
}
```

**Configuration Parameters**:

- `replication_url`: Source for daily OSM changesets
- `replication_interval`: Updates every 24 hours  
- `diff_state_before`: Buffer time before current state (24 hours)

Note: Additional configuration such as database connection, mapping file, and cache directories are provided via command-line arguments or environment variables in the `import-osm-data.sh` script rather than in this configuration file.

### imposm-mapping.yaml

Located at: `setup/data-sources/osm/imposm-mapping.yaml`

The mapping file defines a comprehensive schema for various geographic features:

#### Tag Processing Configuration

```yaml
tags:
  load_all: true  # Loads all OSM tags into hstore column
```

#### Area Detection

```yaml
areas:
  area_tags: [building, landuse, leisure, natural, aeroway, ...]
  linear_tags: [highway, railway, waterway]
```

## Database Schema

The mapping creates 30+ specialized tables, each optimized for specific geographic features:

### Transportation Infrastructure

#### **aeroway_polygon** & **aeroway_linestring**

- **Purpose**: Airport infrastructure (runways, taxiways, aprons)
- **Key Columns**:
  - `icao`, `iata`: Airport codes
  - `surface`: Surface material
  - `width`, `length`: Dimensions
  - `military`: Military designation
  - `ele`: Elevation

#### **highway**

- **Purpose**: Road network
- **Key Columns**:
  - `class`/`subclass`: Road classification (motorway, primary, secondary, etc.)
  - `ref`: Road reference number
  - `network`: Road network identifier
  - `is_tunnel`, `is_bridge`, `is_ford`: Infrastructure attributes
  - `surface`: Road surface type
  - `is_oneway`: Direction restriction
  - Lifecycle fields: `construction`, `proposed`, `abandoned`, `destroyed`, etc.

#### **railway**

- **Purpose**: Rail infrastructure
- **Key Columns**:
  - `class`/`subclass`: Rail type (rail, subway, tram, monorail)
  - `electrified`: Electrification status
  - `gauge`: Track gauge
  - `tracks`: Number of tracks
  - `usage`: Usage type (main, branch, industrial)
  - Lifecycle tracking similar to highways

#### **shipway_linestring**

- **Purpose**: Ferry routes
- **Mapping**: `route=ferry`

### Water Features

#### **waterway** & **waterway_relation**

- **Purpose**: Rivers, streams, canals
- **Key Columns**:
  - `waterway`: Type of waterway
  - `intermittent`: Seasonal water presence
  - `tunnel`, `bridge`: Infrastructure crossings

#### **water**

- **Purpose**: Water bodies (lakes, reservoirs, seas)
- **Geometry**: Polygon
- **Includes**: Natural water, reservoirs, basins, swimming pools

#### **water_label**

- **Purpose**: Labels for water features
- **Includes**: Oceans, seas, bays, straits, springs

### Natural Features

#### **mountain_peak**

- **Purpose**: Peaks, volcanoes, saddles, hills
- **Key Columns**:
  - `ele`: Elevation
  - `subclass`: Feature type

#### **mountain_label**

- **Purpose**: Linear mountain features
- **Includes**: Ridges, cliffs, valleys, dunes

#### **landcover**

- **Purpose**: Land cover classification
- **Key Columns**:
  - `class`/`subclass`: Cover type
  - `leaf_cycle`, `leaf_type`: Vegetation characteristics
  - `wetland`: Wetland type
  - `intermittent`, `seasonal`: Temporal characteristics
- **Mapped Tags**: landuse, natural, landcover, crop, wetland, geological

### Urban and Administrative

#### **builtup_area**

- **Purpose**: Urban and developed areas
- **Includes**: Residential, commercial, industrial, military areas
- **Also covers**: Educational, religious, cemetery, ports

#### **park_polygon**

- **Purpose**: Parks and protected areas
- **Key Columns**:
  - `protection_title`: Protection designation
  - `iucn_level`: IUCN protection category
  - `ownership`, `operator`: Management information

#### **poi** (Points of Interest)

- **Purpose**: General points of interest
- **Mapped Tags**: amenity, tourism, leisure, sport, shop, office, historic, building

### Administrative Boundaries

#### **continent_point**, **country_point**, **state_point**, **city_point**

- **Purpose**: Administrative hierarchy labels
- **Key Columns**:
  - `name`, `name_en`, `name_de`: Multilingual names
  - `rank`: Importance ranking
  - `population`: Population data (cities)
  - `capital`: Capital designation
  - ISO country codes for countries

#### **island_polygon** & **island_point**

- **Purpose**: Island features
- **Includes area calculation for polygons**

### Infrastructure

#### **utility_stations** & **utility_linestrings**

- **Purpose**: Power and utility infrastructure
- **Key Columns**:
  - Power plant attributes: `plant_source`, `plant_method`, `plant_output`
  - Generator details: `generator_source`, `generator_type`
  - Pipeline attributes: `substance`, `diameter`, `flow_direction`
  - Electrical: `voltage`, `cables`

#### **transportation_stations** & **transportation_label**

- **Purpose**: Transit stations and stops
- **Includes**: Bus stations, railway stations, ferry terminals
- **Key Columns**: `platforms`, `station`, `operator`

### Special Columns Across Tables

#### Common Fields

- `osm_id`: OpenStreetMap unique identifier
- `geometry`: PostGIS geometry column
- `tags`: hstore column containing all OSM tags
- `name`, `name_en`, `name_de`: Multilingual naming
- `area`: Calculated area for polygons

#### Geometry Types

- **point**: Point features
- **linestring**: Linear features
- **polygon**: Area features
- **geometry**: Mixed geometry types
- **relation_member**: OSM relation members

## Processing Workflow

### 1. **Initialization**

- Validates dependencies (aria2c, wget, osmium, osmosis, imposm)
- Sets up logging infrastructure
- Validates configuration files
- Checks disk space (requires ~70GB)

### 2. **Planet File Download**

- Downloads latest OSM planet file (~55GB compressed)
- Uses aria2c with multiple mirrors for redundancy
- Supports resume on failure
- Validates downloaded file size

### 3. **Diff File Processing**

- Downloads daily diff files (sequences 713-730 by default)
- Parallel download using wget (8 concurrent jobs)
- Merges all diffs using osmium merge-changes
- Creates single consolidated changeset

### 4. **Change Application**

- Applies merged changeset to planet file using osmosis
- Produces updated planet.osm.pbf
- Validates output file integrity

### 5. **Database Import**

- Imports data using imposm3
- Creates tables according to mapping.yaml
- Builds spatial indexes
- Optimizes database for queries

### 6. **Continuous Updates**

- Runs imposm in continuous mode
- Checks for updates every 24 hours
- Applies incremental changes
- Maintains database currency

## Script Features

### Error Handling

- Comprehensive error checking at each stage
- Retry logic with configurable attempts (default: 3)
- Graceful shutdown on signals (SIGINT, SIGTERM)
- Cleanup of temporary files on exit

### Performance Optimization

- Parallel downloads for faster data retrieval
- Batch processing of diff files
- File validation to avoid re-downloads
- Configurable resource limits

### Monitoring

- Detailed logging with timestamps
- Progress tracking for long operations
- Health check server on port 8080
- PID file for process management

### Configuration Options

```bash
# Environment variables
LOG_FILE           # Log file location
DATA_DIR           # Data storage directory
CONFIG_FILE        # Imposm config file
MAX_RETRIES        # Retry attempts (default: 3)
RETRY_DELAY        # Delay between retries (default: 10s)
CLEANUP_ON_EXIT    # Remove temp files (default: true)
VALIDATE_DOWNLOADS # Validate file integrity (default: true)
HEALTH_CHECK_PORT  # Health check port (default: 8080)
```

## Usage

### Basic Execution

```bash
./setup/data-sources/osm/import-osm-data.sh
```

### Custom Configuration

```bash
DATA_DIR=/custom/path CONFIG_FILE=custom.json ./setup/data-sources/osm/import-osm-data.sh
```

### Docker/Container Usage

```bash
docker run -v /data:/mnt/data \
           -e DATA_DIR=/mnt/data \
           -e CONFIG_FILE=/app/config.json \
           imposm-processor
```

## Monitoring and Health Checks

### Health Check Endpoint

The script starts a health check server on port 8080 (configurable) that responds with HTTP 200 OK. This is useful for:

- Container orchestration (Kubernetes, Docker Swarm)
- Load balancer health checks
- Monitoring systems

### Log Analysis

Monitor the log file for:

- Progress indicators: `[INFO] Progress: <task> [current/total] (percent%)`
- Errors: `[ERROR]` prefixed messages
- Warnings: `[WARN]` prefixed messages
- Timing: Duration reports for each major operation

### Database Validation

After import, verify data integrity:

```sql
-- Check table counts
SELECT table_name, 
       pg_size_pretty(pg_relation_size(table_name::regclass)) as size,
       n_live_tup as row_count
FROM pg_stat_user_tables 
WHERE schemaname = 'public'
ORDER BY pg_relation_size(table_name::regclass) DESC;

-- Verify spatial indexes
SELECT tablename, indexname 
FROM pg_indexes 
WHERE schemaname = 'public' 
  AND indexdef LIKE '%gist%';
```

## Troubleshooting

### Common Issues

1. **Insufficient Disk Space**

   - Ensure at least 70GB free space
   - Check both DATA_DIR and temporary directories

2. **Connection Failures**

   - Verify PostgreSQL connectivity
   - Check PostGIS extension is installed
   - Ensure database credentials are correct

3. **Memory Issues**

   - Imposm3 requires significant RAM for large imports
   - Consider adjusting PostgreSQL work_mem and shared_buffers

4. **Slow Performance**

   - Increase parallel download settings
   - Ensure fast disk I/O (SSD recommended)
   - Optimize PostgreSQL configuration for bulk inserts

## References

- [Imposm3 Documentation](https://imposm.org/docs/imposm3/latest/)
- [OSM Data Processing](https://wiki.openstreetmap.org/wiki/OSM_file_formats)
- [PostGIS Documentation](https://postgis.net/documentation/)
- [Osmium Tool Manual](https://osmcode.org/osmium-tool/manual.html)
- [Osmosis Documentation](https://wiki.openstreetmap.org/wiki/Osmosis)
- [aria2 Documentation](https://aria2.github.io/manual/en/html/)

## 📚 Related Documentation

- **[← Back to Home](index.md)**
- **[Getting Started Guide](getting-started.md)** - Setup walkthrough and first steps
- **[Architecture Overview](architecture.md)** - System design and data flow
- **[Database Initialization](database-initialization.md)** - Complete database setup
- **[Physical Layers](physical-layers.md)** - Natural feature processing
- **[Cultural Layers](cultural-layers.md)** - Human infrastructure processing
- **[Setup Documentation](setup-readme.md)** - Complete setup information
