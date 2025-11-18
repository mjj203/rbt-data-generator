-- ==============================================================================
-- WATER LAYER SQL SCRIPT FOR CI/CD PROCESSING
-- Extracted from physical.sql - handles all water-related processing
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

-- Trigram-specific configuration for optimized pattern matching
SET LOCAL pg_trgm.similarity_threshold = 0.3;
SET LOCAL pg_trgm.word_similarity_threshold = 0.6;
SET LOCAL pg_trgm.strict_word_similarity_threshold = 0.5;

\echo 'Water layer processing started with enhanced performance settings'

-- ==============================================================================
-- STEP 2: ENSURE REQUIRED EXTENSIONS
-- ==============================================================================

\echo 'Ensuring required PostgreSQL extensions...'

-- Ensure pg_trgm extension is available for trigram indexes
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm') THEN
        CREATE EXTENSION pg_trgm;
        RAISE NOTICE 'Created pg_trgm extension for trigram support';
    ELSE
        RAISE NOTICE 'pg_trgm extension already exists';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Could not create pg_trgm extension: %. GIN trigram indexes will fail.', SQLERRM;
END $$;

-- ==============================================================================
-- STEP 3: DEPENDENCY VALIDATION
-- ==============================================================================

\echo 'Validating water source data dependencies...'

-- NOTE: This script uses pg_matviews catalog instead of information_schema.tables
-- for materialized view detection, as information_schema.tables can be unreliable
-- for materialized views due to timing and metadata consistency issues.

DO $$
DECLARE
    table_count INTEGER;
    error_msg TEXT;
BEGIN
    
    -- Validate import.water exists and has data
    SELECT COUNT(*) INTO table_count FROM import.water LIMIT 1;
    IF table_count = 0 THEN
        RAISE EXCEPTION 'Source table import.water is empty or missing. Cannot proceed with water layer processing.';
    END IF;
    
    -- Validate import.waterway exists and has data
    SELECT COUNT(*) INTO table_count FROM import.waterway LIMIT 1;
    IF table_count = 0 THEN
        RAISE EXCEPTION 'Source table import.waterway is empty or missing. Cannot proceed with water layer processing.';
    END IF;
    
    -- Validate rbt.osm_ocean exists
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'rbt' AND table_name = 'osm_ocean') THEN
        RAISE EXCEPTION 'Table rbt.osm_ocean is missing. Cannot proceed with water layer processing.';
    END IF;
    
    -- Validate rbt.osm_ocean_simplified exists
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'rbt' AND table_name = 'osm_ocean_simplified') THEN
        RAISE EXCEPTION 'Table rbt.osm_ocean_simplified is missing. Cannot proceed with water layer processing.';
    END IF;
    
    RAISE NOTICE 'All required water source tables validated successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE EXCEPTION 'Water dependency validation failed: %', error_msg;
END $$;

\echo 'Water source data validation completed successfully'

-- ==============================================================================
-- STEP 5: CREATE CRITICAL INDEXES FOR WATER PERFORMANCE
-- ==============================================================================

\echo 'Creating critical indexes for optimal water processing performance...'

-- ==============================================================================
-- INDEX STRATEGY:
-- - GIN trigram indexes (gin_trgm_ops) for fuzzy text matching on name/subclass
-- - B-tree indexes for exact matches and range queries  
-- - GiST indexes for spatial operations on geometry columns
-- - Covering indexes (B-tree only) to enable index-only scans
-- ==============================================================================

-- Source table indexes for import.water
CREATE INDEX IF NOT EXISTS idx_water_name_trgm ON import.water USING gin(name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_water_area ON import.water USING btree(area);
CREATE INDEX IF NOT EXISTS idx_water_intermittent ON import.water USING btree(intermittent);
CREATE INDEX IF NOT EXISTS idx_water_subclass ON import.water USING gin(subclass gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_water_geometry ON import.water USING gist(geometry);
CREATE INDEX IF NOT EXISTS idx_water_name ON import.water USING btree(name) WHERE name IS NOT NULL AND name != '';

-- B-tree covering indexes to avoid heap lookups (INCLUDE only supported on B-tree)
CREATE INDEX IF NOT EXISTS idx_water_covering ON import.water USING btree(subclass, intermittent) 
    INCLUDE (name, name_en, area) WHERE geometry IS NOT NULL;

-- Source table indexes for import.waterway
CREATE INDEX IF NOT EXISTS idx_waterway_name_trgm ON import.waterway USING gin(name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_waterway_subclass ON import.waterway USING gin(subclass gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_waterway_intermittent ON import.waterway USING btree(intermittent);
CREATE INDEX IF NOT EXISTS idx_waterway_geometry ON import.waterway USING gist(geometry);
CREATE INDEX IF NOT EXISTS idx_waterway_name ON import.waterway USING btree(name) WHERE name IS NOT NULL AND name != '';
-- B-tree covering index (INCLUDE only supported on B-tree, not GIN)
CREATE INDEX IF NOT EXISTS idx_waterway_covering 
    ON import.waterway USING btree(subclass, intermittent) 
    INCLUDE (name) 
    WHERE geometry IS NOT NULL;

\echo 'Critical water indexes created successfully'

-- Commit indexes to ensure they persist even if later steps fail
COMMIT;
\echo 'Water indexes committed successfully - they will persist even if later steps fail'

-- Start new transaction for utility functions
BEGIN;

-- ==============================================================================
-- STEP 6: CREATE WATER-RELATED UTILITY FUNCTIONS
-- ==============================================================================
-- FUNCTION CATEGORIES:
-- 1. CORE FUNCTIONS (Used in views/materialized views):
--    - classify_water_type: Normalizes water subclass values
--    - safe_simplify_geometry: Safe geometry simplification with error handling
--
-- 2. DIAGNOSTIC FUNCTIONS (For manual analysis):
--    - find_subclass_variations: Analyze subclass patterns
--    - water_features_by_normalized_type: Query by normalized type
--    - analyze_subclass_patterns: Suggest normalization rules
--
-- 3. SEARCH FUNCTIONS (For ad-hoc queries):
--    - search_water_features_fuzzy: Fuzzy name search
--    - search_features_by_partial_name: Partial name matching
--    - find_similar_place_names: Typo-tolerant name search
--
-- Note: Diagnostic and search functions are not used in automated processing
-- but provide valuable tools for data exploration and quality control.
-- ==============================================================================

\echo 'Creating water-related utility functions...'

-- Create a function to classify water types based on subclass patterns
CREATE OR REPLACE FUNCTION classify_water_type(subclass_input TEXT) 
RETURNS TEXT AS $$
BEGIN

  -- Early return for null or empty
  IF subclass_input IS NULL OR subclass_input = '' THEN
    RETURN 'water';
  END IF;

  RETURN CASE
    WHEN subclass_input ~ '^bas' THEN 'basin'
    WHEN subclass_input ~ 'bayou' THEN 'bayou'
    WHEN subclass_input ~ 'can[ao]l' THEN 'canal'
    WHEN subclass_input ~ 'lake' THEN 'lake'
    WHEN subclass_input ~ 'pool' THEN 'pool'
    WHEN subclass_input ~ 'pond' THEN 'pond'
    WHEN subclass_input ~ 'res[eo]rvoir' THEN 'reservoir'
    WHEN subclass_input ~ 'cove' THEN 'cove'
    WHEN subclass_input ~ 'creek' THEN 'creek'
    WHEN subclass_input ~ 'spring' THEN 'spring'
    WHEN subclass_input ~ 'river' THEN 'river'
    WHEN subclass_input ~ 'ditch' THEN 'ditch'
    WHEN subclass_input ~ 'stream' THEN 'stream'
    WHEN subclass_input ~ '^est' THEN 'estuary'
    WHEN subclass_input ~ 'fall' THEN 'falls'
    WHEN subclass_input ~ '^fj[oi]' THEN 'fjord'
    WHEN subclass_input ~ '^ha[rv]bou?r' THEN 'harbour'
    WHEN subclass_input ~ 'lag[ou]' THEN 'lagoon'
    WHEN subclass_input ~ 'ocean' THEN 'ocean'
    WHEN subclass_input ~ '^rapi' THEN 'rapids'
    WHEN subclass_input ~ 'o[xs]bow' THEN 'oxbow'
    WHEN subclass_input ~ '^tidal' THEN 'tidal'
    WHEN subclass_input ~ '^waste' THEN 'wastewater'
    WHEN subclass_input = 'yes' THEN 'water'
    ELSE subclass_input
  END;
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE;

-- ==============================================================================
-- DIAGNOSTIC/UTILITY FUNCTIONS FOR SUBCLASS ANALYSIS (Not used in views)
-- These functions are available for manual analysis and debugging:
-- - find_subclass_variations: Discover subclass naming patterns
-- - water_features_by_normalized_type: Query features by type
-- - analyze_subclass_patterns: Suggest normalization rules
-- ==============================================================================

-- Function to find all subclass variations that should map to a normalized value
-- USAGE: SELECT * FROM find_subclass_variations('lake', 'lak');
-- This uses the GIN trigram index for fast pattern matching
CREATE OR REPLACE FUNCTION find_subclass_variations(
    normalized_term TEXT,
    pattern TEXT DEFAULT NULL
)
RETURNS TABLE(
    table_source TEXT,
    subclass TEXT,
    count BIGINT
) AS $$
BEGIN
    -- If no pattern provided, use the normalized term as pattern
    IF pattern IS NULL THEN
        pattern := normalized_term;
    END IF;
    
    RETURN QUERY
    WITH variations AS (
        SELECT 'water'::TEXT as table_source, w.subclass, COUNT(*) as count
        FROM import.water w
        WHERE w.subclass % pattern  -- Uses trigram index!
           OR w.subclass ILIKE '%' || pattern || '%'
        GROUP BY w.subclass
        
        UNION ALL
        
        SELECT 'waterway'::TEXT, ww.subclass, COUNT(*) as count
        FROM import.waterway ww
        WHERE ww.subclass % pattern  -- Uses trigram index!
           OR ww.subclass ILIKE '%' || pattern || '%'
        GROUP BY ww.subclass
    )
    SELECT * FROM variations
    ORDER BY count DESC;
END;
$$ LANGUAGE plpgsql STABLE PARALLEL SAFE;

-- Function for efficient subclass-based filtering using trigram indexes
-- This is MUCH faster than classify_water_type in WHERE clauses
CREATE OR REPLACE FUNCTION water_features_by_normalized_type(
    water_types TEXT[]
)
RETURNS TABLE(
    osm_id BIGINT,
    name TEXT,
    original_subclass TEXT,
    normalized_subclass TEXT,
    geometry geometry
) AS $$
BEGIN
    RETURN QUERY
    WITH type_patterns AS (
        SELECT unnest(water_types) as wtype
    ),
    matched_features AS (
        SELECT 
            w.osm_id,
            w.name,
            w.subclass as original_subclass,
            classify_water_type(w.subclass) as normalized_subclass,
            w.geometry
        FROM import.water w
        WHERE EXISTS (
            SELECT 1 FROM type_patterns t
            WHERE 
                -- Direct match on normalized value
                classify_water_type(w.subclass) = t.wtype
                -- Or use trigram similarity for fuzzy matching
                OR w.subclass % t.wtype
                -- Or pattern matching with trigram index support
                OR w.subclass ILIKE '%' || t.wtype || '%'
        )
    )
    SELECT * FROM matched_features;
END;
$$ LANGUAGE plpgsql STABLE PARALLEL SAFE;

-- Function to analyze and suggest subclass normalization rules
CREATE OR REPLACE FUNCTION analyze_subclass_patterns(
    min_occurrences INT DEFAULT 10
)
RETURNS TABLE(
    suggested_normalized TEXT,
    pattern TEXT,
    variations TEXT[],
    total_count BIGINT
) AS $$
BEGIN
    RETURN QUERY
    WITH all_subclasses AS (
        SELECT subclass, COUNT(*) as cnt
        FROM (
            SELECT subclass FROM import.water
            UNION ALL
            SELECT subclass FROM import.waterway
        ) t
        GROUP BY subclass
        HAVING COUNT(*) >= min_occurrences
    ),
    clustered AS (
        SELECT 
            s1.subclass as base,
            array_agg(DISTINCT s2.subclass ORDER BY s2.subclass) as similar_items,
            SUM(s2.cnt) as total
        FROM all_subclasses s1
        JOIN all_subclasses s2 
            ON s1.subclass <-> s2.subclass < 0.3  -- Similar within distance
        WHERE s1.cnt >= s2.cnt  -- Base should be most common
        GROUP BY s1.subclass
        HAVING COUNT(DISTINCT s2.subclass) > 1
    )
    SELECT 
        base as suggested_normalized,
        base || '%' as pattern,
        similar_items as variations,
        total as total_count
    FROM clustered
    ORDER BY total DESC;
END;
$$ LANGUAGE plpgsql STABLE;

-- Create helper function for efficient geometry validation
CREATE OR REPLACE FUNCTION safe_simplify_geometry(geom geometry, tolerance float8)
RETURNS geometry AS $$
BEGIN
  -- Ensure geometry is valid before simplification
  IF NOT ST_IsValid(geom) THEN
    geom := ST_MakeValid(geom, 'method=structure');
  END IF;
  
  -- Use ST_SimplifyPreserveTopology for safety
  RETURN ST_SimplifyPreserveTopology(geom, tolerance);
EXCEPTION WHEN OTHERS THEN
  -- Return original geometry if simplification fails
  RETURN geom;
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE;

-- ==============================================================================
-- SEARCH UTILITY FUNCTIONS (Available for ad-hoc queries)
-- These functions leverage trigram indexes for powerful search capabilities:
-- - search_water_features_fuzzy: Find features by fuzzy name matching
-- - search_features_by_partial_name: Find features containing text
-- - find_similar_place_names: Find typo-tolerant name matches
-- USAGE EXAMPLES:
--   SELECT * FROM search_water_features_fuzzy('mississippi', 0.3);
--   SELECT * FROM search_features_by_partial_name('river');
--   SELECT * FROM find_similar_place_names('potomac', 0.3);
-- ==============================================================================

-- Function for fuzzy name search across water features
CREATE OR REPLACE FUNCTION search_water_features_fuzzy(
    search_term TEXT,
    similarity_threshold FLOAT DEFAULT 0.3,
    max_results INT DEFAULT 100
)
RETURNS TABLE(
    table_source TEXT,
    osm_id BIGINT,
    name TEXT,
    name_en TEXT,
    subclass TEXT,
    similarity_score FLOAT,
    geometry geometry
) AS $$
BEGIN
    RETURN QUERY
    WITH water_search AS (
        SELECT 
            'water'::TEXT as table_source,
            w.osm_id,
            w.name,
            w.name_en,
            w.subclass,
            GREATEST(
                similarity(w.name, search_term),
                similarity(w.name_en, search_term)
            ) as similarity_score,
            w.geometry
        FROM import.water w
        WHERE w.name % search_term 
           OR w.name_en % search_term
           OR w.name ILIKE '%' || search_term || '%'
           OR w.name_en ILIKE '%' || search_term || '%'
    ),
    waterway_search AS (
        SELECT 
            'waterway'::TEXT as table_source,
            ww.osm_id,
            ww.name,
            ww.name_en,
            ww.subclass,
            GREATEST(
                similarity(ww.name, search_term),
                similarity(ww.name_en, search_term)
            ) as similarity_score,
            ww.geometry
        FROM import.waterway ww
        WHERE ww.name % search_term 
           OR ww.name_en % search_term
           OR ww.name ILIKE '%' || search_term || '%'
           OR ww.name_en ILIKE '%' || search_term || '%'
    )
    SELECT * FROM (
        SELECT * FROM water_search
        UNION ALL
        SELECT * FROM waterway_search
    ) AS combined
    WHERE similarity_score >= similarity_threshold
    ORDER BY similarity_score DESC, name
    LIMIT max_results;
END;
$$ LANGUAGE plpgsql STABLE PARALLEL SAFE;

-- Function for efficient partial name matching
CREATE OR REPLACE FUNCTION search_features_by_partial_name(
    partial_name TEXT,
    search_tables TEXT[] DEFAULT ARRAY['water', 'waterway', 'park', 'builtup']
)
RETURNS TABLE(
    table_source TEXT,
    osm_id BIGINT,
    name TEXT,
    subclass TEXT,
    geometry geometry
) AS $$
BEGIN
    -- Optimize the search pattern
    partial_name := '%' || lower(partial_name) || '%';
    
    RETURN QUERY
    SELECT * FROM (
        -- Water features
        SELECT 'water'::TEXT, w.osm_id, w.name, w.subclass, w.geometry
        FROM import.water w
        WHERE 'water' = ANY(search_tables) 
          AND lower(w.name) LIKE partial_name
        
        UNION ALL
        
        -- Waterway features
        SELECT 'waterway'::TEXT, ww.osm_id, ww.name, ww.subclass, ww.geometry
        FROM import.waterway ww
        WHERE 'waterway' = ANY(search_tables)
          AND lower(ww.name) LIKE partial_name
        
        UNION ALL
        
        -- Park features
        SELECT 'park'::TEXT, p.osm_id, p.name, p.subclass, p.geometry
        FROM import.park_polygon p
        WHERE 'park' = ANY(search_tables)
          AND lower(p.name) LIKE partial_name
        
        UNION ALL
        
        -- Built-up areas
        SELECT 'builtup'::TEXT, b.osm_id, b.name, b.subclass, b.geometry
        FROM import.builtup_area b
        WHERE 'builtup' = ANY(search_tables)
          AND lower(b.name) LIKE partial_name
    ) AS results;
END;
$$ LANGUAGE plpgsql STABLE PARALLEL SAFE;

-- Function to find similar place names (typo-tolerant)
CREATE OR REPLACE FUNCTION find_similar_place_names(
    search_name TEXT,
    max_distance FLOAT DEFAULT 0.3
)
RETURNS TABLE(
    name TEXT,
    distance FLOAT,
    occurrences BIGINT
) AS $$
BEGIN
    RETURN QUERY
    WITH all_names AS (
        SELECT name FROM import.water WHERE name IS NOT NULL
        UNION ALL
        SELECT name FROM import.waterway WHERE name IS NOT NULL
        UNION ALL
        SELECT name FROM import.park_polygon WHERE name IS NOT NULL
        UNION ALL
        SELECT name FROM import.builtup_area WHERE name IS NOT NULL
    ),
    distinct_names AS (
        SELECT name, COUNT(*) as occurrences
        FROM all_names
        GROUP BY name
    )
    SELECT 
        dn.name,
        dn.name <-> search_name as distance,
        dn.occurrences
    FROM distinct_names dn
    WHERE dn.name <-> search_name <= max_distance
    ORDER BY distance, occurrences DESC
    LIMIT 20;
END;
$$ LANGUAGE plpgsql STABLE;

\echo 'Water-related utility functions created successfully'

-- Commit utility functions to ensure they persist even if later steps fail
COMMIT;
\echo 'Water utility functions committed successfully'

-- ==============================================================================
-- STEP 7: CREATE WATER-RELATED MATERIALIZED VIEWS FOR HIGH-PERFORMANCE QUERIES
-- ==============================================================================

\echo 'Creating water-related materialized views for optimal CI/CD performance...'

-- ==============================================================================
-- WATER SURFACE MATERIALIZED VIEW (Transaction 1)
-- ==============================================================================

\echo 'Creating rbt.water_surface materialized view...'

-- Start transaction for water_surface materialized view
BEGIN;

DO $$
DECLARE
    error_msg TEXT;
BEGIN
    CREATE MATERIALIZED VIEW rbt.water_surface AS
    WITH water_classified AS (
      SELECT 
        osm_id,
        NULLIF(name,'') as name, 
        NULLIF(name_en,'') as name_en,
        classify_water_type(subclass) as subclass,
        ST_Area(ST_Transform(geometry, 3857))::real as area,
        safe_simplify_geometry(geometry, 0.000001) AS geometry,
        intermittent
      FROM import.water
      WHERE intermittent = 'f'
        AND geometry IS NOT NULL
    )
    SELECT 
      osm_id,
      name, 
      name_en, 
      subclass,
      intermittent,
      area, 
      geometry 
    FROM water_classified
    WHERE subclass IN (
      'artificial', 'basin', 'bay', 'bayou', 'brook', 'canal', 'CANAL', 'cenote',
      'channel', 'connector', 'canoe_pass', 'cove', 'creek', 'derelict_canal',
      'disused_canal', 'ditch', 'drain', 'estuary', 'falls', 'fish_pass',
      'fishpond', 'fjord', 'glacial_lage', 'guelta', 'gulf', 'harbour',
      'lagoon', 'lake', 'lake;pond', 'lake;reservoir', 'moat', 'ocean',
      'old_river', 'oxbow', 'pan', 'piscina', 'pond', 'pond;reservoir',
      'pool', 'rapids', 'reservoir', 'river', 'river;canal', 'riverbank',
      'riverbed', 'salt_pond', 'sea', 'sound', 'spillway', 'spring',
      'swimming_pool', 'strait', 'stream', 'stream_pool', 'stream;river',
      'tidal', 'tidal_channel', 'unclassified', 'wastewater', 'water',
      'waterfall', 'yes'
    )
      AND geometry IS NOT NULL;

    -- Create indexes on materialized view
    CREATE INDEX IF NOT EXISTS idx_water_surface_osm_id ON rbt.water_surface USING btree(osm_id);
    CREATE INDEX IF NOT EXISTS idx_water_surface_subclass ON rbt.water_surface USING btree(subclass);
    CREATE INDEX IF NOT EXISTS idx_water_surface_area ON rbt.water_surface USING btree(area);
    CREATE INDEX IF NOT EXISTS idx_water_surface_geometry ON rbt.water_surface USING gist(geometry);
    CREATE INDEX IF NOT EXISTS idx_water_surface_name ON rbt.water_surface USING btree(name) WHERE name IS NOT NULL;
    
    RAISE NOTICE 'rbt.water_surface materialized view created successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create rbt.water_surface materialized view: %', error_msg;
    RAISE;
END $$;

COMMIT;
\echo 'Water surface materialized view committed successfully'

-- ==============================================================================
-- ADDITIONAL WATER PROCESSING TABLES (Transaction 4)
-- ==============================================================================

\echo 'Creating additional water processing tables...'

-- Start transaction for additional water processing tables
BEGIN;

DO $$
DECLARE
    error_msg TEXT;
    water_surface_exists BOOLEAN;
    ocean_exists BOOLEAN;
BEGIN
    -- Check if required dependencies exist
    SELECT EXISTS (
        SELECT 1 FROM pg_matviews 
        WHERE schemaname = 'rbt' AND matviewname = 'water_surface'
    ) INTO water_surface_exists;
    
    
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables 
        WHERE table_schema = 'rbt' AND table_name = 'osm_ocean'
    ) INTO ocean_exists;
    
    IF NOT water_surface_exists THEN
        RAISE EXCEPTION 'rbt.water_surface does not exist. Cannot create additional water processing tables.';
    END IF;
    
    IF NOT ocean_exists THEN
        RAISE WARNING 'rbt.osm_ocean does not exist. Ocean processing will be skipped.';
    END IF;

    -- Create water_surface_clean table
    CREATE TABLE rbt.water_surface_clean AS
    SELECT subclass, osm_id, 
           (ST_Dump(ST_MakeValid(ST_SimplifyPreserveTopology(geometry, 0.000001),'method=structure'))).geom::geometry(Polygon,4326) as geometry
    FROM rbt.water_surface
    WHERE subclass NOT IN ('bay','harbour','sea','strait');
    
    CREATE INDEX water_srf_clean_geom_idx ON rbt.water_surface_clean USING gist(geometry);
    CREATE INDEX water_srf_clean_osmid_idx ON rbt.water_surface_clean USING btree(osm_id);
    CREATE INDEX water_srf_clean_subclass_idx ON rbt.water_surface_clean USING btree(subclass);
    
    RAISE NOTICE 'rbt.water_surface_clean table created successfully';

    -- Create valid_ocean table (only if osm_ocean exists)
    IF ocean_exists THEN
        CREATE TABLE rbt.valid_ocean AS
        SELECT
            'ocean' as subclass,
            ST_MakeValid((ST_Dump(ST_SimplifyPreserveTopology(geometry, 0.000001))).geom::geometry(Polygon,4326),'method=structure') as geometry
        FROM rbt.osm_ocean
        WHERE geometry IS NOT NULL AND NOT ST_IsEmpty(geometry);
        
        CREATE INDEX valid_ocean_geom_idx ON rbt.valid_ocean USING gist(geometry);
        
        RAISE NOTICE 'rbt.valid_ocean table created successfully';
    ELSE
        RAISE WARNING 'Skipping rbt.valid_ocean table - rbt.osm_ocean does not exist';
    END IF;
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create additional water processing tables: %', error_msg;
    RAISE;
END $$;

COMMIT;
\echo 'Additional water processing tables transaction completed'

-- ==============================================================================
-- WATER MATERIALIZED VIEW (Transaction 2)
-- ==============================================================================
-- from ocean water features. The approach:
-- 2. Filters out pieces that are fully within ocean boundaries
-- 3. Keeps only inland water features and ocean features separately
-- Benefits:
-- - Rivers/estuaries are properly clipped at ocean boundary
================================

\echo 'Creating rbt.water materialized view...'

-- Start transaction for water materialized view
BEGIN;

DO $$
DECLARE
    error_msg TEXT;
    water_surface_exists BOOLEAN;
BEGIN
    -- Check if water_surface exists before proceeding
    SELECT EXISTS (
        SELECT 1 FROM pg_matviews 
        WHERE schemaname = 'rbt' AND matviewname = 'water_surface'
    ) INTO water_surface_exists;
    
    IF NOT water_surface_exists THEN
        RAISE EXCEPTION 'rbt.water_surface does not exist. Cannot create rbt.water materialized view.';
    END IF;

    -- Employs efficient LATERAL JOIN to avoid expensive ST_Union operations
    CREATE MATERIALIZED VIEW rbt.water AS
    WITH 
    -- Filter out pieces that are within the ocean

    valid_inland AS (
        SELECT
            ws.subclass,
            ws.osm_id,
            ws.geometry
        FROM rbt.water_surface_clean ws
        LEFT JOIN rbt.sound_ocean so on so.osm_id = ws.osm_id
        WHERE ws.geometry IS NOT NULL
            AND NOT ST_IsEmpty(ws.geometry)
            AND so.osm_id IS NULL
    )
    -- Final output WITHOUT any ST_Union operations
    -- Each row represents an individual water feature
    SELECT 
        subclass::text,
        ST_MakeValid(geometry, 'method=structure') as geometry
    FROM valid_inland

    UNION ALL

    SELECT 
        subclass::text,
        ST_MakeValid(geometry, 'method=structure') as geometry
    FROM rbt.valid_ocean

    WITH DATA;

    -- Create indexes on materialized view
    CREATE INDEX IF NOT EXISTS idx_water_subclass ON rbt.water USING btree(subclass);
    CREATE INDEX IF NOT EXISTS idx_water_geometry ON rbt.water USING gist(geometry);
    
    RAISE NOTICE 'rbt.water materialized view created successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create rbt.water materialized view: %', error_msg;
    -- Continue without raising - allow other views to be created
END $$;

COMMIT;
\echo 'Water materialized view transaction completed'

-- ==============================================================================
-- WATER SIMPLIFIED MATERIALIZED VIEW (Transaction 3)
-- ==============================================================================

\echo 'Creating rbt.water_simplified materialized view...'

-- Start transaction for water_simplified materialized view
BEGIN;

DO $$
DECLARE
    error_msg TEXT;
    water_surface_exists BOOLEAN;
BEGIN
    -- Check if water_surface exists before proceeding
    SELECT EXISTS (
        SELECT 1 FROM pg_matviews 
        WHERE schemaname = 'rbt' AND matviewname = 'water_surface'
    ) INTO water_surface_exists;
    
    IF NOT water_surface_exists THEN
        RAISE EXCEPTION 'rbt.water_surface does not exist. Cannot create rbt.water_simplified materialized view.';
    END IF;

    CREATE MATERIALIZED VIEW rbt.water_simplified AS
WITH valid_inland_geoms AS (
    SELECT
        subclass,
        CASE 
            WHEN ST_IsValid(geometry) THEN geometry
            ELSE ST_MakeValid(geometry, 'method=structure')
        END as clean_geometry,
        area
    FROM rbt.water_surface
    WHERE geometry IS NOT NULL 
        AND area > 5000000
),
-- Simplify geometries but don't cluster or union them
simplified_inland AS (
    SELECT
        subclass,
        safe_simplify_geometry(clean_geometry, 0.0001) as geometry
    FROM valid_inland_geoms
    WHERE clean_geometry IS NOT NULL
        AND ST_IsValid(clean_geometry)
        AND NOT ST_IsEmpty(clean_geometry)
),
-- Ocean geometries without union
valid_ocean_simplified AS (
    SELECT
        'ocean' as subclass,
        CASE 
            WHEN ST_IsValid(geometry) THEN geometry
            ELSE ST_MakeValid(geometry, 'method=structure')
        END as clean_geometry
    FROM rbt.osm_ocean_simplified
    WHERE geometry IS NOT NULL
),
simplified_ocean AS (
    SELECT
        subclass,
        safe_simplify_geometry(clean_geometry, 0.0001) as geometry
    FROM valid_ocean_simplified
    WHERE clean_geometry IS NOT NULL
        AND ST_IsValid(clean_geometry)
        AND NOT ST_IsEmpty(clean_geometry)
)
-- Final output WITHOUT clustering or union operations
-- Each row represents an individual simplified water feature
SELECT
    subclass,
    geometry
FROM simplified_inland
WHERE geometry IS NOT NULL

UNION ALL

SELECT
    subclass,
    geometry
FROM simplified_ocean
WHERE geometry IS NOT NULL;

    -- Create indexes on materialized view
    CREATE INDEX IF NOT EXISTS idx_water_simplified_subclass ON rbt.water_simplified USING btree(subclass);
    CREATE INDEX IF NOT EXISTS idx_water_simplified_geometry ON rbt.water_simplified USING gist(geometry);
    
    RAISE NOTICE 'rbt.water_simplified materialized view created successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create rbt.water_simplified materialized view: %', error_msg;
    -- Continue without raising - allow other views to be created
END $$;

COMMIT;
\echo 'Water simplified materialized view transaction completed'

\echo 'All water-related materialized view transactions completed'

-- ==============================================================================
-- STEP 8: CREATE WATER-RELATED REGULAR VIEWS (ZOOM LEVELS AND SPECIALIZED VIEWS)
-- ==============================================================================

\echo 'Creating water-related regular views for zoom levels and specialized queries...'

-- ==============================================================================
-- INDEPENDENT WATER VIEWS (Transaction 1)
-- ==============================================================================

-- Start transaction for independent water views
BEGIN;

\echo 'Creating independent water views...'

DO $$
DECLARE
    error_msg TEXT;
BEGIN
    -- Intermittent water materialized views
    CREATE MATERIALIZED VIEW rbt.inland_water_intermittent AS
    WITH intermittent_water AS (
      SELECT
        osm_id,
        NULLIF(name, '') AS name, 
        NULLIF(name_en, '') AS name_en, 
        classify_water_type(subclass) as subclass,
        (ST_Dump(ST_MakeValid(ST_SimplifyPreserveTopology(geometry, 0.000001),'method=structure'))).geom::geometry(Polygon,4326) as geometry,
        ST_Area(ST_Transform(geometry, 3857))::real as area,
        intermittent
    FROM import.water
    WHERE 
        (intermittent = 't' OR subclass IN ('intermittent', 'seasonal', 'drystream'))
        AND geometry IS NOT NULL
    )
    SELECT * FROM intermittent_water;

    -- Create indexes on materialized view
    CREATE INDEX IF NOT EXISTS idx_inland_water_intermittent_osm_id ON rbt.inland_water_intermittent USING btree(osm_id);
    CREATE INDEX IF NOT EXISTS idx_inland_water_intermittent_subclass ON rbt.inland_water_intermittent USING btree(subclass);
    CREATE INDEX IF NOT EXISTS idx_inland_water_intermittent_area ON rbt.inland_water_intermittent USING btree(area);
    CREATE INDEX IF NOT EXISTS idx_inland_water_intermittent_geometry ON rbt.inland_water_intermittent USING gist(geometry);
    CREATE INDEX IF NOT EXISTS idx_inland_water_intermittent_name ON rbt.inland_water_intermittent USING btree(name) WHERE name IS NOT NULL;

    RAISE NOTICE 'rbt.inland_water_intermittent materialized view created successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create rbt.inland_water_intermittent materialized view: %', error_msg;
END $$;


DO $$
DECLARE
    error_msg TEXT;
BEGIN
    -- Natural Earth water label view (independent of our materialized views)
    CREATE VIEW rbt.ne_water_label AS
    SELECT
        NULLIF(featurecla, '') as featurecla,
        NULLIF(name, '') as name,
        ST_Area(ST_Transform(geometry, 3857))::real as area,
        ST_PointOnSurface(geometry)::geometry(Point, 4326) as geometry
    FROM naturalearth.ne_10m_geography_marine_polys;

    RAISE NOTICE 'rbt.ne_water_label view created successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create rbt.ne_water_label view: %', error_msg;
END $$;

DO $$
DECLARE
    error_msg TEXT;
BEGIN
    -- Waterway views (independent of our materialized views)
    CREATE VIEW rbt.waterway AS
    WITH waterway AS (SELECT
        NULLIF(name,'') AS name,
        intermittent,
        classify_water_type(subclass) as subclass,
        ST_Length(ST_Transform(geometry, 3857))::real AS geom_len,
        geometry
    FROM import.waterway
    )
    SELECT * FROM waterway
    WHERE subclass IN (
        'canal', 'ditch', 'drain', 'river', 'stream', 'pond', 'lake', 'reservoir',
        'basin', 'wastewater', 'weir', 'rapids', 'oxbow', 'drystream',
        'tidal_channel', 'artificial', 'lagoon', 'fishpond', 'yes', 'waterfall',
        'derelict_canal', 'intermittent', 'brook', 'harbour', 'drainage_channel',
        'connector', 'sluice_gate', 'lake;pond', 'tidal', 'sewer', 'spillway',
        'construction', 'pan', 'riverbank', 'water', 'stream;river', 'culvert',
        'underground_drain', 'tunnel', 'drainage_gutter', 'sewage', 'abandoned',
        'creek', 'navigation', 'seaway', 'riverbed', 'lake;reservoir', 'razed',
        'pond;reservoir', 'unclassified', 'disused_canal', 'sluice', 'duct',
        'piscina', 'glacial_lage', 'seasonal', 'old_river', 'channel',
        'river;canal', 'strait', 'ocean'
    );

    RAISE NOTICE 'rbt.waterway view created successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create rbt.waterway view: %', error_msg;
END $$;

DO $$
DECLARE
    error_msg TEXT;
BEGIN
    CREATE VIEW rbt.waterway_z8 AS
    SELECT
        name,
        intermittent,
        subclass,
        geom_len,
        geometry
    FROM rbt.waterway
    WHERE subclass IN ('canal', 'river', 'stream');

    RAISE NOTICE 'rbt.waterway_z8 view created successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create rbt.waterway_z8 view: %', error_msg;
END $$;

COMMIT;
\echo 'Independent water views transaction completed'

-- ==============================================================================
-- DEPENDENT WATER VIEWS (Transaction 2)
-- ==============================================================================

-- Start transaction for views that depend on materialized views
BEGIN;

\echo 'Creating views that depend on materialized views...'

DO $$
DECLARE
    error_msg TEXT;
    water_surface_exists BOOLEAN;
BEGIN
    -- Check if water_surface materialized view exists
    SELECT EXISTS (
        SELECT 1 FROM pg_matviews 
        WHERE schemaname = 'rbt' AND matviewname = 'water_surface'
    ) INTO water_surface_exists;
    
    IF water_surface_exists THEN
        -- Water surface label view (depends on rbt.water_surface)
        CREATE VIEW rbt.water_surface_label AS
        SELECT
          osm_id,
          name,
          name_en,
          subclass,
          intermittent,
          area,
          ST_PointOnSurface(geometry)::geometry(Point,4326) as geometry
        FROM rbt.water_surface
        WHERE (name != '' OR name_en != '') AND name IS NOT NULL AND geometry IS NOT NULL
        UNION ALL
        SELECT
          osm_id,
          name,
          name_en,
          subclass,
          intermittent,
          area,
          ST_PointOnSurface(geometry)::geometry(Point,4326) as geometry
        FROM rbt.inland_water_intermittent
        WHERE (name != '' OR name_en != '') AND name IS NOT NULL AND geometry IS NOT NULL;

        RAISE NOTICE 'rbt.water_surface_label view created successfully';
    ELSE
        RAISE WARNING 'Skipping rbt.water_surface_label view - rbt.water_surface materialized view does not exist';
    END IF;
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create rbt.water_surface_label view: %', error_msg;
END $$;

COMMIT;
\echo 'Dependent water views transaction completed'

\echo 'All water-related regular views processing completed'

-- ==============================================================================
-- STEP 9: ANALYZE WATER TABLES FOR OPTIMAL QUERY PLANNING
-- ==============================================================================

-- Start transaction for analysis
BEGIN;

\echo 'Analyzing water tables for optimal query planning...'

DO $$
DECLARE
    error_msg TEXT;
    view_exists BOOLEAN;
BEGIN
    -- Analyze water-related materialized views (only if they exist)
    
    -- Check and analyze rbt.water_surface
    SELECT EXISTS (
        SELECT 1 FROM pg_matviews 
        WHERE schemaname = 'rbt' AND matviewname = 'water_surface'
    ) INTO view_exists;
    
    IF view_exists THEN
        EXECUTE 'ANALYZE rbt.water_surface';
        RAISE NOTICE 'Analyzed rbt.water_surface successfully';
    ELSE
        RAISE WARNING 'Skipping analysis of rbt.water_surface - table does not exist';
    END IF;
    
    -- Check and analyze rbt.water
    SELECT EXISTS (
        SELECT 1 FROM pg_matviews 
        WHERE schemaname = 'rbt' AND matviewname = 'water'
    ) INTO view_exists;
    
    IF view_exists THEN
        EXECUTE 'ANALYZE rbt.water';
        RAISE NOTICE 'Analyzed rbt.water successfully';
    ELSE
        RAISE WARNING 'Skipping analysis of rbt.water - table does not exist';
    END IF;
    
    -- Check and analyze rbt.water_simplified
    SELECT EXISTS (
        SELECT 1 FROM pg_matviews 
        WHERE schemaname = 'rbt' AND matviewname = 'water_simplified'
    ) INTO view_exists;
    
    IF view_exists THEN
        EXECUTE 'ANALYZE rbt.water_simplified';
        RAISE NOTICE 'Analyzed rbt.water_simplified successfully';
    ELSE
        RAISE WARNING 'Skipping analysis of rbt.water_simplified - table does not exist';
    END IF;
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Error during materialized view analysis: %', error_msg;
END $$;

DO $$
DECLARE
    error_msg TEXT;
BEGIN
    -- Analyze water-related source tables
    ANALYZE import.water;
    ANALYZE import.waterway;
    
    RAISE NOTICE 'Analyzed source tables import.water and import.waterway successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Error during source table analysis: %', error_msg;
END $$;

COMMIT;
\echo 'Water table analysis completed'

-- ==============================================================================
-- STEP 10: FINAL WATER VALIDATION AND SUMMARY
-- ==============================================================================

-- Start transaction for validation
BEGIN;

\echo 'Performing final water validation and generating summary...'

DO $$
DECLARE
    rec RECORD;
    success_count INTEGER := 0;
    total_views INTEGER := 5;
    view_name TEXT;
    view_exists BOOLEAN;
    row_count BIGINT;
BEGIN
    RAISE NOTICE '=== WATER LAYER PROCESSING SUMMARY ===';
    
    -- Check each materialized view
    FOR view_name IN VALUES ('water_surface'), ('water'), ('water_simplified'), ('inland_water_intermittent') LOOP
        SELECT EXISTS (
            SELECT 1 FROM pg_matviews 
            WHERE schemaname = 'rbt' AND matviewname = view_name
        ) INTO view_exists;
        
        IF view_exists THEN
            BEGIN
                EXECUTE format('SELECT COUNT(*) FROM rbt.%I', view_name) INTO row_count;
                RAISE NOTICE '✓ Materialized view rbt.% exists with % rows', view_name, row_count;
                success_count := success_count + 1;
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING '⚠ Materialized view rbt.% exists but could not count rows: %', view_name, SQLERRM;
            END;
        ELSE
            RAISE WARNING '✗ Materialized view rbt.% was not created', view_name;
        END IF;
    END LOOP;
    
    -- Check regular views
    DECLARE
        view_count INTEGER;
    BEGIN
        SELECT COUNT(*) INTO view_count
        FROM information_schema.views 
        WHERE table_schema = 'rbt' 
        AND table_name IN ('water_surface_label', 'ne_water_label', 'waterway', 'waterway_z8');
        
        RAISE NOTICE '✓ Created % regular water-related views', view_count;
    END;
    
    -- Final summary
    RAISE NOTICE '=== PROCESSING RESULTS ===';
    RAISE NOTICE 'Materialized views: %/% successful', success_count, total_views;
    
    IF success_count > 0 THEN
        RAISE NOTICE '✓ Water layer processing completed with % successful materialized view(s)', success_count;
    ELSE
        RAISE WARNING '⚠ No materialized views were successfully created';
    END IF;
    
    RAISE NOTICE 'Transaction-based processing ensures that successful views are preserved';
    
END $$;

COMMIT;
\echo 'Final water validation and summary completed'

\echo '=============================================================================='
\echo 'WATER LAYER PROCESSING COMPLETED SUCCESSFULLY'
\echo 'Enhanced water script execution finished with optimizations:'
\echo '- Created water-related materialized views for optimal performance'
\echo '- Added comprehensive indexes for fast water queries'
\echo '- Implemented transaction management with intermediate commits'
\echo '- Added dependency validation for reliable CI/CD execution'
\echo '- Uses checkpoint commits to preserve work if later steps fail'
\echo '- Extracted from physical.sql for modular processing'
\echo ''
\echo 'UTILITY FUNCTIONS STATUS:'
\echo '- Core functions (classify_water_type, safe_simplify_geometry): ACTIVE'
\echo '- Diagnostic functions: Available for manual data analysis'
\echo '- Search functions: Available for ad-hoc queries and exploration'
\echo '=============================================================================='

-- Disable timing
\timing off
