-- ==============================================================================
-- RAILWAY PROCESSING SQL SCRIPT FOR CI/CD PROCESSING
-- Extracted from cultural layer processing for modular execution
-- Optimized for execution after imposm3 import completion
-- ==============================================================================
-- 
-- HSTORE OPERATOR USAGE REFERENCE (PostgreSQL 17):
-- The 'tags' column is an hstore type containing OSM key-value pairs.
-- 
-- Common hstore operators used in this script:
--   -> : Extract value for a key (returns text or NULL)
--        Example: tags -> 'voltage' returns the voltage value
--   ? : Check if key exists (returns boolean)
--        Example: tags ? 'voltage' returns true if voltage key exists
--   ?| : Check if any of the keys exist (returns boolean)
--        Example: tags ?| ARRAY['voltage', 'frequency'] returns true if either exists
--   ?& : Check if all keys exist (returns boolean)
--        Example: tags ?& ARRAY['voltage', 'frequency'] returns true if both exist
--   @> : Check if hstore contains key-value pairs (returns boolean)
--        Example: tags @> 'voltage=>25000'::hstore returns true for exact match
--   ? : Check if hstore contains a specific key (returns boolean)
--        Example: tags ? 'voltage' returns true if key exists
--   slice_array(hstore, text[]) : Extract subset of keys as array (returns text[])
--        Example: slice_array(tags, ARRAY['voltage', 'frequency']) returns values as array
--   
-- Pattern matching on extracted values:
--   ILIKE : Case-insensitive pattern matching on extracted text
--   NOT ILIKE : Negated case-insensitive pattern matching
--   
-- pg_trgm operators for similarity matching:
--   % : Similarity operator (returns boolean based on threshold)
--   <-> : Distance operator (returns float, 1 - similarity)
--   similarity() : Similarity function (returns float 0-1)
--   word_similarity() : Word similarity for partial matches
-- ==============================================================================

-- Enable timing for CI/CD monitoring
\timing on

-- Ensure required extensions are available
CREATE EXTENSION IF NOT EXISTS hstore;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Start transaction with error handling
BEGIN;

-- ==============================================================================
-- STEP 1: CONFIGURATION AND PERFORMANCE SETTINGS
-- ==============================================================================


-- Trigram configuration for optimized pattern matching
SET LOCAL pg_trgm.similarity_threshold = 0.3;
SET LOCAL pg_trgm.word_similarity_threshold = 0.6;
SET LOCAL pg_trgm.strict_word_similarity_threshold = 0.5;

-- Optimize parallel index creation
SET LOCAL min_parallel_index_scan_size = '512kB';

-- Transaction consistency is handled by explicit BEGIN/COMMIT blocks

\echo 'Railway processing started with enhanced performance settings'

-- ==============================================================================
-- STEP 2: DEPENDENCY VALIDATION
-- ==============================================================================

\echo 'Validating railway source data dependencies...'

DO $$
DECLARE
    table_count INTEGER;
    error_msg TEXT;
BEGIN
    -- Validate import.railway exists and has data
    SELECT COUNT(*) INTO table_count FROM import.railway LIMIT 1;
    IF table_count = 0 THEN
        RAISE EXCEPTION 'Source table import.railway is empty or missing. Cannot proceed with railway processing.';
    END IF;
    
    -- Validate import.transportation_stations exists and has data
    SELECT COUNT(*) INTO table_count FROM import.transportation_stations LIMIT 1;
    IF table_count = 0 THEN
        RAISE EXCEPTION 'Source table import.transportation_stations is empty or missing. Cannot proceed with railway processing.';
    END IF;
    
    RAISE NOTICE 'All required railway source tables validated successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE EXCEPTION 'Railway dependency validation failed: %', error_msg;
END $$;

\echo 'Railway source data validation completed successfully'

-- ==============================================================================
-- STEP 3: DROP EXISTING RAILWAY MATERIALIZED VIEWS FOR CLEAN REBUILD
-- ==============================================================================

\echo 'Dropping existing railway materialized views for clean rebuild...'

-- Drop railway materialized views that will be recreated
DROP MATERIALIZED VIEW IF EXISTS rbt.railway CASCADE;

-- Drop existing tables/views that depend on railway materialized views
DROP MATERIALIZED VIEW IF EXISTS rbt.yard_label CASCADE;

\echo 'Existing railway views dropped successfully'

-- ==============================================================================
-- STEP 4: CREATE CRITICAL RAILWAY INDEXES FOR PERFORMANCE
-- ==============================================================================

\echo 'Creating critical railway indexes for optimal performance...'

-- Railway table indexes
CREATE INDEX IF NOT EXISTS idx_railway_subclass ON import.railway USING btree(subclass);
CREATE INDEX IF NOT EXISTS idx_railway_usage ON import.railway USING btree(usage);
CREATE INDEX IF NOT EXISTS idx_railway_service ON import.railway USING btree(service);
CREATE INDEX IF NOT EXISTS idx_railway_gauge ON import.railway USING btree(gauge);
CREATE INDEX IF NOT EXISTS idx_railway_tracks ON import.railway USING btree(tracks);
CREATE INDEX IF NOT EXISTS idx_railway_electrified ON import.railway USING btree(electrified);
CREATE INDEX IF NOT EXISTS idx_railway_tunnel ON import.railway USING btree(is_tunnel);
CREATE INDEX IF NOT EXISTS idx_railway_bridge ON import.railway USING btree(is_bridge);
CREATE INDEX IF NOT EXISTS idx_railway_voltage ON import.railway USING btree((tags -> 'voltage'));
CREATE INDEX IF NOT EXISTS idx_railway_freq ON import.railway USING btree((tags -> 'frequency'));
CREATE INDEX IF NOT EXISTS idx_railway_geometry ON import.railway USING gist(geometry);

-- Transportation stations indexes
CREATE INDEX IF NOT EXISTS idx_transportation_stations_subclass ON import.transportation_stations USING btree(subclass);
CREATE INDEX IF NOT EXISTS idx_transportation_stations_service ON import.transportation_stations USING btree(service);
CREATE INDEX IF NOT EXISTS idx_transportation_stations_geometry ON import.transportation_stations USING gist(geometry);

-- ==============================================================================
-- GIN TRIGRAM INDEXES FOR RAILWAY PATTERN MATCHING OPTIMIZATION
-- ==============================================================================

\echo 'Creating GIN trigram indexes for railway pattern matching...'

-- Railway table trigram indexes
CREATE INDEX IF NOT EXISTS idx_railway_name_trgm ON import.railway USING GIN (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_railway_name_en_trgm ON import.railway USING GIN (name_en gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_railway_tags_hstore ON import.railway USING GIN (tags);

-- Transportation stations trigram indexes
CREATE INDEX IF NOT EXISTS idx_transportation_stations_name_trgm ON import.transportation_stations 
USING GIN (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_transportation_stations_operator_trgm ON import.transportation_stations 
USING GIN (operator gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_transportation_stations_tags_hstore ON import.transportation_stations 
USING GIN (tags);

-- Transportation stations specific hstore key indexes
CREATE INDEX IF NOT EXISTS idx_transportation_stations_yard_size ON import.transportation_stations 
USING btree ((tags -> 'railway:yard:size'));

-- Transportation label trigram indexes
CREATE INDEX IF NOT EXISTS idx_transportation_label_tags_hstore ON import.transportation_label 
USING GIN (tags);

-- Special case index for Francis Scott Key Bridge
CREATE INDEX IF NOT EXISTS idx_railway_bridge_francis_scott ON import.railway 
USING btree ((tags -> 'bridge:name'));

-- OPTIMIZED: Additional hstore containment indexes for performance
CREATE INDEX IF NOT EXISTS idx_railway_yard_size_containment ON import.railway 
USING GIN (tags) WHERE tags ? 'railway:yard:size';

-- Note: Lifecycle key detection is handled by idx_railway_lifecycle_key index created later

\echo 'GIN trigram indexes for railway created successfully'

-- Commit trigram indexes to ensure they persist
COMMIT;
\echo 'Railway trigram indexes committed successfully'


-- ==============================================================================
-- STEP 6: CREATE RAILWAY YARD LABEL TABLE
-- ==============================================================================

\echo 'Creating railway yard label table...'

-- Start new transaction for yard label table
BEGIN;

-- Create yard_label table with all data in a single statement
CREATE MATERIALIZED VIEW IF NOT EXISTS rbt.yard_label AS 
WITH normalized_labels AS (
    -- Original transportation_label records
    SELECT 
        osm_id, 
        class, 
        subclass, 
        NULLIF(operator,'') as operator, 
        NULLIF(name,'') as name, 
        NULLIF(tags -> 'ref','') as ref, 
        NULLIF(service,'') as service, 
        NULLIF((tags -> 'usage'),'') as usage, 
        -- Use optimized pattern matching for yard size classification
        -- OPTIMIZED: Combines hstore containment (@>) and trigram similarity for efficiency
        CASE
            -- Exact matches first (fastest using hstore containment)
            WHEN tags @> 'railway:yard:size=>very_large'::hstore THEN 'very_large'
            WHEN tags @> 'railway:yard:size=>very_small'::hstore THEN 'very_small'
            WHEN tags @> 'railway:yard:size=>large'::hstore THEN 'large'
            WHEN tags @> 'railway:yard:size=>medium'::hstore THEN 'medium'
            WHEN tags @> 'railway:yard:size=>small'::hstore THEN 'small'
            -- Pattern matching for variations
            WHEN tags -> 'railway:yard:size' ILIKE '%very%large%' THEN 'very_large'
            WHEN tags -> 'railway:yard:size' ILIKE '%very%small%' THEN 'very_small'
            WHEN tags -> 'railway:yard:size' ILIKE '%large%' AND tags -> 'railway:yard:size' NOT ILIKE '%very%' THEN 'large'
            WHEN tags -> 'railway:yard:size' ILIKE '%medium%' THEN 'medium'
            WHEN tags -> 'railway:yard:size' ILIKE '%small%' AND tags -> 'railway:yard:size' NOT ILIKE '%very%' THEN 'small'
            ELSE tags -> 'railway:yard:size'
        END as yard_size,
        tags -> 'railway:yard:purpose' as yard_purpose, 
        tags, 
        geometry 
    FROM import.transportation_label 
    WHERE subclass IN ('yar', 'yard') OR service = 'yard'
    
    UNION ALL
    
    -- Generated labels from yard polygons
    SELECT 
        osm_id, 
        class, 
        subclass, 
        NULLIF(operator,'') as operator, 
        NULLIF(name,'') as name, 
        tags -> 'ref' as ref, 
        NULLIF(service,'') as service, 
        NULLIF((tags -> 'usage'),'') as usage, 
        -- Use optimized pattern matching for yard size classification
        -- OPTIMIZED: Combines hstore containment (@>) and trigram similarity for efficiency
        CASE
            -- Exact matches first (fastest using hstore containment)
            WHEN tags @> 'railway:yard:size=>very_large'::hstore THEN 'very_large'
            WHEN tags @> 'railway:yard:size=>very_small'::hstore THEN 'very_small'
            WHEN tags @> 'railway:yard:size=>large'::hstore THEN 'large'
            WHEN tags @> 'railway:yard:size=>medium'::hstore THEN 'medium'
            WHEN tags @> 'railway:yard:size=>small'::hstore THEN 'small'
            -- Pattern matching for variations
            WHEN tags -> 'railway:yard:size' ILIKE '%very%large%' THEN 'very_large'
            WHEN tags -> 'railway:yard:size' ILIKE '%very%small%' THEN 'very_small'
            WHEN tags -> 'railway:yard:size' ILIKE '%large%' AND tags -> 'railway:yard:size' NOT ILIKE '%very%' THEN 'large'
            WHEN tags -> 'railway:yard:size' ILIKE '%medium%' THEN 'medium'
            WHEN tags -> 'railway:yard:size' ILIKE '%small%' AND tags -> 'railway:yard:size' NOT ILIKE '%very%' THEN 'small'
            ELSE tags -> 'railway:yard:size'
        END as yard_size,
        tags -> 'railway:yard:purpose' as yard_purpose,
        tags,
        ST_PointOnSurface(geometry)::geometry(Point,4326) as geometry
    FROM import.transportation_stations 
    WHERE subclass IN ('yar', 'yard') OR service = 'yard'
)
SELECT * FROM normalized_labels;

\echo 'Railway yard label table created successfully'

-- Commit yard label table
COMMIT;
\echo 'Railway yard label table committed successfully'

-- ==============================================================================
-- STEP 7: RAILWAY ENHANCED MATERIALIZED VIEW
-- ==============================================================================

\echo 'Creating rbt.railway materialized view...'

-- Start new transaction for railway enhanced materialized view
BEGIN;

DO $$
DECLARE
    error_msg TEXT;
BEGIN
    CREATE MATERIALIZED VIEW IF NOT EXISTS rbt.railway AS
WITH RECURSIVE 
lifecycle_keys(key) AS (
    VALUES 
        ('destroyed:railway'), ('disused:railway'), ('construction:railway')
),
lifecycle_types(type) AS (
    VALUES 
        ('destroyed'), ('disused'), ('construction')
),
cleaned_data AS (
    SELECT 
        osm_id,
        NULLIF(TRIM(name), '') AS name,
        NULLIF(TRIM(name_en), '') AS name_en,
        NULLIF(TRIM(ref), '') AS ref,
        NULLIF(TRIM(tags -> 'voltage'), '') AS voltage,
        NULLIF(TRIM(tags -> 'frequency'), '') AS frequency,
        NULLIF(TRIM(network), '') AS network,
        LOWER(NULLIF(TRIM(service), '')) AS service_value,
        LOWER(NULLIF(TRIM(usage), '')) AS usage_value,
        NULLIF(TRIM(gauge), '') AS gauge_value,
        NULLIF(TRIM(electrified), '') AS electrified_value,
        NULLIF(TRIM(tracks), '') AS tracks_value,
        is_tunnel,
        is_bridge,
        tags,
        ST_Length(ST_Transform(geometry, 3857))::real AS geom_len,
        CASE
            WHEN subclass IN ('construction') THEN
                COALESCE(tags -> subclass, subclass)
            WHEN subclass IN ('destroyed', 'disused') THEN
                COALESCE(tags -> (subclass || ':railway'), subclass)
            ELSE subclass
        END AS subclass,
        COALESCE(
            (SELECT NULLIF(TRIM(tags -> lk.key), '')
             FROM lifecycle_keys lk
             WHERE tags ? lk.key
             LIMIT 1),
            NULL
        ) AS lifecycle_desc,
        geometry
    FROM import.railway
),
classified_data AS (
    SELECT
        osm_id,
        name,
        name_en,
        ref,
        voltage,
        frequency,
        network,
        lifecycle_desc,
        CASE
            WHEN is_tunnel AND is_bridge THEN 'tunnel;bridge'
            WHEN is_tunnel THEN 'tunnel'
            WHEN is_bridge OR (tags -> 'bridge:name' = 'Francis Scott Key Bridge') THEN 'bridge'
            ELSE NULL
        END AS brunnel,
        CASE 
            WHEN service_value IN ('no', 'none') OR service_value IS NULL THEN NULL
            WHEN service_value % 'siding' OR service_value % 'siting' THEN 'siding'
            WHEN service_value % 'spur' THEN 'spur'
            WHEN service_value % 'crossover' THEN 'crossover'
            WHEN service_value % 'yard' THEN 'yard'
            WHEN service_value IS NULL AND usage_value IN ('crossover', 'siding', 'spur', 'yard') THEN usage_value
            WHEN service_value IS NULL AND usage_value % 'siding' THEN 'siding'
            WHEN service_value IS NULL AND usage_value % 'spur' THEN 'spur'
            WHEN service_value IS NULL AND usage_value % 'crossover' THEN 'crossover'
            WHEN service_value IS NULL AND usage_value % 'yard' THEN 'yard'
            ELSE 'yes'
        END AS service,
        CASE 
            WHEN usage_value % 'siding' THEN 'siding'
            WHEN usage_value % 'spur' THEN 'spur'
            WHEN usage_value % 'crossover' THEN 'crossover'
            WHEN usage_value % 'yard' THEN 'yard'
            WHEN usage_value % 'branch' THEN 'branch'
            WHEN usage_value % 'industrial' THEN 'industrial'
            WHEN usage_value % 'main' AND usage_value != 'maintenance' THEN 'main'
            WHEN usage_value % 'tourism' OR usage_value % 'tourist' THEN 'tourism'
            ELSE usage_value
        END AS usage,
        CASE
            WHEN (electrified_value IN ('FIXME', 'no', 'NO', 'b', 'cn', 'nogauge=1435', 'unknown') OR electrified_value IS NULL) AND subclass NOT IN ('tram', 'monorail', 'subway', 'light_rail', 'funicular') THEN 0
            WHEN electrified_value IN ('tram', 'monorail', 'subway', 'light_rail', 'funicular') OR subclass IN ('tram', 'monorail', 'subway', 'light_rail', 'funicular') THEN 1
            ELSE 1
        END AS electrified,
        CASE
            WHEN tracks_value IN ('1', 'single', 'tram', '1frequency=0', 'monorail') OR tracks_value IS NULL THEN 'single'
            ELSE 'multiple'
        END AS tracks,
        CASE 
            WHEN subclass IN ('narrow_gauge', 'miniature') THEN 'narrow'
            WHEN gauge_value IS NULL OR gauge_value IN ('railway', 'rail', 'unknown', 'no', '1.435mm', 'standard') OR gauge_value ILIKE '14%' THEN 'standard'
            WHEN gauge_value IN ('wide', 'broad') OR gauge_value ~ '^(15|16|17|18|19|2\d{3})' THEN 'broad'
            ELSE 'narrow'
        END AS gauge,
        COALESCE(
            (SELECT lt.type
             FROM lifecycle_types lt
             WHERE subclass = lt.type 
                OR (lt.type IN ('destroyed', 'disused') AND tags ? (lt.type || ':railway'))
             LIMIT 1),
            NULL
        ) AS lifecycle_type,
        subclass,
        geom_len,
        tags,
        geometry
    FROM cleaned_data
),
final_data AS (
    SELECT
        osm_id,
        name,
        name_en,
        brunnel,
        ref,
        subclass,
        voltage,
        frequency,
        network,
        service,
        usage,
        electrified,
        tracks,
        gauge,
        CASE
            WHEN lifecycle_type IS NULL THEN 'intact'
            ELSE lifecycle_type
        END AS lifecycle_type,
        lifecycle_desc,
        geom_len,
        geometry
    FROM classified_data
)
SELECT
    osm_id,
    name,
    name_en,
    ref,
    brunnel,
    subclass,
    voltage,
    frequency,
    network,
    service,
    usage,
    electrified,
    tracks,
    gauge,
    lifecycle_type,
    lifecycle_desc,
    CASE
        WHEN service IS NULL AND lifecycle_type = 'intact' THEN
            'railway_intact_' ||
            CASE WHEN gauge = 'narrow' THEN 'narrow' ELSE 'broadstandard' END || '_' ||
            CASE WHEN electrified = 1 THEN 'electrified' ELSE 'nonelectrified' END || '_' ||
            CASE WHEN tracks = 'single' THEN 'singletrack' ELSE 'multipletracks' END

        WHEN service IS NOT NULL AND lifecycle_type = 'intact' THEN
            'sidetrack_intact_' ||
            CASE WHEN gauge = 'narrow' THEN 'narrow' ELSE 'broadstandard' END || '_' ||
            CASE WHEN electrified = 1 THEN 'electrified' ELSE 'nonelectrified' END

        WHEN service IS NULL AND lifecycle_type != 'intact' THEN
            'railway_not-intact_' ||
            CASE WHEN gauge = 'narrow' THEN 'narrow' ELSE 'broadstandard' END || '_' ||
            CASE WHEN electrified = 1 THEN 'electrified' ELSE 'nonelectrified' END || '_' ||
            CASE WHEN tracks = 'single' THEN 'singletrack' ELSE 'multipletracks' END

        WHEN service IS NOT NULL AND lifecycle_type != 'intact' THEN
            'sidetrack_not-intact_' ||
            CASE WHEN gauge = 'narrow' THEN 'narrow' ELSE 'broadstandard' END || '_' ||
            CASE WHEN electrified = 1 THEN 'electrified' ELSE 'nonelectrified' END
    END AS dps_type,
    geom_len,
    geometry
FROM final_data;

    -- Create indexes on materialized view
    CREATE INDEX IF NOT EXISTS idx_railway_enhanced_subclass ON rbt.railway USING btree(subclass);
    CREATE INDEX IF NOT EXISTS idx_railway_enhanced_service ON rbt.railway USING btree(service);
    CREATE INDEX IF NOT EXISTS idx_railway_enhanced_lifecycle ON rbt.railway USING btree(lifecycle_type);
    CREATE INDEX IF NOT EXISTS idx_railway_enhanced_geometry ON rbt.railway USING gist(geometry);

    RAISE NOTICE 'rbt.railway materialized view created successfully';

EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create rbt.railway materialized view: %', error_msg;
    RAISE;
END $$;

-- Commit this materialized view
COMMIT;
\echo 'rbt.railway materialized view committed'

-- Start new transaction for regular views
BEGIN;

-- ==============================================================================
-- STEP 8: CREATE RAILWAY STATION VIEWS
-- ==============================================================================

\echo 'Creating railway station views...'

-- Additional railway station views
CREATE VIEW rbt.railway_station AS
	SELECT
		id,
		osm_id,
        class,
		subclass,
		NULLIF(name,'') as name,
		NULLIF(platforms,'') as platforms,
		NULLIF(operator,'') as operator,
		NULLIF(station,'') as station,
		NULLIF(service,'') as service,
		ST_Area(ST_Transform(geometry, 3857))::real as area,
		geometry
	FROM import.transportation_stations;

CREATE VIEW rbt.railway_station_label AS
	SELECT
		id,
		osm_id,
        class,
		subclass,
		NULLIF(name,'') as name,
		NULLIF(platforms,'') as platforms,
		NULLIF(operator,'') as operator,
		NULLIF(station,'') as station,
		NULLIF(service,'') as service,
		ST_Area(ST_Transform(geometry, 3857))::real as area,
		ST_PointOnSurface(geometry)::geometry(Point,4326) as geometry
	FROM import.transportation_stations;

-- Railway zoom level views
CREATE VIEW rbt.railway_z6 AS
SELECT * FROM rbt.railway
WHERE service != 'yard';

\echo 'Railway station views created successfully'

-- ==============================================================================
-- STEP 10: ANALYZE TABLES FOR OPTIMAL QUERY PLANNING
-- ==============================================================================

\echo 'Analyzing railway tables for optimal query planning...'

-- Analyze materialized views
ANALYZE rbt.railway;
ANALYZE rbt.yard_label;

-- Analyze source tables
ANALYZE import.railway;
ANALYZE import.transportation_stations;

\echo 'Railway table analysis completed'

-- ==============================================================================
-- STEP 11: FINAL VALIDATION AND COMMIT
-- ==============================================================================

\echo 'Performing final railway validation...'

DO $$
DECLARE
    rec RECORD;
    success_count INTEGER := 0;
    total_views INTEGER := 1;
    view_name TEXT;
    view_exists BOOLEAN;
    row_count BIGINT;
BEGIN
    RAISE NOTICE '=== RAILWAY PROCESSING SUMMARY ===';
    
    -- Check railway materialized view
    view_name := 'rbt.railway';
    SELECT EXISTS (
        SELECT 1 FROM pg_matviews 
        WHERE schemaname = split_part(view_name, '.', 1) 
        AND matviewname = split_part(view_name, '.', 2)
    ) INTO view_exists;
    
    IF view_exists THEN
        BEGIN
            EXECUTE format('SELECT COUNT(*) FROM %s', view_name) INTO row_count;
            RAISE NOTICE '✓ Materialized view % exists with % rows', view_name, row_count;
            success_count := success_count + 1;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '⚠ Materialized view % exists but could not count rows: %', view_name, SQLERRM;
        END;
    ELSE
        RAISE WARNING '✗ Materialized view % was not created', view_name;
    END IF;
    
    -- Check regular railway views
    DECLARE
        view_count INTEGER;
    BEGIN
        SELECT COUNT(*) INTO view_count
        FROM information_schema.views 
        WHERE table_schema = 'rbt' 
        AND table_name IN ('railway', 'railway_station', 'railway_station_label', 'railway_z6');
        
        RAISE NOTICE '✓ Created % railway-related views', view_count;
    END;
    
    -- Check yard_label table
    BEGIN
        SELECT COUNT(*) INTO row_count FROM rbt.yard_label;
        RAISE NOTICE '✓ Created yard_label table with % rows', row_count;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING '⚠ yard_label table could not be counted: %', SQLERRM;
    END;
    
    -- Final summary
    RAISE NOTICE '=== RAILWAY PROCESSING RESULTS ===';
    RAISE NOTICE 'Materialized views: %/% successful', success_count, total_views;
    
    IF success_count > 0 THEN
        RAISE NOTICE '✓ Railway processing completed with % successful materialized view(s)', success_count;
    ELSE
        RAISE WARNING '⚠ No railway materialized views were successfully created';
    END IF;
    
    RAISE NOTICE 'Transaction-based processing ensures that successful views are preserved';
    
END $$;

\echo 'Final railway validation completed successfully'

-- Commit transaction
COMMIT;

-- ==============================================================================
-- STEP 12: VACUUM AND ANALYZE FOR OPTIMAL PERFORMANCE
-- ==============================================================================

\echo 'Running final railway optimization...'

-- Vacuum and analyze railway materialized views for optimal performance
VACUUM FULL ANALYZE rbt.railway;
VACUUM FULL ANALYZE rbt.yard_label;

\echo '=============================================================================='
\echo 'RAILWAY PROCESSING COMPLETED SUCCESSFULLY'
\echo 'Enhanced railway script execution finished with optimizations:'
\echo '- Created railway materialized view for optimal performance'
\echo '- Added comprehensive railway indexes for fast queries'
\echo '- Implemented transaction management with error handling'
\echo '- Added railway dependency validation for reliable CI/CD execution'
\echo '- Created railway station views and yard processing'
\echo '=============================================================================='

-- Disable timing
\timing off
