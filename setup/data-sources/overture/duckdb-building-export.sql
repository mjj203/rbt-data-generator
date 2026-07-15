-- DuckDB script to process Overture building data and export to FlatGeobuf
-- This script reads directly from Overture GeoParquet files and creates 
-- building tables with area-based filtering for multiple zoom levels

-- Load required extensions
INSTALL spatial;
INSTALL httpfs;

LOAD spatial;
LOAD httpfs;

-- Set DuckDB configuration from environment variables with fallback defaults.
-- DuckDB's getenv() returns '' (not NULL) for an unset variable, so wrap every
-- lookup in nullif(..., '') — otherwise coalesce sees the empty string, the
-- default never fires, and e.g. `SET memory_limit = ''` errors. `rbt export
-- buildings` always sets all of these; the fallbacks are for a bare
-- `duckdb -f` run with only OUTPUT_DIR set.
SET max_temp_directory_size = coalesce(nullif(getenv('DUCKDB_MAX_TEMP_SIZE'), ''), '2900GB');
SET preserve_insertion_order = false;
SET temp_directory = coalesce(nullif(getenv('DUCKDB_TEMP_DIRECTORY'), ''), nullif(getenv('OUTPUT_DIR'), ''), '/data');
SET memory_limit = coalesce(nullif(getenv('DUCKDB_MEMORY_LIMIT'), ''), '200GB');
-- Region is tied to the public Overture bucket below; if you point
-- OVERTURE_S3_BUCKET at a bucket in another region, change this to match.
SET s3_region='us-west-2';

-- Set output directory from environment variable (defaults to /data if not set)
SET VARIABLE output_dir = coalesce(nullif(getenv('OUTPUT_DIR'), ''), '/data');
-- Bucket and release come from the environment (set by `rbt export buildings`
-- from OVERTURE_S3_BUCKET / OVERTURE_RELEASE) so the DuckDB path stays in
-- lockstep with the PostGIS importer. rtrim drops any trailing slash on the
-- bucket so the concatenated path never doubles it.
SET VARIABLE s3_bucket = rtrim(coalesce(nullif(getenv('OVERTURE_S3_BUCKET'), ''), 's3://overturemaps-us-west-2'), '/');
SET VARIABLE overture_release = coalesce(nullif(getenv('OVERTURE_RELEASE'), ''), '2026-06-17.0');
-- Create the main building table by joining building and building_part data
-- Note: We perform a LEFT JOIN to include all buildings, even those without parts
CREATE OR REPLACE TABLE rbt_building AS
SELECT 
    b.id,
    b.names.primary AS name,
    b.subtype,
    b.class,
    b.has_parts,
    b.height,
    ST_Area(ST_Transform(b.geometry, 'EPSG:4326', 'EPSG:3857')) AS area,
    b.geometry
FROM read_parquet(getvariable('s3_bucket') || '/release/' || getvariable('overture_release') || '/theme=buildings/type=building/*', filename=true, hive_partitioning=1) b
LEFT JOIN (
    SELECT DISTINCT building_id
    FROM read_parquet(getvariable('s3_bucket') || '/release/' || getvariable('overture_release') || '/theme=buildings/type=building_part/*', filename=true, hive_partitioning=1)
) bp ON b.id = bp.building_id;

CREATE OR REPLACE TABLE rbt_building_label AS
SELECT 
    id,
    name,
    subtype,
    class,
    has_parts,
    height,
    area,
    ST_PointOnSurface(geometry)::geometry(Point,4326) as geometry
FROM rbt_building;
-- Create area-filtered views for different zoom levels
-- Note: ST_Area on unprojected geometries returns area in square degrees
-- We'll use ST_Transform to project to Web Mercator (EPSG:3857) for accurate area calculations

-- Z10: Buildings >= 5000 square meters
CREATE OR REPLACE VIEW rbt_building_z10 AS
SELECT * FROM rbt_building
WHERE area >= 5000;

-- Z11: Buildings >= 2500 square meters
CREATE OR REPLACE VIEW rbt_building_z11 AS
SELECT * FROM rbt_building
WHERE area >= 2500;

-- Z12: Buildings >= 1500 square meters
CREATE OR REPLACE VIEW rbt_building_z12 AS
SELECT * FROM rbt_building
WHERE area >= 1500;

-- Export to FlatGeobuf format in different projections
-- EPSG:3395 - World Mercator

-- 3395
COPY (
    SELECT 
        id,
        subtype,
        class,
        has_parts,
        height,
        area,
        ST_Transform(geometry, 'EPSG:4326', 'EPSG:3395') as geometry
    FROM rbt_building
) TO (getvariable('output_dir') || '/building_3395.fgb')
WITH (FORMAT GDAL, DRIVER 'FlatGeobuf', SRS 'EPSG:3395');

-- Export to FlatGeobuf format in EPSG:3857 - Web Mercator

-- 3857
COPY (
    SELECT 
        id,
        subtype,
        class,
        has_parts,
        height,
        area,
        ST_Transform(geometry, 'EPSG:4326', 'EPSG:3857') as geometry
    FROM rbt_building
) TO (getvariable('output_dir') || '/building_3857.fgb')
WITH (FORMAT GDAL, DRIVER 'FlatGeobuf', SRS 'EPSG:3857');

-- Export to FlatGeobuf format in EPSG:4326 - WGS84

-- 4326
COPY (
    SELECT 
        id,
        subtype,
        class,
        has_parts,
        height,
        area,
        geometry
    FROM rbt_building
) TO (getvariable('output_dir') || '/building_4326.fgb')
WITH (FORMAT GDAL, DRIVER 'FlatGeobuf', SRS 'EPSG:4326');

-- Z10 in EPSG:4326

COPY (
    SELECT 
        id,
        subtype,
        class,
        has_parts,
        height,
        area,
        geometry
    FROM rbt_building_z10
) TO (getvariable('output_dir') || '/building_z10_4326.fgb')
WITH (FORMAT GDAL, DRIVER 'FlatGeobuf', SRS 'EPSG:4326');

-- Z11 in EPSG:4326
COPY (
    SELECT 
        id,
        subtype,
        class,
        has_parts,
        height,
        area,
        geometry
    FROM rbt_building_z11
) TO (getvariable('output_dir') || '/building_z11_4326.fgb')
WITH (FORMAT GDAL, DRIVER 'FlatGeobuf', SRS 'EPSG:4326');

-- Z12 in EPSG:4326
COPY (
    SELECT 
        id,
        subtype,
        class,
        has_parts,
        height,
        area,
        geometry
    FROM rbt_building_z12
) TO (getvariable('output_dir') || '/building_z12_4326.fgb')
WITH (FORMAT GDAL, DRIVER 'FlatGeobuf', SRS 'EPSG:4326');
