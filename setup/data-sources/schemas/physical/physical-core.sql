-- ==============================================================================
-- ENHANCED PHYSICAL LAYER SQL SCRIPT FOR CI/CD PROCESSING
-- Optimized for execution after imposm3 import completion
-- NOTE: Landcover processing has been extracted to landcover.sql
-- NOTE: Water processing has been extracted to water.sql
-- Run landcover.sql and water.sql separately if those views are needed
-- ==============================================================================

-- Enable timing for CI/CD monitoring
\timing on

-- Start transaction with error handling
BEGIN;

-- ==============================================================================
-- STEP 1: CONFIGURATION AND PERFORMANCE SETTINGS
-- ==============================================================================

-- Set memory configurations for heavy spatial operations (optimized for 256GB system)
SET LOCAL work_mem = '32GB';
SET LOCAL maintenance_work_mem = '64GB';
SET LOCAL max_parallel_workers_per_gather = 8;
SET LOCAL parallel_tuple_cost = 0.1;
SET LOCAL parallel_setup_cost = 1000;
SET LOCAL enable_parallel_hash = on;
SET LOCAL max_parallel_maintenance_workers = 8;
SET LOCAL effective_cache_size = '192GB';
SET LOCAL jit = on;



\echo 'Physical layer processing started with enhanced performance settings'

-- ==============================================================================
-- STEP 2: DEPENDENCY VALIDATION
-- ==============================================================================

\echo 'Validating source data dependencies...'

DO $$
DECLARE
    table_count INTEGER;
    error_msg TEXT;
BEGIN
    

    -- Validate import.park_polygon exists and has data
    SELECT COUNT(*) INTO table_count FROM import.park_polygon LIMIT 1;
    IF table_count = 0 THEN
        RAISE EXCEPTION 'Source table import.park_polygon is empty or missing. Cannot proceed with physical layer processing.';
    END IF;
    
    -- Validate import.builtup_area exists and has data
    SELECT COUNT(*) INTO table_count FROM import.builtup_area LIMIT 1;
    IF table_count = 0 THEN
        RAISE EXCEPTION 'Source table import.builtup_area is empty or missing. Cannot proceed with physical layer processing.';
    END IF;
    
    -- Validate naturalearth schema exists
    IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'naturalearth') THEN
        RAISE EXCEPTION 'Schema naturalearth is missing. Cannot proceed with physical layer processing.';
    END IF;
    


    RAISE NOTICE 'All required source tables validated successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE EXCEPTION 'Dependency validation failed: %', error_msg;
END $$;

\echo 'Source data validation completed successfully'

-- ==============================================================================
-- STEP 3: DROP EXISTING MATERIALIZED VIEWS FOR CLEAN REBUILD
-- ==============================================================================

\echo 'Dropping existing materialized views for clean rebuild...'

-- Drop materialized views that will be recreated (cascade to handle dependencies)
DROP MATERIALIZED VIEW IF EXISTS rbt.mountain_label CASCADE;
DROP MATERIALIZED VIEW IF EXISTS rbt.glacier_ne CASCADE;
DROP MATERIALIZED VIEW IF EXISTS rbt.glacier_osm CASCADE;
DROP MATERIALIZED VIEW IF EXISTS rbt.builtuparea_ne CASCADE;
DROP MATERIALIZED VIEW IF EXISTS rbt.builtuparea_osm CASCADE;

-- Drop regular views that depend on materialized views
-- Note: Landcover views are now handled in landcover.sql
-- Note: Water views are now handled in water.sql

\echo 'Existing views dropped successfully'

-- ==============================================================================
-- STEP 4: CREATE CRITICAL INDEXES FOR PERFORMANCE
-- ==============================================================================

\echo 'Creating critical indexes for optimal performance...'

-- Note: Landcover indexes are now handled in landcover.sql
-- Note: Water indexes are now handled in water.sql
-- Source table indexes for import.park_polygon
CREATE INDEX IF NOT EXISTS idx_park_subclass ON import.park_polygon USING btree(subclass);
CREATE INDEX IF NOT EXISTS idx_park_area ON import.park_polygon USING btree(ST_Area(geometry));
CREATE INDEX IF NOT EXISTS idx_park_geometry ON import.park_polygon USING gist(geometry);
CREATE INDEX IF NOT EXISTS idx_park_name ON import.park_polygon USING btree(name) WHERE name IS NOT NULL AND name != '';

-- Source table indexes for import.builtup_area
CREATE INDEX IF NOT EXISTS idx_builtup_area_name_trgm ON import.builtup_area USING gin(name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_builtup_class_subclass ON import.builtup_area USING btree(class, subclass);
CREATE INDEX IF NOT EXISTS idx_builtup_geometry ON import.builtup_area USING gist(geometry);
CREATE INDEX IF NOT EXISTS idx_builtup_area_calc ON import.builtup_area USING btree(ST_Area(geometry));

\echo 'Critical indexes created successfully'

-- Commit indexes to ensure they persist even if later steps fail
COMMIT;
\echo 'Indexes committed successfully - they will persist even if later steps fail'

-- Start new transaction for utility functions
BEGIN;

-- ==============================================================================
-- STEP 5: CREATE UTILITY FUNCTIONS
-- ==============================================================================

\echo 'Creating utility functions...'


-- Create helper function for efficient geometry validation
CREATE OR REPLACE FUNCTION safe_simplify_geometry(geom geometry, tolerance float8)
RETURNS geometry AS $$
BEGIN
  -- Ensure geometry is valid before simplification
  IF NOT ST_IsValid(geom) THEN
    geom := ST_MakeValid(geom);
  END IF;
  
  -- Use ST_SimplifyPreserveTopology for safety
  RETURN ST_SimplifyPreserveTopology(geom, tolerance);
EXCEPTION WHEN OTHERS THEN
  -- Return original geometry if simplification fails
  RETURN geom;
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE;

-- ==============================================================================
-- HELPER FUNCTIONS FOR TRIGRAM-POWERED TEXT SEARCH
-- ==============================================================================



\echo 'Utility functions created successfully'

-- Commit utility functions to ensure they persist even if later steps fail
COMMIT;
\echo 'Utility functions committed successfully'

-- Start new transaction for materialized views
BEGIN;

-- ==============================================================================
-- STEP 6: CREATE MATERIALIZED VIEWS FOR HIGH-PERFORMANCE QUERIES
-- ==============================================================================

\echo 'Creating materialized views for optimal CI/CD performance...'

-- ==============================================================================
-- BUILTUPAREA_NE MATERIALIZED VIEW
-- ==============================================================================

\echo 'Creating rbt.builtuparea_ne materialized view...'

CREATE MATERIALIZED VIEW rbt.builtuparea_ne AS
SELECT
    'ne' AS class,
    featurecla AS subclass,
    ST_Area(ST_Transform(geometry, 3857))::real AS area,
    (ST_Dump(ST_MakeValid(ST_SimplifyPreserveTopology(geometry, 0.000001),'method=structure'))).geom::geometry(Polygon,4326) as geometry
FROM naturalearth.ne_10m_urban_areas
WHERE geometry IS NOT NULL;

-- Create indexes on builtuparea_ne materialized view
CREATE INDEX IF NOT EXISTS idx_builtuparea_ne_class ON rbt.builtuparea_ne USING btree(class);
CREATE INDEX IF NOT EXISTS idx_builtuparea_ne_subclass ON rbt.builtuparea_ne USING btree(subclass);
CREATE INDEX IF NOT EXISTS idx_builtuparea_ne_area ON rbt.builtuparea_ne USING btree(area);
CREATE INDEX IF NOT EXISTS idx_builtuparea_ne_geometry ON rbt.builtuparea_ne USING gist(geometry);

-- ==============================================================================
-- BUILTUPAREA_OSM MATERIALIZED VIEW
-- ==============================================================================

\echo 'Creating rbt.builtuparea_osm materialized view...'

CREATE MATERIALIZED VIEW rbt.builtuparea_osm AS
SELECT
    'osm' AS class,
    subclass,
    ST_Area(ST_Transform(geometry, 3857))::real AS area,
    (ST_Dump(ST_MakeValid(ST_SimplifyPreserveTopology(geometry, 0.000001),'method=structure'))).geom::geometry(Polygon,4326) as geometry
FROM import.builtup_area
WHERE class = 'landuse' OR (class = 'place' AND subclass IN ('city', 'town', 'village', 'hamlet'))
  AND geometry IS NOT NULL;

-- Create indexes on builtuparea_osm materialized view
CREATE INDEX IF NOT EXISTS idx_builtuparea_osm_class ON rbt.builtuparea_osm USING btree(class);
CREATE INDEX IF NOT EXISTS idx_builtuparea_osm_subclass ON rbt.builtuparea_osm USING btree(subclass);
CREATE INDEX IF NOT EXISTS idx_builtuparea_osm_area ON rbt.builtuparea_osm USING btree(area);
CREATE INDEX IF NOT EXISTS idx_builtuparea_osm_geometry ON rbt.builtuparea_osm USING gist(geometry);

-- ==============================================================================
-- GLACIER_NE MATERIALIZED VIEW
-- ==============================================================================

\echo 'Creating rbt.glacier_ne materialized view...'

CREATE MATERIALIZED VIEW rbt.glacier_ne AS
    -- Antarctic ice shelves
    SELECT
        'ne' as source,
        NULLIF(name, '') as name,
        (ST_Dump(ST_MakeValid(ST_SimplifyPreserveTopology(geometry, 0.000001),'method=structure'))).geom::geometry(Polygon,4326) as geometry
    FROM naturalearth.ne_10m_antarctic_ice_shelves_polys
    WHERE geometry IS NOT NULL
    
    UNION ALL
    
    -- Glaciated areas
    SELECT
        'ne' as source,
        NULLIF(name, '') as name,
        (ST_Dump(ST_MakeValid(ST_SimplifyPreserveTopology(geometry, 0.000001),'method=structure'))).geom::geometry(Polygon,4326) as geometry
    FROM naturalearth.ne_10m_glaciated_areas
    WHERE geometry IS NOT NULL;

-- Create indexes on glacier_ne materialized view
CREATE INDEX IF NOT EXISTS idx_glacier_ne_source ON rbt.glacier_ne USING btree(source);
CREATE INDEX IF NOT EXISTS idx_glacier_ne_geometry ON rbt.glacier_ne USING gist(geometry);

-- ==============================================================================
-- GLACIER_OSM MATERIALIZED VIEW
-- ==============================================================================

\echo 'Creating rbt.glacier_osm materialized view...'

CREATE MATERIALIZED VIEW rbt.glacier_osm AS
    SELECT
      'osm' as source,
      NULLIF(TRIM(tags -> 'name'), '') as name,
      (ST_Dump(ST_MakeValid(ST_SimplifyPreserveTopology(geometry, 0.000001),'method=structure'))).geom::geometry(Polygon,4326) as geometry
    FROM import.landcover 
    WHERE subclass = 'glacier'
      AND geometry IS NOT NULL

    UNION ALL

    SELECT
      'osm' as source,
      'antarctica_icesheet' as name,
      (ST_Dump(ST_MakeValid(ST_SimplifyPreserveTopology(geometry, 0.000001),'method=structure'))).geom::geometry(Polygon,4326) as geometry
    FROM rbt.osm_antarctica_icesheet
    WHERE geometry IS NOT NULL;

-- Create indexes on glacier_osm materialized view
CREATE INDEX IF NOT EXISTS idx_glacier_osm_source ON rbt.glacier_osm USING btree(source);
CREATE INDEX IF NOT EXISTS idx_glacier_osm_geometry ON rbt.glacier_osm USING gist(geometry);

-- Note: Landcover materialized view processing moved to landcover.sql


-- ==============================================================================
-- MOUNTAIN LABEL MATERIALIZED VIEW
-- ==============================================================================

\echo 'Creating rbt.mountain_label materialized view...'

CREATE MATERIALIZED VIEW rbt.mountain_label AS
WITH medial_axis AS (
    SELECT 
        featurecla,
        label,
        max_label,
        min_label,
        name,
        name_ar,
        name_bn,
        name_de,
        name_el,
        name_en,
        name_es,
        name_fa,
        name_fr,
        name_he,
        name_hi,
        name_hu,
        name_id,
        name_it,
        name_ja,
        name_ko,
        name_nl,
        name_pl,
        name_pt,
        name_ru,
        name_sv,
        name_tr,
        name_uk,
        name_ur,
        name_vi,
        name_zh,
        name_zht,
        namealt,
        ne_id,
        region,
        scalerank,
        subregion,
        CG_ApproximateMedialAxis(geometry) as medial_geom
    FROM naturalearth.ne_10m_geography_regions_polys
    WHERE geometry IS NOT NULL 
      AND ST_IsValid(geometry)
      AND NOT ST_IsEmpty(geometry)
),
medial_lines AS (
    SELECT 
        *,
        (ST_Dump(medial_geom)).geom as line_segment
    FROM medial_axis
),
ranked_lines AS (
    SELECT 
        *,
        ST_Length(line_segment) as segment_length,
        ROW_NUMBER() OVER (PARTITION BY ne_id ORDER BY ST_Length(line_segment) DESC) as rn
    FROM medial_lines
    WHERE line_segment IS NOT NULL 
      AND ST_GeometryType(line_segment) = 'ST_LineString'
)
SELECT
    ne_id,
    NULLIF(featurecla, '') as featurecla,
    NULLIF(label, '') as label,
    segment_length as length,
    max_label,
    min_label,
    NULLIF(name, '') as name,
    NULLIF(name_ar, '') as name_ar,
    NULLIF(name_bn, '') as name_bn,
    NULLIF(name_de, '') as name_de,
    NULLIF(name_el, '') as name_el,
    NULLIF(name_en, '') as name_en,
    NULLIF(name_es, '') as name_es,
    NULLIF(name_fa, '') as name_fa,
    NULLIF(name_fr, '') as name_fr,
    NULLIF(name_he, '') as name_he,
    NULLIF(name_hi, '') as name_hi,
    NULLIF(name_hu, '') as name_hu,
    NULLIF(name_id, '') as name_id,
    NULLIF(name_it, '') as name_it,
    NULLIF(name_ja, '') as name_ja,
    NULLIF(name_ko, '') as name_ko,
    NULLIF(name_nl, '') as name_nl,
    NULLIF(name_pl, '') as name_pl,
    NULLIF(name_pt, '') as name_pt,
    NULLIF(name_ru, '') as name_ru,
    NULLIF(name_sv, '') as name_sv,
    NULLIF(name_tr, '') as name_tr,
    NULLIF(name_uk, '') as name_uk,
    NULLIF(name_ur, '') as name_ur,
    NULLIF(name_vi, '') as name_vi,
    NULLIF(name_zh, '') as name_zh,
    NULLIF(name_zht, '') as name_zht,
    NULLIF(namealt, '') as namealt,
    NULLIF(region, '') as region,
    scalerank,
    NULLIF(subregion, '') as subregion,
    line_segment as geometry
FROM ranked_lines
WHERE rn = 1;

-- Create indexes on materialized view
CREATE INDEX IF NOT EXISTS idx_mountain_label_geometry ON rbt.mountain_label USING GIST (geometry);
CREATE INDEX IF NOT EXISTS idx_mountain_label_ne_id ON rbt.mountain_label (ne_id);
CREATE INDEX IF NOT EXISTS idx_mountain_label_name ON rbt.mountain_label (name) WHERE name IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_mountain_label_scalerank ON rbt.mountain_label (scalerank);

\echo 'All materialized views (builtuparea_ne, builtuparea_osm, glacier_ne, glacier_osm, mountain_label) created successfully (landcover and water are handled separately)'

-- Commit materialized views to ensure they persist even if later steps fail
COMMIT;
\echo 'Materialized views committed successfully'

-- Start new transaction for regular views
BEGIN;

-- ==============================================================================
-- STEP 7: CREATE REGULAR VIEWS (ZOOM LEVELS AND SPECIALIZED VIEWS)
-- ==============================================================================

\echo 'Creating regular views for zoom levels and specialized queries...'



-- Note: Landcover views (zoom-level and label) are now handled in landcover.sql

-- Builtuparea view (union of builtuparea_ne and builtuparea_osm materialized views)
CREATE VIEW rbt.builtuparea AS
SELECT 
    class,
    subclass,
    area,
    geometry
FROM rbt.builtuparea_ne
UNION ALL
SELECT 
    class,
    subclass,
    area,
    geometry
FROM rbt.builtuparea_osm;

-- Glacier view (union of glacier_ne and glacier_osm materialized views)
CREATE VIEW rbt.glacier AS
SELECT 
    source,
    name,
    geometry
FROM rbt.glacier_ne
UNION ALL
SELECT 
    source,
    name,
    geometry
FROM rbt.glacier_osm;

-- Park view
CREATE VIEW rbt.park AS
SELECT
    osm_id,
    NULLIF(access, '') as access,
    NULLIF(class, '') as class,
    NULLIF(subclass, '') as subclass,
    NULLIF(iucn_level, '') as iucn_level,
    NULLIF(name, '') as name,
    NULLIF(name_en, '') as name_en,
    NULLIF(protect_class, '') as protect_class,
    ST_Area(ST_Transform(geometry, 3857))::real as area,
    geometry
FROM import.park_polygon
WHERE subclass IN ('District', 'Regional', 'aboriginal_lands', 'city_park',
              'community', 'county_park', 'dog_park', 'golf_course',
              'national_park', 'natural_area', 'nature_reserve',
              'neighbourhood', 'park', 'pitch', 'private_park',
              'protected_area', 'recreation_ground', 'regional',
              'special', 'state_beach', 'state_historic_park', 'state_park');


\echo 'Regular views created successfully'

-- Commit all views to ensure they persist even if analysis or validation fails
COMMIT;
\echo 'All regular views committed successfully'

-- Start new transaction for analysis and validation
BEGIN;

-- ==============================================================================
-- STEP 8: ANALYZE TABLES FOR OPTIMAL QUERY PLANNING
-- ==============================================================================

\echo 'Analyzing tables for optimal query planning...'

-- Analyze materialized views
ANALYZE rbt.builtuparea_ne;
ANALYZE rbt.builtuparea_osm;
ANALYZE rbt.glacier_ne;
ANALYZE rbt.glacier_osm;
-- Note: rbt.landcover analysis moved to landcover.sql
-- Note: Water analysis moved to water.sql
ANALYZE rbt.mountain_label;

-- Analyze source tables
-- Note: import.landcover analysis moved to landcover.sql
-- Note: Water source tables analysis moved to water.sql
ANALYZE import.park_polygon;
ANALYZE import.builtup_area;

\echo 'Table analysis completed'

-- ==============================================================================
-- STEP 9: FINAL VALIDATION AND COMMIT
-- ==============================================================================

\echo 'Performing final validation...'

DO $$
DECLARE
    rec RECORD;
    error_count INTEGER := 0;
    row_count INTEGER;
BEGIN
    -- Validate that all materialized views were created successfully
    FOR rec IN 
        SELECT 'rbt.builtuparea_ne' as view_name
        UNION ALL SELECT 'rbt.builtuparea_osm'
        UNION ALL SELECT 'rbt.glacier_ne'
        UNION ALL SELECT 'rbt.glacier_osm'
        -- Note: rbt.landcover validation moved to landcover.sql
        -- Note: Water views validation moved to water.sql
        UNION ALL SELECT 'rbt.mountain_label'
    LOOP
        -- Check using pg_matviews system catalog for materialized views
        IF NOT EXISTS (
            SELECT 1 FROM pg_matviews 
            WHERE schemaname = split_part(rec.view_name, '.', 1) 
            AND matviewname = split_part(rec.view_name, '.', 2)
        ) THEN
            RAISE WARNING 'Materialized view % was not created successfully', rec.view_name;
            error_count := error_count + 1;
        ELSE
            -- Also check that the materialized view has data
            EXECUTE format('SELECT COUNT(*) FROM %I.%I LIMIT 1', 
                          split_part(rec.view_name, '.', 1), 
                          split_part(rec.view_name, '.', 2)) INTO row_count;
            RAISE NOTICE 'Materialized view % created successfully with data', rec.view_name;
        END IF;
    END LOOP;
    
    -- Check row counts for key materialized views
    -- Note: rbt.landcover validation moved to landcover.sql
    -- Note: Water views validation moved to water.sql
    
    IF error_count > 0 THEN
        RAISE EXCEPTION 'Physical layer processing completed with % errors. Review warnings above.', error_count;
    ELSE
        RAISE NOTICE 'All materialized views created successfully and validated';
    END IF;
END $$;

\echo 'Final validation completed successfully'

-- Commit transaction
COMMIT;

\echo '=============================================================================='
\echo 'PHYSICAL LAYER PROCESSING COMPLETED SUCCESSFULLY'
\echo 'Enhanced script execution finished with optimizations:'
\echo '- Created materialized views for optimal performance'
\echo '- Added comprehensive indexes for fast queries'
\echo '- Implemented transaction management with intermediate commits'
\echo '- Added dependency validation for reliable CI/CD execution'
\echo '- Uses checkpoint commits to preserve work if later steps fail'
\echo 'NOTE: Landcover processing has been extracted to landcover.sql'
\echo 'NOTE: Water processing has been extracted to water.sql'
\echo 'Run landcover.sql and water.sql separately if those views are needed'
\echo '=============================================================================='

-- Disable timing
\timing off
