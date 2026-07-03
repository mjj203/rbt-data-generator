-- Empty reference-table stubs for the nightly OSM-fixture pipeline.
--
-- The schema units `water`, `landcover`, `highway`, and `railway` reference a
-- handful of non-OSM tables that the real importers normally create. On the
-- nightly's OSM-only database these stubs satisfy the references with the
-- exact column shapes the SQL consumes; empty is safe because every consumer
-- LEFT-JOINs or filters them (verified against water-features.sql and
-- transportation.sql).

CREATE SCHEMA IF NOT EXISTS rbt;
CREATE SCHEMA IF NOT EXISTS naturalearth;
CREATE SCHEMA IF NOT EXISTS fieldmap;

-- water-features.sql: existence-validated at unit start; read via
-- ST_SimplifyPreserveTopology/ST_Dump (osm_ocean) and a geometry-only CTE
-- (osm_ocean_simplified).
CREATE TABLE IF NOT EXISTS rbt.osm_ocean (
    geometry geometry(Polygon, 4326)
);

CREATE TABLE IF NOT EXISTS rbt.osm_ocean_simplified (
    subclass text,
    geometry geometry(Polygon, 4326)
);

-- water-features.sql: LEFT JOIN rbt.sound_ocean so ON so.osm_id = ws.osm_id
CREATE TABLE IF NOT EXISTS rbt.sound_ocean (
    osm_id bigint
);

-- water-features.sql: rbt.ne_water_label view reads featurecla, name, geometry.
CREATE TABLE IF NOT EXISTS naturalearth.ne_10m_geography_marine_polys (
    featurecla text,
    name text,
    geometry geometry(MultiPolygon, 4326)
);

-- transportation.sql: import.highway_fieldmap matview JOINs on gid_0 +
-- geometry; downstream consumers LEFT JOIN it with COALESCE(gid_0, 'OTHER').
CREATE TABLE IF NOT EXISTS fieldmap.usa (
    gid_0 text,
    geometry geometry(MultiPolygon, 4326)
);
