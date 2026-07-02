-- =============================================================================
-- CI seed data for the `integration-tiles` job (.github/workflows/ci.yml)
-- =============================================================================
-- Minimal stand-in for the rbt.building view (the real CREATE is commented
-- out in setup/data-sources/schemas/cultural/cultural-core.sql pending real
-- Overture ingestion — see that file). A handful of small building
-- footprints, with area comfortably above every zoom threshold in the
-- `building` tippecanoe filter (config/layers.yml `filters.building`) so
-- they survive to every zoom from min_zoom (10) to max_zoom (13).

CREATE EXTENSION IF NOT EXISTS postgis;

CREATE SCHEMA IF NOT EXISTS rbt;

DROP TABLE IF EXISTS rbt.building;

CREATE TABLE rbt.building (
    id text,
    class text,
    subtype text,
    has_parts boolean,
    height double precision,
    area double precision,
    geom geometry (MultiPolygon, 3857)
);

INSERT INTO rbt.building (id, class, subtype, has_parts, height, area, geom) VALUES
(
    'building_meridian', 'building', 'residential', false, 8.5, 20000,
    ST_Multi(ST_Buffer(ST_SetSRID(ST_MakePoint(0, 0), 3857), 80))
),
(
    'building_boreal', 'building', 'commercial', false, 12.0, 20000,
    ST_Multi(ST_Buffer(ST_SetSRID(ST_MakePoint(1500000, 6500000), 3857), 80))
),
(
    'building_austral', 'building', 'industrial', true, 15.0, 20000,
    ST_Multi(ST_Buffer(ST_SetSRID(ST_MakePoint(-7000000, -4000000), 3857), 80))
);
