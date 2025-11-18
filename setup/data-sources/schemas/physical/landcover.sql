-- ==============================================================================
-- LANDCOVER LAYER SQL SCRIPT FOR CI/CD PROCESSING
-- Extracted from physical.sql for modular processing
-- Optimized for execution after imposm3 import completion
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

\echo 'Landcover layer processing started with enhanced performance settings'

-- ==============================================================================
-- STEP 2: DEPENDENCY VALIDATION
-- ==============================================================================

\echo 'Validating landcover data dependencies...'

DO $$
DECLARE
    table_count INTEGER;
    error_msg TEXT;
BEGIN
    -- Validate import.landcover exists and has data
    SELECT COUNT(*) INTO table_count FROM import.landcover LIMIT 1;
    IF table_count = 0 THEN
        RAISE EXCEPTION 'Source table import.landcover is empty or missing. Cannot proceed with landcover layer processing.';
    END IF;
    
    RAISE NOTICE 'Landcover source table validated successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE EXCEPTION 'Landcover dependency validation failed: %', error_msg;
END $$;

\echo 'Landcover data validation completed successfully'

-- ==============================================================================
-- STEP 3: DROP EXISTING LANDCOVER VIEWS FOR CLEAN REBUILD
-- ==============================================================================

\echo 'Dropping existing landcover views for clean rebuild...'

-- Drop materialized views that will be recreated (cascade to handle dependencies)
DROP MATERIALIZED VIEW IF EXISTS rbt.landcover CASCADE;

-- Drop regular views that depend on materialized views
DROP VIEW IF EXISTS rbt.landcover_z4 CASCADE;
DROP VIEW IF EXISTS rbt.landcover_z6 CASCADE;
DROP VIEW IF EXISTS rbt.landcover_z9 CASCADE;
DROP VIEW IF EXISTS rbt.landcover_z10 CASCADE;
DROP VIEW IF EXISTS rbt.landcover_labels CASCADE;
DROP VIEW IF EXISTS rbt.landcover_labels_z4 CASCADE;
DROP VIEW IF EXISTS rbt.landcover_labels_z6 CASCADE;
DROP VIEW IF EXISTS rbt.landcover_labels_z9 CASCADE;
DROP VIEW IF EXISTS rbt.landcover_labels_z10 CASCADE;

\echo 'Existing landcover views dropped successfully'

-- ==============================================================================
-- STEP 4: CREATE CRITICAL INDEXES FOR PERFORMANCE
-- ==============================================================================

\echo 'Creating critical indexes for optimal landcover performance...'

-- Source table indexes for import.landcover
CREATE INDEX IF NOT EXISTS idx_landcover_subclass ON import.landcover USING gin(subclass gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_landcover_wetland ON import.landcover USING gin(wetland gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_landcover_leaftype ON import.landcover USING gin(leaf_type gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_landcover_leafcycle ON import.landcover USING gin(leaf_cycle gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_landcover_osmid ON import.landcover USING btree(osm_id);
CREATE INDEX IF NOT EXISTS idx_landcover_seasonal ON import.landcover USING btree(seasonal);
CREATE INDEX IF NOT EXISTS idx_landcover_intermittent ON import.landcover USING btree(intermittent);
CREATE INDEX IF NOT EXISTS idx_landcover_geometry ON import.landcover USING gist(geometry);

-- Partial indexes for specific queries
CREATE INDEX IF NOT EXISTS idx_landcover_glacier ON import.landcover USING btree(subclass) 
    WHERE subclass = 'glacier'; -- 100% coverage
CREATE INDEX IF NOT EXISTS idx_landcover_wetland ON import.landcover USING btree(subclass) 
    WHERE subclass = 'wetland'; -- 100% coverage

-- Tag-based indexes for landcover
CREATE INDEX IF NOT EXISTS idx_landcover_tags_key_name ON import.landcover USING btree((tags->'name '))
  WHERE exist(tags, 'name');
CREATE INDEX IF NOT EXISTS idx_landcover_tags_key_name_en ON import.landcover USING btree((tags->'name:en'))
  WHERE exist(tags, 'name:en');

\echo 'Critical landcover indexes created successfully'

-- Commit indexes to ensure they persist even if later steps fail
COMMIT;
\echo 'Indexes committed successfully - they will persist even if later steps fail'

-- Start new transaction for materialized view creation
BEGIN;

-- ==============================================================================
-- STEP 5: CREATE LANDCOVER MATERIALIZED VIEW
-- ==============================================================================

\echo 'Creating rbt.landcover materialized view...'

CREATE MATERIALIZED VIEW rbt.landcover AS
WITH leafcycle AS (
    SELECT
        osm_id,
        id,
        class,
        seasonal,
        NULLIF(TRIM(tags -> 'name'), '') AS name,
        NULLIF(TRIM(tags -> 'name_en'), '') AS name_en,
        
        CASE
            WHEN leaf_type ~ '^broad' THEN 'broadleaved'
            WHEN leaf_type ~ '^con' THEN 'coniferous'
            WHEN leaf_type ~ '^dec' THEN 'deciduous'
            WHEN leaf_type ~ '^leaf' THEN 'leafless'
            WHEN leaf_type ~ '^mix' THEN 'mixed'
            WHEN leaf_type ~ '^needle' THEN 'needleleaved'
            ELSE NULL
        END AS leaf_type,
        
        CASE
            WHEN leaf_cycle IN ('deciduous', 'semi_deciduous') THEN 'deciduous'
            WHEN leaf_cycle IN ('evergreen', 'semi_evergreen') THEN 'evergreen'
            WHEN leaf_cycle ~ '^m' THEN 'mixed'
            ELSE NULL
        END AS leaf_cycle,
        
        CASE
            WHEN subclass = 'wetland' THEN 
                CASE tags -> 'wetland'
                    WHEN 'mangrove' THEN 'mangrove'
                    WHEN 'bog' THEN 'bog'
                    WHEN 'marsh' THEN 'marsh'
                    WHEN 'swamp' THEN 'swamp'
                    WHEN 'fen' THEN 'fen'
                    WHEN 'saltmarsh' THEN 'saltmarsh'
                    WHEN 'reedbed' THEN 'reedbed'
                    WHEN 'wet_meadow' THEN 'wet_meadow'
                    WHEN 'yes' THEN 'unknown_wetland'
                    WHEN NULL THEN 'unknown_wetland'
                    ELSE tags -> 'wetland'
                END
            ELSE subclass
        END AS subclass,
        
        COALESCE(seasonal::text, intermittent::text, 'false') AS intermittent,
        
        tags,
        ST_Area(ST_Transform(geometry, 3857))::real AS area,
        geometry
    FROM import.landcover
    WHERE ST_GeometryType(geometry) IN ('ST_Polygon', 'ST_MultiPolygon')
      AND subclass NOT IN ('glacier', 'recreation_ground')
),
filtered AS (
    SELECT 
        osm_id,
        name,
        name_en,
        subclass,
        intermittent,
        leaf_type,
        CASE
            WHEN leaf_type IN ('coniferous', 'needleleaved') AND leaf_cycle IS NULL THEN 'evergreen'
            WHEN leaf_type IN ('deciduous', 'broadleaved', 'leafless') AND leaf_cycle IS NULL THEN 'deciduous'
            WHEN leaf_type = 'mixed' AND leaf_cycle IS NULL THEN 'mixed'
            ELSE leaf_cycle
        END AS leaf_cycle,
        ST_GeometryType(geometry) = 'ST_MultiPolygon' AS is_multipolygon,
        area,
        geometry
    FROM leafcycle
)
SELECT 
    f.osm_id,
    f.name,
    f.name_en,
    f.subclass,
    f.intermittent,
    f.leaf_type,
    f.leaf_cycle,
    CASE
        WHEN f.is_multipolygon THEN
            ROW_NUMBER() OVER (PARTITION BY f.osm_id ORDER BY ST_Area(COALESCE(d.geom, f.geometry)) DESC)
        ELSE NULL
    END AS rank,
    f.area,
    CASE
        WHEN f.is_multipolygon THEN ST_Area(COALESCE(d.geom, f.geometry))
        ELSE NULL
    END AS area_part,
    COALESCE(d.geom, f.geometry) AS geometry
FROM filtered f
LEFT JOIN LATERAL (
    SELECT (ST_Dump(f.geometry)).geom
    WHERE f.is_multipolygon
) d ON true;

-- Create indexes on materialized view
CREATE INDEX IF NOT EXISTS idx_landcover_osm_id ON rbt.landcover USING btree(osm_id);
CREATE INDEX IF NOT EXISTS idx_landcover_subclass_mv ON rbt.landcover USING btree(subclass);
CREATE INDEX IF NOT EXISTS idx_landcover_area_mv ON rbt.landcover USING btree(area) WHERE area IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_landcover_leaf_type_mv ON rbt.landcover USING btree(leaf_type) WHERE leaf_type IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_landcover_leaf_cycle_mv ON rbt.landcover USING btree(leaf_cycle) WHERE leaf_cycle IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_landcover_geometry_mv ON rbt.landcover USING gist(geometry);
CREATE INDEX IF NOT EXISTS idx_landcover_name_mv ON rbt.landcover USING btree(name) WHERE name IS NOT NULL;
-- Partial index for zoom level filtering
CREATE INDEX IF NOT EXISTS idx_landcover_area_z4 ON rbt.landcover USING btree(area) 
    WHERE area >= 15625000 AND subclass IN ('sand', 'dune', 'dune_system', 'beach');

\echo 'Landcover materialized view created successfully'

-- Commit materialized view to ensure it persists even if later steps fail
COMMIT;
\echo 'Materialized view committed successfully'

-- Start new transaction for view creation
BEGIN;

-- ==============================================================================
-- STEP 6: CREATE LANDCOVER ZOOM-LEVEL VIEWS
-- ==============================================================================

\echo 'Creating landcover zoom-level views...'

-- Landcover zoom-level views
CREATE VIEW rbt.landcover_z4 AS
SELECT * FROM rbt.landcover
WHERE area >= 15625000 
  AND subclass IN ('sand', 'dune', 'dune_system', 'beach');

CREATE VIEW rbt.landcover_z6 AS
SELECT * FROM rbt.landcover
WHERE area >= 15625000 
  AND subclass IN ('sand', 'dune', 'dune_system', 'beach', 'bog', 'mangrove', 
                   'marsh', 'reedbed', 'rice', 'saltmarsh', 'swamp', 
                   'unknown_wetland', 'wetland', 'paddy', 'wet_meadow');

CREATE VIEW rbt.landcover_z9 AS
SELECT * FROM rbt.landcover
WHERE subclass IN ('sand', 'dune', 'dune_system', 'beach', 'bog', 'mangrove', 
                   'marsh', 'reedbed', 'rice', 'paddy', 'saltmarsh', 'swamp', 
                   'unknown_wetland', 'wetland', 'wet_meadow');

CREATE VIEW rbt.landcover_z10 AS
SELECT * FROM rbt.landcover
WHERE subclass IN ('sand', 'dune', 'dune_system', 'beach', 'bog', 'mangrove', 
                   'marsh', 'reedbed', 'rice', 'saltmarsh', 'swamp', 
                   'unknown_wetland', 'wetland', 'wet_meadow', 'meadow', 
                   'grassland', 'forest', 'wood', 'tundra', 'reef', 'scrub', 
                   'heath', 'farm', 'farmland', 'orchard', 'paddy', 'vineyard');

\echo 'Landcover zoom-level views created successfully'

-- ==============================================================================
-- STEP 7: CREATE LANDCOVER LABEL VIEWS
-- ==============================================================================

\echo 'Creating landcover label views...'

-- Landcover label views
CREATE VIEW rbt.landcover_labels AS
SELECT
    osm_id,
    name,
    name_en,
    subclass,
    intermittent,
    leaf_type,
    leaf_cycle,
    area,
    ST_PointOnSurface(geometry)::geometry(Point,4326) AS geometry
FROM rbt.landcover
WHERE name IS NOT NULL OR name_en IS NOT NULL;

CREATE VIEW rbt.landcover_labels_z4 AS
SELECT
    osm_id,
    name,
    name_en,
    subclass,
    intermittent,
    leaf_type,
    leaf_cycle,
    area,
    geometry
FROM rbt.landcover_labels
WHERE area >= 15625000 
  AND subclass IN ('sand', 'dune', 'dune_system', 'beach');

CREATE VIEW rbt.landcover_labels_z6 AS
SELECT
    osm_id,
    name,
    name_en,
    subclass,
    intermittent,
    leaf_type,
    leaf_cycle,
    area,
    geometry
FROM rbt.landcover_labels
WHERE area >= 15625000 
  AND subclass IN ('sand', 'dune', 'dune_system', 'beach', 'bog', 'mangrove', 
                   'marsh', 'reedbed', 'rice', 'saltmarsh', 'swamp', 
                   'unknown_wetland', 'wetland', 'paddy', 'wet_meadow');

CREATE VIEW rbt.landcover_labels_z9 AS
SELECT
    osm_id,
    name,
    name_en,
    subclass,
    intermittent,
    leaf_type,
    leaf_cycle,
    area,
    geometry
FROM rbt.landcover_labels
WHERE subclass IN ('sand', 'dune', 'dune_system', 'beach', 'bog', 'mangrove', 
                   'marsh', 'reedbed', 'rice', 'paddy', 'saltmarsh', 'swamp', 
                   'unknown_wetland', 'wetland', 'wet_meadow');

CREATE VIEW rbt.landcover_labels_z10 AS
SELECT
    osm_id,
    name,
    name_en,
    subclass,
    intermittent,
    leaf_type,
    leaf_cycle,
    area,
    geometry
FROM rbt.landcover_labels
WHERE subclass IN ('sand', 'dune', 'dune_system', 'beach', 'bog', 'mangrove', 
                   'marsh', 'reedbed', 'rice', 'saltmarsh', 'swamp', 
                   'unknown_wetland', 'wetland', 'wet_meadow', 'meadow', 
                   'grassland', 'forest', 'wood', 'tundra', 'reef', 'scrub', 
                   'heath', 'farm', 'farmland', 'orchard', 'paddy', 'vineyard');

\echo 'Landcover label views created successfully'

-- Commit all views to ensure they persist even if analysis or validation fails
COMMIT;
\echo 'All landcover views committed successfully'

-- Start new transaction for analysis and validation
BEGIN;

-- ==============================================================================
-- STEP 8: ANALYZE TABLES FOR OPTIMAL QUERY PLANNING
-- ==============================================================================

\echo 'Analyzing landcover tables for optimal query planning...'

-- Analyze materialized view
ANALYZE rbt.landcover;

-- Analyze source table
ANALYZE import.landcover;

\echo 'Landcover table analysis completed'

-- ==============================================================================
-- STEP 9: FINAL VALIDATION AND COMMIT
-- ==============================================================================

\echo 'Performing final landcover validation...'

DO $$
DECLARE
    rec RECORD;
    error_count INTEGER := 0;
BEGIN
    -- Validate that landcover materialized view was created successfully
    IF NOT EXISTS (
        SELECT 1 FROM pg_matviews 
        WHERE schemaname = 'rbt' 
        AND matviewname = 'landcover'
    ) THEN
        RAISE WARNING 'Materialized view rbt.landcover was not created successfully';
        error_count := error_count + 1;
    END IF;
    
    -- Check row counts for landcover materialized view
    EXECUTE 'SELECT COUNT(*) FROM rbt.landcover' INTO rec;
    IF rec.count = 0 THEN
        RAISE WARNING 'Materialized view rbt.landcover has no rows';
        error_count := error_count + 1;
    ELSE
        RAISE NOTICE 'Materialized view rbt.landcover has % rows', rec.count;
    END IF;
    
    IF error_count > 0 THEN
        RAISE EXCEPTION 'Landcover layer processing completed with % errors. Review warnings above.', error_count;
    ELSE
        RAISE NOTICE 'Landcover materialized view created successfully and validated';
    END IF;
END $$;

\echo 'Final landcover validation completed successfully'

-- Commit transaction
COMMIT;

\echo '=============================================================================='
\echo 'LANDCOVER LAYER PROCESSING COMPLETED SUCCESSFULLY'
\echo 'Landcover script execution finished with optimizations:'
\echo '- Created landcover materialized view for optimal performance'
\echo '- Added comprehensive indexes for fast landcover queries'
\echo '- Implemented transaction management with intermediate commits'
\echo '- Added dependency validation for reliable CI/CD execution'
\echo '- Created zoom-level and label views for tile generation'
\echo '- Uses checkpoint commits to preserve work if later steps fail'
\echo '=============================================================================='

-- Disable timing
\timing off
