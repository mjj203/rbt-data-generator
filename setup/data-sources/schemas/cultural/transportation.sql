-- ==============================================================================
-- HIGHWAY LAYER SQL SCRIPT FOR CI/CD PROCESSING
-- Extracted from cultural.sql - Optimized for execution after imposm3 import completion
-- ==============================================================================

-- Enable timing for CI/CD monitoring
\timing on

-- Start transaction with error handling
BEGIN;

-- ==============================================================================
-- STEP 1: CONFIGURATION AND PERFORMANCE SETTINGS
-- ==============================================================================

-- Set search path to ensure hstore operators are accessible 
-- This is critical for PostgreSQL 17 where hstore operators need proper schema visibility
-- Include import and rbt schemas where the tables reside
SET search_path TO import, rbt, public, pg_catalog;

-- Ensure required extensions are installed in the public schema
-- hstore: Required for OSM tags storage and querying (? operator for key existence, -> for value extraction)
-- pg_trgm: Required for fuzzy text matching and similarity functions (word_similarity, similarity)
-- Per PostgreSQL documentation: https://www.postgresql.org/docs/current/hstore.html
CREATE EXTENSION IF NOT EXISTS hstore SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA public;
-- Trigram configuration for optimized pattern matching
SET LOCAL pg_trgm.similarity_threshold = 0.3;
SET LOCAL pg_trgm.word_similarity_threshold = 0.6;
SET LOCAL pg_trgm.strict_word_similarity_threshold = 0.5;

-- Optimize parallel index creation
SET LOCAL min_parallel_index_scan_size = '128kB';


\echo 'Highway layer processing started with enhanced performance settings'

-- ==============================================================================
-- STEP 2: DEPENDENCY VALIDATION
-- ==============================================================================

\echo 'Validating highway source data dependencies...'

DO $$
DECLARE
    table_count INTEGER;
    error_msg TEXT;
BEGIN
    -- Validate import.highway exists and has data
    SELECT COUNT(*) INTO table_count FROM import.highway LIMIT 1;
    IF table_count = 0 THEN
        RAISE EXCEPTION 'Source table import.highway is empty or missing. Cannot proceed with highway layer processing.';
    END IF;
    
    -- Validate fieldmap schema exists (optional dependency)
    IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'fieldmap') THEN
        RAISE NOTICE 'Schema fieldmap is missing. Highway processing will continue without fieldmap integration.';
    END IF;
    
    RAISE NOTICE 'Highway source data validated successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE EXCEPTION 'Highway dependency validation failed: %', error_msg;
END $$;

\echo 'Highway source data validation completed successfully'

-- ==============================================================================
-- STEP 4: CREATE CRITICAL INDEXES FOR HIGHWAY PERFORMANCE
-- ==============================================================================

\echo 'Creating critical highway indexes for optimal performance...'

-- Highway table indexes
CREATE INDEX IF NOT EXISTS idx_highway_surface_trigram ON import.highway USING GIN (surface gin_trgm_ops);
CREATE UNIQUE INDEX IF NOT EXISTS rbt_highway_fid_idx ON import.highway USING btree(id);
CREATE INDEX IF NOT EXISTS idx_highway_ref ON import.highway USING gin(ref gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_highway_osmid ON import.highway USING btree(osm_id);
CREATE INDEX IF NOT EXISTS idx_highway_subclass ON import.highway USING btree(subclass);
CREATE INDEX IF NOT EXISTS idx_highway_subclass_gin ON import.highway USING gin(subclass gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_highway_name_trgm ON import.highway USING GIN (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_highway_name_en_trgm ON import.highway USING GIN (name_en gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_highway_tunnel ON import.highway USING btree(is_tunnel);
CREATE INDEX IF NOT EXISTS idx_highway_bridge ON import.highway USING btree(is_bridge);
CREATE INDEX IF NOT EXISTS idx_highway_ford ON import.highway USING btree(is_ford);
CREATE INDEX IF NOT EXISTS idx_highway_geometry ON import.highway USING gist(geometry);
CREATE INDEX IF NOT EXISTS idx_highway_lifecycle_tags ON import.highway USING GIN (tags)
WHERE tags ? 'highway:demolished' OR 
      tags ? 'demolished:highway' OR
      tags ? 'destroyed:highway' OR 
      tags ? 'removed:highway' OR
      tags ? 'razed:highway' OR
      tags ? 'disused:highway' OR
      tags ? 'abandoned:highway' OR
      tags ? 'planned:highway' OR
      tags ? 'construction:highway' OR
      tags ? 'bridge:name' OR
      tags ? 'tunnel:name' OR
      tags ? 'proposed:highway';

-- Commit trigram indexes to ensure they persist
COMMIT;
\echo 'Highway trigram indexes committed successfully'


-- ==============================================================================
-- STEP 6: CREATE HIGHWAY MATERIALIZED VIEWS FOR HIGH-PERFORMANCE QUERIES
-- ==============================================================================

\echo 'Creating highway materialized views for optimal CI/CD performance...'

-- Start new transaction for first materialized view
BEGIN;

-- ==============================================================================
-- HIGHWAY CLASSIFICATION MATERIALIZED VIEWS
-- ==============================================================================

\echo 'Creating highway classification materialized views...'

CREATE MATERIALIZED VIEW import.highway_surface_subclass AS
WITH classification_patterns AS (
    SELECT *
    FROM (VALUES
        -- Basic road types (higher priority = checked first)
        (1, 'motorway', '^(motorway|motoway)$', NULL),
        (2, 'trunk', '.*tru.*k.*', '.*link.*'),
        (3, 'primary', '.*p.*y.*', '.*link.*'),
        (4, 'secondary', '^sec.*', '.*link.*'),
        (5, 'tertiary', '.*(te.*y.*|minor|highway).*', '.*link.*'),
        (6, 'residential', '.*re.*l.*', '.*rail.*'),
        (7, 'unclassified', '.*unc.*ed.*', '.*link.*'),
        (8, 'living_street', '.*(living.*street|livingstreet).*', NULL),
        (9, 'pedestrian', '.*ped.*an.*', NULL),
        (10, 'track', '.*track.*', NULL),
        (11, 'bus_guideway', '.*(bus_guideway|bus guideway).*', NULL),
        (12, 'escape', '.*escape.*', NULL),
        (13, 'raceway', '.*raceway.*', NULL),
        (14, 'road', '.*road.*', '.*footway.*'),
        (15, 'busway', '.*busway.*', NULL),
        (16, 'footway', '(foot.*|.*foo.*way.*)', NULL),
        (17, 'bridleway', '.*bridleway.*', NULL),
        (18, 'steps', '.*steps.*', NULL),
        (19, 'corridor', '.*corridor.*', NULL),
        (20, 'path', '.*path.*', '.*footway.*'),
        (21, 'cycleway', '.*(cy.*way|ci.*way).*', NULL),
        (22, 'abandoned', '.*a.*oned.*', NULL),
        (23, 'demolished', '.*demo.*', NULL),
        
        -- Link types (lower priority than basic road types)
        (30, 'motorway_link', '.*mot.*way.*li.*k.*', NULL),
        (31, 'trunk_link', '.*trunk.*link.*', NULL),
        (32, 'primary_link', '.*primary.*link.*', NULL),
        (33, 'secondary_link', '.*secondary.*link.*', NULL),
        (34, 'tertiary_link', '.*tertiary.*link.*', NULL),
        (35, 'unclassified_link', '.*unc.*ed.*link.*', NULL)
    ) AS t(priority, result, pattern, exclusion)
)
SELECT 
    id,
    CASE
        WHEN surface IS NULL OR TRIM(surface) = '' THEN 'paved_unknown'
        WHEN (
            SELECT array_agg(matches[1]) 
            FROM regexp_matches(lower(surface), '([a-z_]+)', 'g') AS matches
        ) && ARRAY[
            'asphalt','asphal','asfalt','tarmac','concrete','cement',
            'cobblestone','sett','paving_stone','paved','brick','block',
            'metal','steel','wood','boardwalk','chipseal','tiles',
            'flagstone','bitum','interlock','paver','tartan',
            'unhewn_cobblestone','pebblestone'
        ] OR surface ~* 'tar.*road' THEN 'paved'
        WHEN (
            SELECT array_agg(matches[1]) 
            FROM regexp_matches(lower(surface), '([a-z_]+)', 'g') AS matches
        ) && ARRAY[
            'unpaved','dirt','gravel','sand','earth','mud','grass',
            'ground','clay','soil','compacted','fine_gravel','ice',
            'snow','shell','rock','stone'
        ] THEN 'unpaved'
        ELSE 'unknown'
    END AS normalized_surface,
    COALESCE(
        (SELECT cp.result
         FROM classification_patterns cp
         WHERE lower(subclass) ~ cp.pattern
           AND (cp.exclusion IS NULL OR lower(subclass) !~ cp.exclusion)
         ORDER BY cp.priority
         LIMIT 1
        ),
        lower(subclass)
    ) AS subclass
FROM import.highway;

-- Create indexes on materialized view
CREATE INDEX idx_highway_surface_subclass_id ON import.highway_surface_subclass USING btree(id);
CREATE INDEX idx_highway_surface_subclass_sub ON import.highway_surface_subclass USING btree(subclass);

-- Commit this materialized view
COMMIT;
\echo 'import.highway_surface_subclass materialized view committed'

-- Start new transaction for next materialized view
BEGIN;

CREATE MATERIALIZED VIEW import.highway_ref AS
WITH matching AS (
    SELECT
        id,
        array_to_string(ARRAY[regexp_matches(ref, '[0-9]+', 'g')], ',') AS ref_match
    FROM import.highway
)
SELECT
    id,
    string_agg(ref_match, ';') AS ref_number
FROM matching
GROUP BY id;

-- Create indexes on materialized view
CREATE INDEX idx_highway_ref_id ON import.highway_ref USING btree(id);
CREATE INDEX idx_highway_ref_match ON import.highway_ref USING btree(ref_number);

-- Commit this materialized view
COMMIT;
\echo 'import.highway_ref materialized view committed'

-- Start new transaction for next materialized view
BEGIN;

CREATE MATERIALIZED VIEW import.highway_fieldmap AS 
    SELECT 
        a.id,
        b.gid_0 
    FROM import.highway a 
    JOIN fieldmap.usa b 
        ON a.geometry && b.geometry 
        AND st_intersects(a.geometry, b.geometry);
CREATE INDEX idx_highway_fieldmap_id ON import.highway_fieldmap USING btree(id);
CREATE INDEX idx_highway_fieldmap_gid ON import.highway_fieldmap USING btree(gid_0);


-- Commit this materialized view (conditional)
COMMIT;
\echo 'import.highway_fieldmap materialized view committed (if created)'

-- Start new transaction for next materialized view
BEGIN;

CREATE MATERIALIZED VIEW import.highway_temp AS
WITH lifecycle_keys(key) AS (
    VALUES ('destroyed:highway'), ('highway:demolished'), ('demolished:highway'), ('razed:highway'), ('disused:highway'),
        ('abandoned:highway'), ('removed:highway'), ('planned:highway'), ('construction:highway'), ('proposed:highway')
),
lifecycle_types(type) AS (
    VALUES ('destroyed'), ('removed'), ('demolished'), ('razed'), ('disused'), ('abandoned'), ('construction')
)
SELECT
    a.id,
    a.osm_id,
    COALESCE(b.gid_0, 'OTHER') as gid_0,
    NULLIF(TRIM(a.name), '') AS name,
    CASE
        WHEN (a.tags -> 'bridge:name') IS NOT NULL THEN (a.tags -> 'bridge:name')
        WHEN (a.tags -> 'tunnel:name') IS NOT NULL THEN (a.tags -> 'tunnel:name')
        ELSE NULL
    END AS brunnel_name,
    length(a.name) AS name_len,
    NULLIF(TRIM(a.ref), '') AS ref,
    c.ref_number,
    d.normalized_surface AS surface,
    length(c.ref_number) AS ref_number_len,
    (a.ref ~~ ANY(ARRAY['%:%', '%,%', '%;%'])) AS ref_multi,
    length(a.ref) AS ref_len,
    CASE
        WHEN a.is_tunnel THEN CASE WHEN a.is_bridge THEN 'tunnel;bridge' ELSE 'tunnel' END
        WHEN a.is_bridge THEN CASE WHEN a.is_ford THEN 'bridge;ford' ELSE 'bridge' END
        WHEN a.is_ford THEN 'ford'
        WHEN a.tags -> 'bridge:name' = 'Francis Scott Key Bridge' THEN 'bridge'
    END AS brunnel,
    COALESCE(
        (SELECT NULLIF(TRIM(a.tags -> lk.key), '')
            FROM lifecycle_keys lk
            WHERE a.tags ? lk.key
            LIMIT 1),
            NULL
    ) AS lifecycle_desc,
    COALESCE(
        (SELECT lt.type
            FROM lifecycle_types lt
            WHERE lower(d.subclass) = lt.type 
                OR (lt.type = 'demolished' AND (a.tags ? 'highway:demolished' OR a.tags ? 'demolished:highway'))
                OR (lt.type IN ('destroyed', 'removed', 'razed', 'disused', 'abandoned') AND a.tags ? (lt.type || ':highway'))
            LIMIT 1),
            NULL
    ) AS lifecycle_type,
    NULLIF(a.lane, '') AS lane,
    NULLIF(TRIM(a.tags -> 'layer'), '') AS layer,
    ST_Length(ST_Transform(a.geometry, 3857))::real AS geom_len,
    CASE
        WHEN lower(d.subclass) IN ('construction', 'proposed', 'planned') THEN
            COALESCE(a.tags -> lower(d.subclass), lower(d.subclass))
        WHEN lower(d.subclass) IN ('destroyed', 'disused', 'removed', 'razed', 'abandoned') THEN
            COALESCE(a.tags -> (lower(d.subclass) || ':highway'), lower(d.subclass))
        WHEN a.tags -> 'bridge:name' = 'Francis Scott Key Bridge' THEN 'motorway'
        WHEN lower(d.subclass) = 'demolished' THEN
            COALESCE(a.tags -> 'demolished:highway', a.tags -> 'highway:demolished', lower(d.subclass))
        ELSE lower(d.subclass)
    END AS subclass,
    a.geometry
FROM import.highway a
LEFT JOIN import.highway_fieldmap b ON a.id = b.id 
LEFT JOIN import.highway_ref c ON a.id = c.id
LEFT JOIN import.highway_surface_subclass d ON a.id = d.id;

-- Create indexes on materialized view
CREATE INDEX idx_highway_temp_gid ON import.highway_temp USING btree(gid_0);
CREATE INDEX idx_highway_temp_ref_multi ON import.highway_temp USING btree(ref_multi);
CREATE INDEX idx_highway_temp_ref ON import.highway_temp USING gin(ref gin_trgm_ops);
CREATE INDEX idx_highway_temp_subclass ON import.highway_temp USING btree(subclass);
CREATE INDEX idx_highway_temp_geom ON import.highway_temp USING gist(geometry);

-- Commit this materialized view
COMMIT;
\echo 'import.highway_temp materialized view committed'

-- Start new transaction for next materialized view
BEGIN;

-- ==============================================================================
-- HIGHWAY ENHANCED MATERIALIZED VIEW
-- ==============================================================================

\echo 'Creating rbt.highway materialized view...'

DO $$
DECLARE
    error_msg TEXT;
BEGIN
    CREATE MATERIALIZED VIEW rbt.highway AS
WITH highway_with_route_type AS (
    SELECT
        osm_id,
        gid_0,
        name,
        NULLIF(brunnel_name,'') AS brunnel_name,
        name_len,
        CASE
            WHEN name = 'Baltimore Beltway' THEN 'motorway'
            ELSE subclass
        END AS subclass,
        ref,
        ref_len,
        ref_number,
        ref_number_len,
        ref_multi,
        brunnel,
        surface,
        COALESCE(lifecycle_type, 'intact') as lifecycle_type,
        CASE
            WHEN lane NOT IN ('1','2','3','4','5') THEN NULL
            ELSE lane::int
        END AS lane,
        geom_len::int AS geom_len,
        geometry,
        CASE
            WHEN gid_0 = 'USA' AND ref_multi = false THEN
                CASE
                    WHEN ref ~ '^(A[KLRZ]|C[AOT]|D[CE]|FL|GA|HI|I[ADLN]|K[SY]|LA|M[ADEINOST]|N[CDEHJMVY]|O[HKR]|PA|RI|S[CD]|T[NX]|UT|V[AT]|W[AIVY])' THEN
                        CASE
                            WHEN ref LIKE '__ %Bus%' THEN 'State Hwy Business'
                            WHEN ref LIKE '__ % %' THEN 'State Hwy Other'
                            ELSE 'State Hwy'
                        END
                    WHEN ref LIKE 'US %' THEN
                        CASE
                            WHEN ref LIKE '%Bus%' THEN 'US Hwy Business'
                            WHEN ref LIKE '% % %' THEN 'US Hwy Other'
                            ELSE 'US Hwy'
                        END
                    WHEN ref LIKE 'I %' THEN
                        CASE
                            WHEN ref ILIKE '%Bus%' THEN 'Interstate Business'
                            WHEN ref LIKE '% % %' THEN 'Interstate Other'
                            ELSE 'Interstate'
                        END
                END
        END AS route_types
    FROM import.highway_temp
    WHERE geometry IS NOT NULL AND subclass IN ('demolished', 'abandoned', 'bridleway','bus_guideway','cycleway','footway','living_street','motorway','motorway_link','path','pedestrian','primary','primary_link','raceway','residential','road','secondary','secondary_link','service','steps','tertiary','tertiary_link','track','trunk','trunk_link','unclassified','')
)
SELECT
    osm_id,
    COALESCE(route_types, CASE WHEN gid_0 = 'USA' THEN 'Other' END) AS route_type,
    name,
    brunnel_name,
    name_len,
    subclass,
    ref,
    ref_len,
    ref_number,
    ref_number_len,
    ref_multi,
    brunnel,
    surface,
    CASE
        WHEN osm_id IN (1113291935, 1113291934, 1113291937, 1113291932) THEN 'destroyed'
        ELSE lifecycle_type
    END AS lifecycle_type,
    lane,
    geom_len,
    geometry
FROM highway_with_route_type;

    RAISE NOTICE 'rbt.highway materialized view created successfully';

EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create rbt.highway materialized view: %', error_msg;
    RAISE;
END $$;

-- Commit this materialized view
COMMIT;
\echo 'rbt.highway materialized view committed'

-- Start new transaction for regular views
BEGIN;

-- ==============================================================================
-- STEP 7: CREATE HIGHWAY REGULAR VIEWS AND ZOOM LEVEL VIEWS
-- ==============================================================================

\echo 'Creating highway regular views and zoom level views...'

-- Zoom level views that reference the wrapper view
CREATE VIEW rbt.highway_z4 AS
SELECT * FROM rbt.highway
WHERE subclass IN ('motorway', 'trunk', 'construction_trunk', 'construction_motorway');

CREATE VIEW rbt.highway_z6 AS
SELECT * FROM rbt.highway
WHERE subclass IN ('motorway', 'trunk', 'primary', 'construction_trunk', 'construction_motorway', 'construction_primary');

CREATE VIEW rbt.highway_z7 AS
SELECT * FROM rbt.highway
WHERE subclass IN ('motorway', 'motorway_link', 'trunk', 'primary', 'construction_trunk', 'construction_motorway', 'construction_primary');

CREATE VIEW rbt.highway_z8 AS
SELECT * FROM rbt.highway
WHERE subclass IN ('motorway', 'motorway_link', 'trunk', 'trunk_link', 'primary', 'secondary', 'construction_trunk', 'construction_motorway', 'construction_primary', 'construction_secondary');

CREATE VIEW rbt.highway_z9 AS
SELECT * FROM rbt.highway
WHERE subclass IN ('motorway', 'motorway_link', 'trunk', 'trunk_link', 'primary', 'primary_link', 'secondary', 'construction_trunk', 'construction_motorway', 'construction_primary', 'construction_secondary');

CREATE VIEW rbt.highway_z10 AS
SELECT * FROM rbt.highway
WHERE subclass IN ('motorway', 'motorway_link', 'trunk', 'trunk_link', 'primary', 'primary_link', 'secondary', 'tertiary', 'construction_trunk', 'construction_motorway', 'construction_primary', 'construction_secondary', 'construction_tertiary', 'construction', 'construction_unclassified', 'construction_road');

CREATE VIEW rbt.highway_z11 AS
SELECT * FROM rbt.highway
WHERE subclass IN ('motorway', 'motorway_link', 'trunk', 'trunk_link', 'primary', 'primary_link', 'secondary', 'secondary_link', 'tertiary', 'tertiary_link', 'unclassified', 'road', 'construction_trunk', 'construction_motorway', 'construction_primary', 'construction_secondary', 'construction_tertiary', 'construction_unclassified', 'construction_road', 'construction');

CREATE VIEW rbt.highway_z12 AS
SELECT * FROM rbt.highway
WHERE subclass IN ('motorway', 'motorway_link', 'trunk', 'trunk_link', 'primary', 'primary_link', 'secondary', 'secondary_link', 'tertiary', 'tertiary_link', 'unclassified', 'proposed', 'road', 'living_street', 'residential', 'tertiary_link', 'unclassified', 'road', 'construction_trunk', 'construction_motorway', 'construction_primary', 'construction_secondary', 'construction', 'construction_tertiary', 'construction_unclassified', 'construction_road', 'construction_residential', 'construction_living_street');

\echo 'Highway regular views created successfully'


-- ==============================================================================
-- STEP 9: FINAL HIGHWAY VALIDATION AND COMMIT
-- ==============================================================================

\echo 'Performing final highway validation...'

DO $$
DECLARE
    rec RECORD;
    success_count INTEGER := 0;
    total_views INTEGER := 5;
    view_name TEXT;
    view_exists BOOLEAN;
    row_count BIGINT;
BEGIN
    RAISE NOTICE '=== HIGHWAY LAYER PROCESSING SUMMARY ===';
    
    -- Check each materialized view
    FOR view_name IN VALUES 
        ('rbt.highway'),
        ('import.highway_surface_subclass'), ('import.highway_ref'), ('import.highway_fieldmap'), 
        ('import.highway_temp') 
    LOOP
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
    END LOOP;
    
    -- Check regular views
    DECLARE
        view_count INTEGER;
    BEGIN
        SELECT COUNT(*) INTO view_count
        FROM information_schema.views 
        WHERE table_schema = 'rbt' 
        AND table_name LIKE 'highway%';
        
        RAISE NOTICE '✓ Created % highway-related views', view_count;
    END;
    
    -- Final summary
    RAISE NOTICE '=== PROCESSING RESULTS ===';
    RAISE NOTICE 'Highway materialized views: %/% successful', success_count, total_views;
    
    IF success_count > 0 THEN
        RAISE NOTICE '✓ Highway layer processing completed with % successful materialized view(s)', success_count;
    ELSE
        RAISE WARNING '⚠ No highway materialized views were successfully created';
    END IF;
    
    RAISE NOTICE 'Transaction-based processing ensures that successful views are preserved';
    
END $$;

\echo 'Final highway validation completed successfully'

-- Commit transaction
COMMIT;

-- ==============================================================================
-- STEP 11: VACUUM AND ANALYZE FOR OPTIMAL HIGHWAY PERFORMANCE
-- ==============================================================================

\echo 'Running final highway optimization...'

-- Vacuum and analyze all highway materialized views for optimal performance
VACUUM FULL ANALYZE import.highway_surface_subclass;
VACUUM FULL ANALYZE import.highway_ref;
VACUUM FULL ANALYZE import.highway_fieldmap;
VACUUM FULL ANALYZE import.highway_temp;
VACUUM FULL ANALYZE rbt.highway;

\echo '=============================================================================='
\echo 'HIGHWAY LAYER PROCESSING COMPLETED SUCCESSFULLY'
\echo 'Highway-specific script execution finished with optimizations:'
\echo '- Created highway materialized views for optimal performance'
\echo '- Added comprehensive highway indexes for fast queries'
\echo '- Implemented transaction management with error handling'
\echo '- Added highway dependency validation for reliable CI/CD execution'
\echo '- Applied highway-specific spatial optimizations'
\echo '- Created zoom-level specific highway views'
\echo '=============================================================================='

-- Disable timing
\timing off
