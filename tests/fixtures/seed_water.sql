-- =============================================================================
-- CI seed data for the `integration-tiles` job (.github/workflows/ci.yml)
-- =============================================================================
-- Minimal stand-in for the rbt.water view produced by
-- setup/data-sources/schemas/physical/water-features.sql: a handful of small
-- multipolygon "lakes" spread across the globe, enough for tippecanoe (3857)
-- and the GDAL MVT driver (4326) to emit non-empty tiles.
--
-- The EPSG:4326 gdal_mvt dataset (config/layers.yml) reads both
-- rbt.water_simplified (z0-9) and rbt.water (z10-13), so both tables are
-- created here.

CREATE EXTENSION IF NOT EXISTS postgis;

CREATE SCHEMA IF NOT EXISTS rbt;

DROP TABLE IF EXISTS rbt.water;

CREATE TABLE rbt.water (
    id serial PRIMARY KEY,
    name text,
    geom geometry (MultiPolygon, 3857)
);

INSERT INTO rbt.water (name, geom) VALUES
(
    'lake_meridian',
    ST_Multi(ST_Buffer(ST_SetSRID(ST_MakePoint(0, 0), 3857), 50000))
),
(
    'lake_boreal',
    ST_Multi(ST_Buffer(ST_SetSRID(ST_MakePoint(1500000, 6500000), 3857), 50000))
),
(
    'lake_austral',
    ST_Multi(ST_Buffer(ST_SetSRID(ST_MakePoint(-7000000, -4000000), 3857), 50000))
),
(
    'lake_oriental',
    ST_Multi(ST_Buffer(ST_SetSRID(ST_MakePoint(12000000, 4500000), 3857), 50000))
),
(
    'lake_occidental',
    ST_Multi(ST_Buffer(ST_SetSRID(ST_MakePoint(-11000000, 5200000), 3857), 50000))
);

DROP TABLE IF EXISTS rbt.water_simplified;

CREATE TABLE rbt.water_simplified AS
SELECT * FROM rbt.water;
