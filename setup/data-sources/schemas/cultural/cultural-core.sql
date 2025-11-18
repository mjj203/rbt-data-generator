-- ==============================================================================
-- ENHANCED CULTURAL LAYER SQL SCRIPT FOR CI/CD PROCESSING
-- Optimized for execution after imposm3 import completion
-- ==============================================================================

-- Enable timing for CI/CD monitoring
\timing on

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

\echo 'Cultural layer processing started with enhanced performance settings'

-- ==============================================================================
-- STEP 2: DEPENDENCY VALIDATION
-- ==============================================================================

\echo 'Validating source data dependencies...'

-- NOTE: This script uses pg_matviews catalog instead of information_schema.tables
-- for materialized view detection, as information_schema.tables can be unreliable
-- for materialized views due to timing and metadata consistency issues.

DO $$
DECLARE
    table_count INTEGER;
    error_msg TEXT;
BEGIN

    -- Validate import.shipway_linestring exists and has data
    SELECT COUNT(*) INTO table_count FROM import.shipway_linestring LIMIT 1;
    IF table_count = 0 THEN
        RAISE EXCEPTION 'Source table import.shipway_linestring is empty or missing. Cannot proceed with cultural layer processing.';
    END IF;
    
    -- Validate import.transportation_stations exists and has data
    SELECT COUNT(*) INTO table_count FROM import.transportation_stations LIMIT 1;
    IF table_count = 0 THEN
        RAISE EXCEPTION 'Source table import.transportation_stations is empty or missing. Cannot proceed with cultural layer processing.';
    END IF;
    
    -- Validate import.builtup_area exists and has data
    SELECT COUNT(*) INTO table_count FROM import.builtup_area LIMIT 1;
    IF table_count = 0 THEN
        RAISE EXCEPTION 'Source table import.builtup_area is empty or missing. Cannot proceed with cultural layer processing.';
    END IF;
    

    
    -- Validate geonames schema exists
    IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'geonames') THEN
        RAISE EXCEPTION 'Schema geonames is missing. Cannot proceed with cultural layer processing.';
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

-- Drop cultural materialized views that will be recreated
DROP MATERIALIZED VIEW IF EXISTS rbt.port_surface_enhanced CASCADE;
DROP MATERIALIZED VIEW IF EXISTS rbt.geonames_hydrographic_enhanced CASCADE;



\echo 'Existing views dropped successfully'

-- ==============================================================================
-- STEP 4: CREATE CRITICAL INDEXES FOR PERFORMANCE
-- ==============================================================================

\echo 'Creating critical indexes for optimal performance...'



-- Builtup area indexes
CREATE INDEX IF NOT EXISTS idx_builtup_area_industrial ON import.builtup_area USING btree((tags -> 'industrial'));

-- Utility stations indexes
CREATE INDEX IF NOT EXISTS idx_utility_stations_class ON import.utility_stations USING btree(class);
CREATE INDEX IF NOT EXISTS idx_utility_stations_subclass ON import.utility_stations USING btree(subclass);
CREATE INDEX IF NOT EXISTS idx_utility_stations_geometry ON import.utility_stations USING gist(geometry);

-- Shipway indexes
CREATE INDEX IF NOT EXISTS idx_shipway_geometry ON import.shipway_linestring USING gist(geometry);

-- Geonames indexes
CREATE INDEX IF NOT EXISTS idx_geonames_hydrographic_nt ON geonames.hydrographic USING btree(nt) WHERE nt IN ('N', 'C', 'D');
CREATE INDEX IF NOT EXISTS idx_geonames_hydrographic_geom ON geonames.hydrographic USING gist(geometry);
CREATE INDEX IF NOT EXISTS idx_geonames_hydrographic_composite ON geonames.hydrographic(geometry, nt, full_nm_nd);



-- ==============================================================================
-- GIN TRIGRAM INDEXES FOR PATTERN MATCHING OPTIMIZATION
-- ==============================================================================

\echo 'Creating GIN trigram indexes for enhanced pattern matching...'



-- Transportation stations trigram indexes
CREATE INDEX IF NOT EXISTS idx_transportation_stations_name_trgm ON import.transportation_stations 
USING GIN (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_transportation_stations_operator_trgm ON import.transportation_stations 
USING GIN (operator gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_transportation_stations_tags_hstore ON import.transportation_stations 
USING GIN (tags);



-- Transportation label trigram indexes
CREATE INDEX IF NOT EXISTS idx_transportation_label_tags_hstore ON import.transportation_label 
USING GIN (tags);



-- Builtup area trigram indexes
CREATE INDEX IF NOT EXISTS idx_builtup_area_tags_hstore ON import.builtup_area 
USING GIN (tags);

-- Utility stations trigram indexes
CREATE INDEX IF NOT EXISTS idx_utility_stations_name_trgm ON import.utility_stations 
USING GIN (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_utility_stations_operator_trgm ON import.utility_stations 
USING GIN (operator gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_utility_stations_tags_hstore ON import.utility_stations 
USING GIN (tags);

-- Utility stations specific hstore key indexes for oil/gas infrastructure
CREATE INDEX IF NOT EXISTS idx_utility_stations_tags_content ON import.utility_stations 
USING btree ((tags -> 'content'));

CREATE INDEX IF NOT EXISTS idx_utility_stations_tags_type ON import.utility_stations 
USING btree ((tags -> 'type'));

-- Shipway trigram indexes
CREATE INDEX IF NOT EXISTS idx_shipway_linestring_name_trgm ON import.shipway_linestring 
USING GIN (name gin_trgm_ops);

-- Waterway trigram indexes
CREATE INDEX IF NOT EXISTS idx_waterway_tags_hstore ON import.waterway 
USING GIN (tags);

-- Water table trigram indexes
CREATE INDEX IF NOT EXISTS idx_water_tags_hstore ON import.water 
USING GIN (tags);



\echo 'GIN trigram indexes created successfully'

-- Commit trigram indexes to ensure they persist
COMMIT;
\echo 'Trigram indexes committed successfully'

-- Start new transaction for helper functions
BEGIN;

-- ==============================================================================
-- STEP 5A: CREATE HELPER FUNCTIONS FOR TRIGRAM PATTERN MATCHING
-- ==============================================================================

\echo 'Creating helper functions for optimized trigram pattern matching...'



-- Function for fuzzy matching hstore values using trigrams
CREATE OR REPLACE FUNCTION hstore_value_similarity_match(
    hs hstore, 
    search_keys text[], 
    pattern text,
    threshold float DEFAULT 0.3
) RETURNS boolean AS $$
DECLARE
    key text;
BEGIN
    FOREACH key IN ARRAY search_keys
    LOOP
        IF hs ? key AND similarity(hs -> key, pattern) > threshold THEN
            RETURN true;
        END IF;
    END LOOP;
    RETURN false;
END;
$$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;





\echo 'Helper functions created successfully'

-- Commit helper functions
COMMIT;
\echo 'Helper functions committed successfully'

-- ==============================================================================
-- STEP 5: CREATE MATERIALIZED VIEWS FOR HIGH-PERFORMANCE QUERIES
-- ==============================================================================

\echo 'Creating materialized views for optimal CI/CD performance...'

-- Start new transaction for materialized views
BEGIN;





-- Lock infrastructure views
DROP VIEW IF EXISTS rbt.lock_label CASCADE;
CREATE VIEW rbt.lock_label AS 
SELECT 
    osm_id, 
    class, 
    subclass, 
    NULLIF(name,'') as name, 
    NULLIF(name_en,'') as name_en, 
    NULLIF(operator,'') as operator, 
    NULLIF(seamark_name,'') as seamark_name, 
    NULLIF(service,'') as service, 
    NULLIF(access,'') as access,
    NULLIF(tags -> 'lock','') as lock,
    NULLIF(tags -> 'seamark:gate:category','') as gate_category,
    tags, 
    geometry 
FROM import.utility_stations_label 
WHERE 
    (NULLIF(tags -> 'seamark:gate:category','') IS NOT NULL)
    OR (NULLIF(tags -> 'lock','') IS NOT NULL)
    OR subclass IN ('lock_gate', 'gate', 'lock_basin', 'lock');

DROP VIEW IF EXISTS rbt.lock CASCADE;
CREATE VIEW rbt.lock AS
SELECT 
    osm_id, 
    class, 
    subclass,
    intermittent,
    NULLIF(name,'') as name,
    NULLIF(name_en,'') as name_en,
    NULLIF(tags -> 'lock','') as lock,
    NULLIF(tags -> 'lock_name','') as lock_name,
    tags, 
    geometry 
FROM import.waterway
WHERE 
    subclass IN ('lock_gate', 'gate', 'lock', 'lock_basin', 'locks');

-- ==============================================================================
-- PORT SURFACE ENHANCED MATERIALIZED VIEW
-- ==============================================================================

\echo 'Creating rbt.port_surface_enhanced materialized view...'

DO $$
DECLARE
    error_msg TEXT;
BEGIN
    CREATE MATERIALIZED VIEW IF NOT EXISTS rbt.port_surface_enhanced AS
WITH base_ports AS (
    -- Extract and aggregate port data with optimized geometry processing
    SELECT
        b.osm_id,
        NULLIF(b.name, '') AS name,
        b.class,
        b.subclass,
        NULLIF(b.tags -> 'industrial', '') AS industrial,
        NULLIF(b.tags -> 'port', '') AS port,
        NULLIF(b.tags -> 'cargo', '') AS cargo,
        NULLIF(b.tags -> 'access', '') AS access,
        NULLIF(b.tags -> 'port:type', '') AS port_type,
        ST_Area(ST_Transform(b.geometry, 3857))::real AS area,
        -- Use clustering for efficient union operations
        unnest(ST_ClusterWithin(
            ST_MakeValid(b.geometry),
            100  -- 100m clustering for port geometries
        )) as clustered_geom
    FROM import.builtup_area AS b
    WHERE (b.subclass IN ('port', 'harbour'))
        OR (b.subclass = 'industrial' AND (tags -> 'industrial') = 'port')
    GROUP BY b.osm_id, b.name, b.class, b.subclass, b.tags -> 'industrial', b.tags -> 'port', b.tags -> 'cargo', b.tags -> 'access', b.tags -> 'port:type', ST_Area(ST_Transform(b.geometry, 3857))::real
),
union_ports AS (
    SELECT
        osm_id,
        name,
        class,
        subclass,
        industrial,
        port,
        cargo,
        access,
        port_type,
        area,
        (ST_Dump(ST_Union(clustered_geom))).geom::geometry(Polygon, 4326) AS geometry
    FROM base_ports
    GROUP BY osm_id, name, class, subclass, industrial, port, cargo, access, port_type, area
),
ports_with_fid AS (
    -- Add a unique identifier for each row
    SELECT 
        ROW_NUMBER() OVER (ORDER BY osm_id, area DESC) AS fid,
        *
    FROM union_ports
),
ranked_ports AS (
    -- Add ranking based on area within each osm_id
    SELECT
        *,
        RANK() OVER (PARTITION BY osm_id ORDER BY area DESC) AS rank_value
    FROM ports_with_fid
),
ports_with_overlap AS (
    -- Detect overlapping geometries
    SELECT
        a.*,
        CASE 
            WHEN a.rank_value = 1 THEN 1
            ELSE 0
        END AS rank,
        CASE 
            WHEN EXISTS (
                SELECT 1 
                FROM ranked_ports b 
                WHERE ST_Overlaps(b.geometry, a.geometry) 
                AND a.fid != b.fid
            ) THEN 1
            ELSE 0
        END AS overlap
    FROM ranked_ports a
)
SELECT * FROM ports_with_overlap
ORDER BY osm_id, area DESC;

    -- Create indexes on materialized view
    CREATE INDEX IF NOT EXISTS idx_port_surface_enhanced_osm_id ON rbt.port_surface_enhanced USING btree(osm_id);
    CREATE INDEX IF NOT EXISTS idx_port_surface_enhanced_subclass ON rbt.port_surface_enhanced USING btree(subclass);
    CREATE INDEX IF NOT EXISTS idx_port_surface_enhanced_geometry ON rbt.port_surface_enhanced USING gist(geometry);
    CREATE INDEX IF NOT EXISTS idx_port_surface_enhanced_rank ON rbt.port_surface_enhanced USING btree(rank);

    RAISE NOTICE 'rbt.port_surface_enhanced materialized view created successfully';

EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create rbt.port_surface_enhanced materialized view: %', error_msg;
    RAISE;
END $$;

-- Commit this materialized view
COMMIT;
\echo 'rbt.port_surface_enhanced materialized view committed'

-- Start new transaction for next materialized views
BEGIN;



-- ==============================================================================
-- GEONAMES HYDROGRAPHIC ENHANCED MATERIALIZED VIEW
-- ==============================================================================

\echo 'Creating rbt.geonames_hydrographic_enhanced materialized view...'

DO $$
DECLARE
    error_msg TEXT;
BEGIN
    CREATE MATERIALIZED VIEW IF NOT EXISTS rbt.geonames_hydrographic_enhanced AS
SELECT DISTINCT ON (h.geometry)
	h.full_nm_nd AS name,
	h.desig_cd,
	CASE 
		WHEN h.desig_cd = 'BAY' THEN 'bay(s)'
		WHEN h.desig_cd = 'BGHT' THEN 'bight(s)'
		WHEN h.desig_cd = 'BNK' THEN 'bank(s)'
		WHEN h.desig_cd = 'BNKR' THEN 'stream bank'
		WHEN h.desig_cd = 'BNKX' THEN 'section of bank'
		WHEN h.desig_cd = 'BOG' THEN 'bog(s)'
		WHEN h.desig_cd = 'BSND' THEN 'Basin'
		WHEN h.desig_cd = 'BSNP' THEN 'Basin'
		WHEN h.desig_cd = 'BSNU' THEN 'Basin'
		WHEN h.desig_cd = 'CAPG' THEN 'icecap'
		WHEN h.desig_cd = 'CHN' THEN 'channel'
		WHEN h.desig_cd = 'CHNL' THEN 'lake channel(s)'
		WHEN h.desig_cd = 'CHNM' THEN 'marine channel'
		WHEN h.desig_cd = 'CNFL' THEN 'confluence'
		WHEN h.desig_cd = 'CNL' THEN 'canal'
		WHEN h.desig_cd = 'CNLA' THEN 'aqueduct'
		WHEN h.desig_cd = 'COVE' THEN 'cove(s)'
		WHEN h.desig_cd = 'CRKT' THEN 'tidal creek(s)'
		WHEN h.desig_cd = 'DOMG' THEN 'icecap dome'
		WHEN h.desig_cd = 'DPRG' THEN 'icecap depression'
		WHEN h.desig_cd = 'ESTY' THEN 'estuary'
		WHEN h.desig_cd = 'FISH' THEN 'fishing area'
		WHEN h.desig_cd = 'FJD' THEN 'fjord(s)'
		WHEN h.desig_cd = 'FLLS' THEN 'waterfall(s)'
		WHEN h.desig_cd = 'FLLSX' THEN 'section of waterfall(s)'
		WHEN h.desig_cd = 'FLTM' THEN 'mud flat(s)'
		WHEN h.desig_cd = 'FLTT' THEN 'tidal flat(s)'
		WHEN h.desig_cd = 'GLCR' THEN 'glacier(s)'
		WHEN h.desig_cd = 'GULF' THEN 'gulf'
		WHEN h.desig_cd = 'GYSR' THEN 'geyser'
		WHEN h.desig_cd = 'HBR' THEN 'harbor(s)'
		WHEN h.desig_cd = 'HBRX' THEN 'section of harbor'
		WHEN h.desig_cd = 'INLT' THEN 'inlet'
		WHEN h.desig_cd = 'LBED' THEN 'lake bed(s)'
		WHEN h.desig_cd = 'LGN' THEN 'lagoon(s)'
		WHEN h.desig_cd = 'LGNX' THEN 'section of lagoon'
		WHEN h.desig_cd = 'LK' THEN 'lake'
		WHEN h.desig_cd = 'LKC' THEN 'crater lake(s)'
		WHEN h.desig_cd = 'LKI' THEN 'intermittent lake(s)'
		WHEN h.desig_cd = 'LKN' THEN 'salt lake(s)'
		WHEN h.desig_cd = 'LKNI' THEN 'intermittent salt lake(s)'
		WHEN h.desig_cd = 'LKO' THEN 'oxbow lake'
		WHEN h.desig_cd = 'LKOI' THEN 'intermittent oxbow lake'
		WHEN h.desig_cd = 'LKS' THEN 'lakes'
		WHEN h.desig_cd = 'LKSB' THEN 'underground lake'
		WHEN h.desig_cd = 'LKX' THEN 'section of lake'
		WHEN h.desig_cd = 'MFGN' THEN 'salt evaporation ponds'
		WHEN h.desig_cd = 'MGV' THEN 'mangrove swamp'
		WHEN h.desig_cd = 'MOOR' THEN 'moor(s)'
		WHEN h.desig_cd = 'MRSH' THEN 'marsh(es)'
		WHEN h.desig_cd = 'MRSHN' THEN 'salt marsh'
		WHEN h.desig_cd = 'NRWS' THEN 'narrows'
		WHEN h.desig_cd = 'OCN' THEN 'ocean'
		WHEN h.desig_cd = 'OVF' THEN 'overfalls'
		WHEN h.desig_cd = 'PND' THEN 'pond(s)'
		WHEN h.desig_cd = 'PNDI' THEN 'intermittent pond(s)'
		WHEN h.desig_cd = 'PNDN' THEN 'salt pond(s)'
		WHEN h.desig_cd = 'PNDNI' THEN 'intermittent salt pond(s)'
		WHEN h.desig_cd = 'PNDSF' THEN 'fishponds'
		WHEN h.desig_cd = 'POOL' THEN 'pool(s)'
		WHEN h.desig_cd = 'POOLI' THEN 'intermittent pool'
		WHEN h.desig_cd = 'RCH' THEN 'reach'
		WHEN h.desig_cd = 'RDGG' THEN 'icecap ridge'
		WHEN h.desig_cd = 'RDST' THEN 'roadstead'
		WHEN h.desig_cd = 'RF' THEN 'reef(s)'
		WHEN h.desig_cd = 'RFC' THEN 'coral reef(s)'
		WHEN h.desig_cd = 'RFX' THEN 'section of reef'
		WHEN h.desig_cd = 'RPDS' THEN 'rapids'
		WHEN h.desig_cd = 'RSV' THEN 'reservoir(s)'
		WHEN h.desig_cd = 'RSVI' THEN 'intermittent reservoir'
		WHEN h.desig_cd = 'RSVT' THEN 'water tank'
		WHEN h.desig_cd = 'RVN' THEN 'ravine(s)'
		WHEN h.desig_cd = 'SBKH' THEN 'sabkha(s)'
		WHEN h.desig_cd = 'SD' THEN 'sound'
		WHEN h.desig_cd = 'SEA' THEN 'sea'
		WHEN h.desig_cd = 'SHOL' THEN 'shoal(s)'
		WHEN h.desig_cd = 'SPNG' THEN 'spring(s)'
		WHEN h.desig_cd = 'SPNS' THEN 'sulphur spring(s)'
		WHEN h.desig_cd = 'SPNT' THEN 'hot spring(s)'
		WHEN h.desig_cd = 'STM' THEN 'stream(s)'
		WHEN h.desig_cd = 'STMA' THEN 'anabranch'
		WHEN h.desig_cd = 'STMB' THEN 'stream bend'
		WHEN h.desig_cd = 'STMC' THEN 'canalized stream'
		WHEN h.desig_cd = 'STMD' THEN 'distributary(-ies)'
		WHEN h.desig_cd = 'STMH' THEN 'headwaters'
		WHEN h.desig_cd = 'STMI' THEN 'intermittent stream'
		WHEN h.desig_cd = 'STMIX' THEN 'section of intermittent stream'
		WHEN h.desig_cd = 'STMM' THEN 'stream mouth(s)'
		WHEN h.desig_cd = 'STMQ' THEN 'abandoned watercourse'
		WHEN h.desig_cd = 'STMSB' THEN 'lost river'
		WHEN h.desig_cd = 'STMX' THEN 'section of stream'
		WHEN h.desig_cd = 'STRT' THEN 'strait'
		WHEN h.desig_cd = 'SWMP' THEN 'swamp'
		WHEN h.desig_cd = 'SYSI' THEN 'irrigation system'
		WHEN h.desig_cd = 'TNLC' THEN 'canal tunnel'
		WHEN h.desig_cd = 'WAD' THEN 'wadi(s)'
		WHEN h.desig_cd = 'WADB' THEN 'wadi bend'
		WHEN h.desig_cd = 'WADJ' THEN 'wadi junction'
		WHEN h.desig_cd = 'WADM' THEN 'wadi mouth'
		WHEN h.desig_cd = 'WADX' THEN 'section of wadi'
		WHEN h.desig_cd = 'WHRL' THEN 'whirlpool'
		WHEN h.desig_cd = 'WLL' THEN 'water well(s)'
		WHEN h.desig_cd = 'WLLQ' THEN 'abandoned well'
		WHEN h.desig_cd = 'WTLD' THEN 'wetland'
		WHEN h.desig_cd = 'WTLDI' THEN 'intermittent wetland'
		WHEN h.desig_cd = 'WTRH' THEN 'waterhole(s)'
		ELSE NULL
	END AS class,
	h.name_rank,
	h.display,
	-- Use optimized lateral join for water intersection calculation
	CASE WHEN w_intersect.water_area_sum IS NOT NULL THEN 'Y' ELSE 'N' END AS osm_intersect,
	-- Add water area if there's an intersection
	ST_Area(ST_Transform(h.geometry, 3857))::real + COALESCE(w_intersect.water_area_sum, 0) AS area,
	h.geometry
FROM geonames.hydrographic h
-- LATERAL JOIN calculates water intersections once per row
LEFT JOIN LATERAL (
	SELECT SUM(ST_Area(ST_Transform(w.geometry, 3857))::real) AS water_area_sum
	FROM rbt.water w
	WHERE ST_Intersects(h.geometry, w.geometry)
) w_intersect ON true
WHERE h.nt IN ('N', 'C', 'D')
ORDER BY h.geometry, 
	CASE 
		WHEN h.nt = 'C' AND h.full_nm_nd IS NOT NULL THEN 1
		WHEN h.nt = 'N' AND h.full_nm_nd IS NOT NULL THEN 2
		WHEN h.nt = 'D' AND h.full_nm_nd IS NOT NULL THEN 3
		WHEN h.nt = 'C' AND h.full_nm_nd IS NULL THEN 4
		WHEN h.nt = 'N' AND h.full_nm_nd IS NULL THEN 5
		WHEN h.nt = 'D' AND h.full_nm_nd IS NULL THEN 6
		ELSE 7
	END;

    -- Create indexes on materialized view
    CREATE INDEX IF NOT EXISTS idx_geonames_hydrographic_enhanced_class ON rbt.geonames_hydrographic_enhanced USING btree(class);
    CREATE INDEX IF NOT EXISTS idx_geonames_hydrographic_enhanced_area ON rbt.geonames_hydrographic_enhanced USING btree(area);
    CREATE INDEX IF NOT EXISTS idx_geonames_hydrographic_enhanced_geometry ON rbt.geonames_hydrographic_enhanced USING gist(geometry);
    CREATE INDEX IF NOT EXISTS idx_geonames_hydrographic_enhanced_name ON rbt.geonames_hydrographic_enhanced USING btree(name) WHERE name IS NOT NULL;

    RAISE NOTICE 'rbt.geonames_hydrographic_enhanced materialized view created successfully';

EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create rbt.geonames_hydrographic_enhanced materialized view: %', error_msg;
    RAISE;
END $$;

-- Commit this materialized view
COMMIT;
\echo 'rbt.geonames_hydrographic_enhanced materialized view committed'

\echo 'All cultural materialized views created successfully'

-- Start new transaction for regular views
BEGIN;

-- ==============================================================================
-- STEP 6: CREATE REGULAR VIEWS AND TABLES
-- ==============================================================================

\echo 'Creating regular views and tables...'

-- Ferry view
DROP VIEW IF EXISTS rbt.ferry CASCADE;
CREATE VIEW rbt.ferry as
select
	osm_id,
	is_bridge,
	is_tunnel,
	NULLIF(name,'') as name,
	NULLIF(name_en,'') as name_en,
	NULLIF(short_name,'') as short_name,
	NULLIF(service,'') as service,
	NULLIF(usage,'') as usage,
	subclass,
	geometry
from import.shipway_linestring;





DROP VIEW IF EXISTS rbt.port_label CASCADE;
CREATE VIEW rbt.port_label AS
SELECT
    osm_id,
    name,
    class,
    subclass,
    industrial,
    port,
    cargo,
    access,
    port_type,
    area,
    rank,
    overlap,
    ST_PointOnSurface(geometry)::geometry(Point,4326) as geometry
FROM rbt.port_surface_enhanced;

-- Hydrographic zoom level views
DROP VIEW IF EXISTS rbt.geonames_hydrographic_z2 CASCADE;
CREATE VIEW rbt.geonames_hydrographic_z2 AS
SELECT * FROM rbt.geonames_hydrographic
WHERE class IN ('ocean', 'sea');

DROP VIEW IF EXISTS rbt.geonames_hydrographic_z3 CASCADE;
CREATE VIEW rbt.geonames_hydrographic_z3 AS
SELECT * FROM rbt.geonames_hydrographic
WHERE class IN ('ocean', 'sea', 'gulf');

DROP VIEW IF EXISTS rbt.geonames_hydrographic_z4 CASCADE;
CREATE VIEW rbt.geonames_hydrographic_z4 AS
SELECT * FROM rbt.geonames_hydrographic
WHERE area >= 12417500000;

DROP VIEW IF EXISTS rbt.geonames_hydrographic_z5 CASCADE;
CREATE VIEW rbt.geonames_hydrographic_z5 AS
SELECT * FROM rbt.geonames_hydrographic
WHERE area >= 9468380000;

DROP VIEW IF EXISTS rbt.geonames_hydrographic_z6 CASCADE;
CREATE VIEW rbt.geonames_hydrographic_z6 AS
SELECT * FROM rbt.geonames_hydrographic
WHERE area >= 5608210000;

DROP VIEW IF EXISTS rbt.geonames_hydrographic_z7 CASCADE;
CREATE VIEW rbt.geonames_hydrographic_z7 AS
SELECT * FROM rbt.geonames_hydrographic
WHERE area >= 1406880000;

DROP VIEW IF EXISTS rbt.geonames_hydrographic_z8 CASCADE;
CREATE VIEW rbt.geonames_hydrographic_z8 AS
SELECT * FROM rbt.geonames_hydrographic
WHERE area >= 24216600;

DROP VIEW IF EXISTS rbt.geonames_hydrographic_z9 CASCADE;
CREATE VIEW rbt.geonames_hydrographic_z9 AS
SELECT * FROM rbt.geonames_hydrographic
WHERE area >= 11804400;

DROP VIEW IF EXISTS rbt.geonames_hydrographic_z10 CASCADE;
CREATE VIEW rbt.geonames_hydrographic_z10 AS
SELECT * FROM rbt.geonames_hydrographic
WHERE area > 0;

\echo 'Regular views created successfully'

-- ==============================================================================
-- ADMINISTRATIVE BOUNDARY VIEWS
-- ==============================================================================

\echo 'Creating administrative boundary views...'

DROP VIEW IF EXISTS rbt.adm0_labels CASCADE;
CREATE VIEW rbt.adm0_labels AS
SELECT
    a.adm0_name,
    a.adm0_name1,
    a.status_cd,
    a.status_nm,
    b.full_nm_nd AS gns_full_name,
    b.name_rank AS gns_name_rank,
    b.desig_cd AS gns_desig_cd,
    c.abbrev AS ne_abbrev,
    c.formal_en AS ne_formal_en,
    c.name AS ne_name,
    c.name_en AS ne_name_en,
    c.name_long AS ne_name_long,
    ST_Area(ST_Transform(d.geometry, 3857)) AS area,
    a.geometry
FROM fieldmap.adm0_labels a
INNER JOIN geonames.administrative_regions b
    ON b.full_nm_nd = a.adm0_name1
INNER JOIN naturalearth.ne_10m_admin_0_countries c
    ON c.name = a.adm0_name1
INNER JOIN fieldmap.adm0 d
    ON d.adm0_id = a.adm0_id;

DROP VIEW IF EXISTS rbt.adm0_lines CASCADE;
CREATE VIEW rbt.adm0_lines AS
	SELECT
		cc1,
		cc2,
		country1,
		country2,
		label,
		rank,
		status,
		geometry
	FROM fieldmap.adm0_lines;

DROP VIEW IF EXISTS rbt.adm1_labels CASCADE;
CREATE VIEW rbt.adm1_labels AS
	SELECT
		adm1_id,
		adm1_name,
		adm1_name1,
		iso_3,
		src_lang,
		src_lang1,
        ST_Area(ST_Transform(geometry, 3857))::real AS area,
        ST_PointOnSurface(geometry)::geometry(Point, 4326) AS geometry
	FROM fieldmap.adm1
    WHERE geometry IS NOT NULL;

DROP VIEW IF EXISTS rbt.adm1_lines CASCADE;
CREATE VIEW rbt.adm1_lines AS
	SELECT
		iso_3,
		geometry
	FROM fieldmap.adm1_lines;

DROP VIEW IF EXISTS rbt.adm2_labels CASCADE;
CREATE VIEW rbt.adm2_labels AS
	SELECT
		adm2_id,
		adm2_name,
		adm2_name1,
		iso_3,
		src_lang,
		src_lang1,
		geometry
	FROM fieldmap.adm2_labels;

DROP VIEW IF EXISTS rbt.adm2_lines CASCADE;
CREATE VIEW rbt.adm2_lines AS
	SELECT
		iso_3,
		geometry
	FROM fieldmap.adm2_lines;

-- ==============================================================================
-- POPULATED PLACES VIEWS
-- ==============================================================================

\echo 'Creating populated places views...'

-- View for zoom levels 3-6 (rank < 8)
DROP VIEW IF EXISTS rbt.populated_places_z3 CASCADE;
CREATE VIEW rbt.populated_places_z3 AS
SELECT
  ne_id,
  NULLIF(name, '') as name,
  NULLIF(name_en, '') as name_en,
  NULLIF(class, '') as class,
  NULLIF(rank, '') as rank,
  NULLIF(capital, '') as capital,
  NULLIF(population, '') as population,
  geometry
FROM import.places
WHERE class in ('city', 'town', 'village', 'hamlet')
  AND rank < 8;

-- View for zoom levels 7-8 (rank < 11)
DROP VIEW IF EXISTS rbt.populated_places_z7 CASCADE;
CREATE VIEW rbt.populated_places_z7 AS
SELECT
  ne_id,
  NULLIF(name, '') as name,
  NULLIF(name_en, '') as name_en,
  NULLIF(class, '') as class,
  NULLIF(rank, '') as rank,
  NULLIF(capital, '') as capital,
  NULLIF(population, '') as population,
  geometry
FROM import.places
WHERE class in ('city', 'town', 'village', 'hamlet')
  AND rank < 11;

-- View for zoom levels 9-11 (rank < 12)
DROP VIEW IF EXISTS rbt.populated_places_z9 CASCADE;
CREATE VIEW rbt.populated_places_z9 AS
SELECT
  ne_id,
  NULLIF(name, '') as name,
  NULLIF(name_en, '') as name_en,
  NULLIF(class, '') as class,
  NULLIF(rank, '') as rank,
  NULLIF(capital, '') as capital,
  NULLIF(population, '') as population,
  geometry
FROM import.places
WHERE class in ('city', 'town', 'village', 'hamlet')
  AND rank < 12;

-- View for zoom levels 12+ (no rank filter)
DROP VIEW IF EXISTS rbt.populated_places CASCADE;
CREATE VIEW rbt.populated_places AS
SELECT
  ne_id,
  NULLIF(name, '') as name,
  NULLIF(name_en, '') as name_en,
  NULLIF(class, '') as class,
  NULLIF(rank, '') as rank,
  NULLIF(capital, '') as capital,
  NULLIF(population, '') as population,
  geometry
FROM import.places
where class in ('city', 'town', 'village', 'hamlet');

-- ==============================================================================
-- BUILDING VIEWS
-- ==============================================================================

-- \echo 'Creating building views...'

-- CREATE TABLE rbt.building AS
-- SELECT 
--     b.id,
--     b.names,
--     b.class,
--     b.level,
--     b.has_parts,
--     b.height,
--     b.num_floors,
--     b.geometry
-- FROM overture.building b
-- LEFT JOIN overture.buildingpart bp ON b.id = bp.building_id;

--CREATE VIEW rbt.building_z10 AS
--SELECT * FROM rbt.building
--WHERE ST_Area(ST_Transform(geometry, 3857)) >= 5000;

--CREATE VIEW rbt.building_z11 AS
--SELECT * FROM rbt.building
--WHERE ST_Area(ST_Transform(geometry, 3857)) >= 2500;

--CREATE VIEW rbt.building_z12 AS
--SELECT * FROM rbt.building
--WHERE ST_Area(ST_Transform(geometry, 3857)) >= 1500;

-- ==============================================================================
-- SPORTS AND RECREATION VIEWS
-- ==============================================================================

\echo 'Creating sports and recreation views...'

DROP VIEW IF EXISTS rbt.stadium_surface CASCADE;
CREATE VIEW rbt.stadium_surface AS
SELECT
    osm_id,
    NULLIF(name,'') as name,
    NULLIF(name_en,'') as name_en,
    class,
    subclass,
    ST_Area(ST_Transform(geometry, 3857))::real as area,
    geometry
FROM import.builtup_area WHERE subclass IN ('sports_centre','stadium');

DROP VIEW IF EXISTS rbt.stadium_labels CASCADE;
CREATE VIEW rbt.stadium_labels AS
SELECT
    osm_id,
    name,
    name_en,
    class,
    subclass,
    ST_Area(ST_Transform(geometry, 3857))::real as area,
    ST_PointOnSurface(geometry)::geometry(Point, 4326) as geometry
FROM rbt.stadium_surface;

DROP VIEW IF EXISTS rbt.sports_ground CASCADE;
CREATE VIEW rbt.sports_ground AS
SELECT 
    osm_id,
    NULLIF(name, '') as name,
    NULLIF(name_en, '') as name_en,
    NULLIF(landuse, '') as landuse,
    NULLIF(surface, '') as surface,
    NULLIF(ownership, '') as ownership,
    NULLIF(owner, '') as owner,
    NULLIF(operator, '') as operator,
    NULLIF(access, '') as access,
    class,
    subclass,
    ST_Area(ST_Transform(geometry, 3857))::real as area,
    NULLIF(tags, '') as tags,
    geometry
FROM 
    public.park_polygon
WHERE 
    subclass = 'pitch';

DROP VIEW IF EXISTS rbt.golf_course CASCADE;
CREATE VIEW rbt.golf_course AS
SELECT 
   osm_id,
   NULLIF(name, '') as name,
   NULLIF(name_en, '') as name_en,
   NULLIF(landuse, '') as landuse,
   NULLIF(surface, '') as surface,
   NULLIF(ownership, '') as ownership,
   NULLIF(owner, '') as owner,
   NULLIF(operator, '') as operator,
   NULLIF(access, '') as access,
   class,
   subclass,
   ST_Area(ST_Transform(geometry, 3857))::real as area,
   NULLIF(tags, '') as tags,
   geometry
FROM 
   public.park_polygon
WHERE 
   subclass = 'golf_course';

-- ==============================================================================
-- MILITARY AND SECURITY INFRASTRUCTURE
-- ==============================================================================

\echo 'Creating military and security views...'

DROP VIEW IF EXISTS rbt.radar_point CASCADE;
CREATE VIEW rbt.radar_point AS 
SELECT
    osm_id,
    class,
    subclass,
    NULLIF(name,'') as name,
    NULLIF(name_en,'') as name_en,
    NULLIF(operator,'') as operator,
    NULLIF(seamark_name,'') as seamark_name,
    NULLIF(tower_type,'') as tower_type,
    NULLIF(tower_construction,'') as tower_construction,
    NULLIF(mast_type,'') as mast_type,
    NULLIF(service,'') as service,
    NULLIF(height,'') as height,
    NULLIF(access,'') as access,
	NULLIF(tags -> 'military','') as military,
	NULLIF(tags -> 'ele','') as ele,
	NULLIF(tags -> 'airmark','') as airmark,
    NULLIF(tags -> 'radar','') as radar,
	NULLIF(tags -> 'description','') as description,
    geometry
FROM import.utility_stations WHERE tower_type = 'radar';

DROP VIEW IF EXISTS rbt.us_military_installations CASCADE;
CREATE VIEW rbt.us_military_installations AS
SELECT
  shape_area AS area,
  NULLIF(sitereportingcomponent, '') AS component,
  NULLIF(countryname, '') AS country,
  NULLIF(isjointbase, '') AS jointbase,
  NULLIF(siteoperationalstatus, '') AS operstatus,
  NULLIF(sitename, '') AS sitename,
  NULLIF(statenamecode, '') AS state,
  geometry
FROM mirta.us_military_installations;

DROP VIEW IF EXISTS rbt.us_military_installations_labels CASCADE;
CREATE VIEW rbt.us_military_installations_labels AS
SELECT
  area,
  component,
  country,
  jointbase,
  operstatus,
  sitename,
  state,
  ST_PointOnSurface(geometry) AS geometry
FROM rbt.us_military_installations;

-- ==============================================================================
-- CEMETERY VIEWS
-- ==============================================================================

\echo 'Creating cemetery views...'

DROP VIEW IF EXISTS rbt.cemetery CASCADE;
CREATE VIEW rbt.cemetery AS
WITH dumped AS (
    SELECT
        osm_id,
        NULLIF(name, '') AS name,
        NULLIF(class, '') AS class,
        NULLIF(subclass, '') AS subclass,
        NULLIF(tags -> 'religion', '') AS religion,
        NULLIF(tags -> 'denomination', '') AS denomination,
        NULLIF(tags -> 'cemetery', '') AS cemetery,
        ST_Area(ST_Transform(geometry, 3857))::real AS area,
        (ST_Dump(geometry)).geom::geometry(Polygon, 3857) AS geometry  -- Extract geometry from ST_Dump
    FROM
        import.builtup_area
    WHERE geometry IS NOT NULL 
      AND (subclass ILIKE '%cemet%y' OR subclass ILIKE '%grav%yard%' OR subclass IN ('grave','gravesite'))
),
base_data AS (
    SELECT
        row_number() OVER (order by geometry) AS fid,
        osm_id,
        name,
        class,
        subclass,
        religion,
        denomination,
        cemetery,
        area,
        ST_Area(ST_Transform(geometry, 3857))::real AS area_part,
        geometry
    FROM dumped
),
with_ranking AS (
    SELECT
        *,
        CASE 
            WHEN RANK() OVER (PARTITION BY name ORDER BY area_part DESC) = 1 
            THEN 1 
            ELSE 0 
        END as rank
    FROM base_data
),
with_containment AS (
    SELECT
        a.*,
        CASE 
            WHEN EXISTS (
                SELECT 1 FROM with_ranking b 
                WHERE ST_ContainsProperly(b.geometry, a.geometry) 
                  AND a.fid != b.fid
            ) THEN 1
            ELSE 0
        END as contained
    FROM with_ranking a
)
SELECT 
    fid,
    osm_id,
    name,
    class,
    subclass,
    religion,
    denomination,
    cemetery,
    area,
    area_part,
    rank,
    contained,
    geometry
FROM with_containment
WHERE NOT (contained = 1);

DROP VIEW IF EXISTS rbt.cemetery_label CASCADE;
CREATE VIEW rbt.cemetery_label AS
SELECT 
    fid,
    osm_id,
    name,
    class,
    subclass,
    religion,
    denomination,
    cemetery,
    area,
    area_part,
    rank,
    contained,
    ST_PointOnSurface(geometry)::geometry(Point, 4326) AS geometry
FROM rbt.cemetery
WHERE NOT (
    name IS NULL 
    AND religion IS NULL
);

-- ==============================================================================
-- HYDROCARBON INFRASTRUCTURE VIEWS
-- ==============================================================================

\echo 'Creating hydrocarbon infrastructure views...'

-- Main hydrocarbon field view with classification logic
DROP VIEW IF EXISTS rbt.hydrocarbon_field CASCADE;
CREATE VIEW rbt.hydrocarbon_field AS
WITH classified_hydrocarbons AS (
    SELECT 
        id,
        osm_id,
        class,
        -- Apply classification logic based on name patterns
        CASE
            -- Terminal classifications using trigram similarity
            WHEN subclass IN ('oil','wellsite','storage_tank') AND (
                name % 'terminal' 
                OR name % 'storage' 
                OR name % 'depot' 
                OR name % 'farm'
            ) THEN 'oil_terminal'
            
            -- Refinery classifications using trigram similarity
            WHEN subclass IN ('oil','wellsite','storage_tank') AND (
                name % 'refinery' 
                OR name % 'facility' 
                OR name % 'plant'
            ) THEN 'oil_refinery'
            
            -- Station classifications using trigram similarity
            WHEN subclass IN ('oil','wellsite') AND name % 'station' THEN 'station'
            

            
            -- Field classifications using trigram similarity
            WHEN subclass = 'wellsite' AND (
                name % 'area' 
                OR name % 'field'
            ) THEN 'oilfield'
            
            -- Keep existing specific classifications
            WHEN subclass IN ('oil_terminal', 'oil_refinery', 'oilfield') THEN subclass
            
            -- Default hydrocarbon classification for storage tanks with oil content
            WHEN subclass = 'storage_tank' AND tags -> 'content' = 'oil' THEN 'oil_storage'
            
            ELSE subclass
        END AS subclass,
        
        NULLIF(name, '') as name,
        NULLIF(name_en, '') as name_en,
        NULLIF(operator, '') as operator,
        
        -- Derive substance from multiple possible sources
        COALESCE(
            substance,
            CASE 
                WHEN tags -> 'type' ILIKE '%oil%' THEN tags -> 'type'
                WHEN tags -> 'content' IS NOT NULL THEN tags -> 'content'
                ELSE NULL 
            END
        ) AS substance,
        
        tags -> 'ref' as ref,
        tags -> 'access' as access,
        tags -> 'type' as type,
        tags -> 'content' as content,
        ST_Area(ST_Transform(geometry, 3857))::real as area,
        tags,
        geometry
    FROM import.utility_stations
    WHERE 
        -- Include oil/gas related features
        subclass IN ('oil', 'wellsite', 'oilfield', 'oil_terminal', 'oil_refinery', 'refinery')
        OR (subclass = 'storage_tank' AND tags -> 'content' IN ('oil', 'gas', 'fuel'))
        -- Use trigram similarity for pattern matching
        OR name % 'oil'
        OR name % 'refinery'
        OR name % 'terminal'
        OR tags -> 'content' % 'oil'
        OR tags -> 'type' % 'oil'
)
SELECT 
    id,
    osm_id,
    class,
    subclass,
    name,
    name_en,
    operator,
    substance,
    ref,
    access,
    type,
    area,
    geometry
FROM classified_hydrocarbons
WHERE 
    -- Filter out small unnamed features
    NOT (
        subclass IN ('oil','wellsite')
        AND name IS NULL 
        AND ref IS NULL
        AND (
            area < 1000000 
            OR (area < 2000000 AND operator IS NULL)
        )
    );

-- Hydrocarbon label view with point geometry for cartographic display
DROP VIEW IF EXISTS rbt.hydrocarbon_label CASCADE;
CREATE VIEW rbt.hydrocarbon_label AS
SELECT 
    id,
    osm_id,
    class,
    subclass,
    name,
    name_en,
    operator,
    substance,
    ref,
    access,
    type,
    area,
    ST_PointOnSurface(geometry)::geometry(Point,3857) as geometry
FROM rbt.hydrocarbon_field
WHERE 
    -- Only create labels for named or referenced features
    name IS NOT NULL 
    OR ref IS NOT NULL
    OR (area > 5000000 AND operator IS NOT NULL);  -- Also label large operator facilities

-- ==============================================================================
-- GRAIN STORAGE FACILITIES
-- ==============================================================================

\echo 'Creating grain storage facility views...'

-- Grain storage facilities (silos) containing grain or crop products

-- Surface/polygon grain storage facilities
DROP VIEW IF EXISTS rbt.grain_srf CASCADE;
CREATE VIEW rbt.grain_srf AS
SELECT 
    osm_id, 
    class, 
    subclass, 
    NULLIF(name,'') as name, 
    NULLIF(name_en,'') as name_en, 
    tags -> 'height' as height, 
    tags -> 'content' as content, 
    ST_Area(ST_Transform(geometry, 3857))::real as area,
    tags,
    geometry
FROM import.utility_stations 
WHERE 
    subclass = 'silo' 
    AND tags -> 'content' IN ('grain','crop','silage','wheat','crops','feed','grit');

-- Point grain storage facilities from labeled points
DROP VIEW IF EXISTS rbt.grain_point CASCADE;
CREATE VIEW rbt.grain_point AS
SELECT 
    osm_id, 
    class, 
    subclass, 
    NULLIF(name,'') as name, 
    NULLIF(name_en,'') as name_en, 
    -- Handle both direct column and tags-based height
    COALESCE(
        NULLIF(height,''), 
        tags -> 'height'
    ) as height,
    -- Handle both direct column and tags-based content  
    COALESCE(
        content,
        tags -> 'content'
    ) as content,
    tags,
    geometry
FROM import.utility_stations_label 
WHERE 
    subclass = 'silo' 
    AND (
        content IN ('grain','crop')
        OR tags -> 'content' IN ('grain','crop','silage','wheat','crops','feed','grit')
    );

-- Point geometry derived from surface features for labeling
DROP VIEW IF EXISTS rbt.grain_srf_pnt CASCADE;
CREATE VIEW rbt.grain_srf_pnt AS
SELECT 
    osm_id, 
    class, 
    subclass, 
    name, 
    name_en, 
    height, 
    content, 
    area,
    tags,
    ST_PointOnSurface(geometry)::geometry(Point,3857) as geometry
FROM rbt.grain_srf;

-- Combined view of all grain storage points (from both sources)
DROP VIEW IF EXISTS rbt.grain_all_points CASCADE;
CREATE VIEW rbt.grain_all_points AS
SELECT * FROM rbt.grain_point
UNION ALL
SELECT 
    osm_id, 
    class, 
    subclass, 
    name, 
    name_en, 
    height, 
    content,
    tags,
    geometry
FROM rbt.grain_srf_pnt;

-- ==============================================================================
-- DAM INFRASTRUCTURE VIEWS
-- ==============================================================================

\echo 'Creating dam infrastructure views...'

CREATE MATERIALIZED VIEW IF NOT EXISTS rbt.dam_curve AS
SELECT
    NULLIF(name, '') AS name,
    NULLIF(name_en, '') AS name_en,
    subclass AS fclass,
    CASE 
        WHEN LOWER(tags -> 'surface') IN (
            'asphalt', 'cement', 'cobblestone', 'concrete', 'concrete:lanes', 'concrete:plates', 
            'dam', 'metal', 'metal_grid', 'paved', 'paving_stones', 'pebblestone', 'rock', 
            'sett', 'stepping_stones', 'stone', 'unhewn_cobblestone', 'wood'
        ) THEN 'hard'
        WHEN LOWER(tags -> 'surface') IN (
            'compacted', 'dirt', 'earth', 'fine_gravel', 'grass', 'gravel', 'ground', 
            'mud', 'sand', 'unpaved'
        ) THEN 'loose'
        WHEN tags -> 'surface' IS NULL OR tags -> 'surface' = '' THEN NULL
        ELSE NULL  -- For any unrecognized surface types (e.g., 'bing')
    END AS surface,
    ST_Length(geometry) AS length,
    geometry
FROM import.waterway
WHERE subclass ILIKE '%dam%' OR subclass ILIKE '%weir%';

CREATE INDEX IF NOT EXISTS idx_dam_curve_geometry ON rbt.dam_curve USING gist(geometry);

CREATE MATERIALIZED VIEW IF NOT EXISTS rbt.dam_surface AS
SELECT
    NULLIF(name, '') AS name,
    NULLIF(name_en, '') AS name_en,
    subclass AS fclass,
    CASE 
        WHEN LOWER(tags -> 'surface') IN (
            'asphalt', 'cement', 'cobblestone', 'concrete', 'concrete:lanes', 'concrete:plates', 
            'dam', 'metal', 'metal_grid', 'paved', 'paving_stones', 'pebblestone', 'rock', 
            'sett', 'stepping_stones', 'stone', 'unhewn_cobblestone', 'wood'
        ) THEN 'hard'
        WHEN LOWER(tags -> 'surface') IN (
            'compacted', 'dirt', 'earth', 'fine_gravel', 'grass', 'gravel', 'ground', 
            'mud', 'sand', 'unpaved'
        ) THEN 'loose'
        WHEN tags -> 'surface' IS NULL OR tags -> 'surface' = '' THEN NULL
        ELSE NULL  -- For any unrecognized surface types (e.g., 'bing')
    END AS surface,
    ST_Area(ST_Transform(geometry, 3857))::real AS area,
    geometry
FROM import.water
WHERE subclass ILIKE '%dam%' OR subclass ILIKE '%weir%';

CREATE INDEX IF NOT EXISTS idx_dam_surface_geometry ON rbt.dam_surface USING gist(geometry);

CREATE MATERIALIZED VIEW IF NOT EXISTS rbt.dam_label AS
WITH intersections AS (
    SELECT 
        wl.fid,
        NULLIF(wl.name, '') AS name,
        NULLIF(wl.name_en, '') AS name_en,
        wl.subclass,
        wl.geometry,
        CASE 
            WHEN EXISTS (
                SELECT 1 FROM rbt.water w 
                WHERE ST_Intersects(wl.geometry, w.geometry)
            ) OR EXISTS (
                SELECT 1 FROM rbt.waterway ww 
                WHERE ST_Intersects(wl.geometry, ww.geometry)
            ) THEN 'Y'
            ELSE 'N'
        END AS calculated_water_intersect,
        CASE 
            WHEN EXISTS (
                SELECT 1 FROM rbt.dam_surface ds 
                WHERE ST_Intersects(wl.geometry, ds.geometry)
            ) OR EXISTS (
                SELECT 1 FROM rbt.dam_curve dc 
                WHERE ST_Intersects(wl.geometry, dc.geometry)
            ) THEN 'Y'
            ELSE 'N'
        END AS calculated_dam_srf_crv_intersect
    FROM import.water_label wl
    WHERE wl.subclass ILIKE '%dam%' OR wl.subclass ILIKE '%weir%'
),
original_labels AS (
    SELECT
        fid,
        name,
        name_en,
        subclass AS fclass,
        calculated_water_intersect AS water_intersect,
        calculated_dam_srf_crv_intersect AS dam_srf_crv_intersect,
        geometry
    FROM intersections
),
supplemental_surface_points AS (
    -- Points from dam_surface polygons that don't have intersecting labels
    SELECT 
        NULL::integer as fid,
        COALESCE(ds.name, 'Unnamed Dam') as name,
        COALESCE(ds.name_en, 'Unnamed Dam') as name_en,
        ds.fclass,
        'Y' as water_intersect, -- These are from water table
        'Y' as dam_srf_crv_intersect, -- These ARE the dam surface
        ST_PointOnSurface(ds.geometry) as geometry
    FROM rbt.dam_surface ds
    WHERE NOT EXISTS (
        SELECT 1 FROM original_labels ol 
        WHERE ST_Intersects(ds.geometry, ol.geometry)
    )
),
supplemental_curve_points AS (
    -- Points from dam_curve linestrings that don't have intersecting labels
    SELECT 
        NULL::integer as fid,
        COALESCE(dc.name, 'Unnamed Dam') as name,
        COALESCE(dc.name_en, 'Unnamed Dam') as name_en,
        dc.fclass,
        'Y' as water_intersect, -- These are from waterway table
        'Y' as dam_srf_crv_intersect, -- These ARE the dam curve
        ST_LineInterpolatePoint(dc.geometry, 0.5) as geometry -- Midpoint of line
    FROM rbt.dam_curve dc
    WHERE NOT EXISTS (
        SELECT 1 FROM original_labels ol 
        WHERE ST_Intersects(dc.geometry, ol.geometry)
    )
    AND NOT EXISTS (
        -- Avoid duplicates if both surface and curve exist for same feature
        SELECT 1 FROM supplemental_surface_points ssp
        WHERE ST_DWithin(ST_LineInterpolatePoint(dc.geometry, 0.5), ssp.geometry, 10) -- 10 meter buffer
    )
)
-- Combine original labels with supplemental points
SELECT * FROM original_labels
UNION ALL
SELECT * FROM supplemental_surface_points  
UNION ALL
SELECT * FROM supplemental_curve_points;

-- ==============================================================================
-- POWER AND UTILITY INFRASTRUCTURE VIEWS
-- ==============================================================================

\echo 'Creating power and utility infrastructure views...'

-- Power station views for electrical generation/distribution facilities
CREATE MATERIALIZED VIEW IF NOT EXISTS rbt.power_station AS
	SELECT
		id,
		osm_id,
		subclass,
		NULLIF(name,'') as name,
		NULLIF(name_en,'') as name_en,
		NULLIF(operator,'') as operator,
		NULLIF(plant_source,'') as plant_source,
		NULLIF(plant_method,'') as plant_method,
		NULLIF(plant_storage,'') as plant_storage,
		NULLIF(plant_output,'') as plant_output,
		NULLIF(generator_source,'') as generator_source,
		NULLIF(generator_method,'') as generator_method,
		NULLIF(generator_type,'') as generator_type,
		NULLIF(generator_output,'') as generator_output,
		NULLIF(generator_plant,'') as generator_plant,
		ST_Area(ST_Transform(geometry, 3857))::real as area,
		geometry
	FROM import.utility_stations
    WHERE class = 'power';

CREATE INDEX IF NOT EXISTS idx_power_station_geometry ON rbt.power_station USING gist(geometry);

-- Power station labels with point geometry for cartographic display
CREATE MATERIALIZED VIEW IF NOT EXISTS rbt.power_station_label AS
	SELECT
		id,
		osm_id,
		subclass,
		name,
		name_en,
		operator,
		plant_source,
		plant_method,
		plant_storage,
		plant_output,
		generator_source,
		generator_method,
		generator_type,
		generator_output,
		generator_plant,
		area,
		ST_PointOnSurface(geometry)::geometry(Point,4326) as geometry
	FROM rbt.power_station;

-- Non-power utility stations (pumping stations, treatment plants, etc.)
CREATE MATERIALIZED VIEW IF NOT EXISTS rbt.pumping_station AS
	SELECT
		id,
		osm_id,
		subclass,
		NULLIF(name,'') as name,
		NULLIF(name_en,'') as name_en,
		NULLIF(operator,'') as operator,
		NULLIF(substation,'') as substation,
		NULLIF(substance,'') as substance,
		NULLIF(pumping_station,'') as pumping_station,
		ST_Area(ST_Transform(geometry, 3857))::real as area,
		geometry
	FROM import.utility_stations
    WHERE class != 'power';

CREATE INDEX IF NOT EXISTS idx_pumping_station_geometry ON rbt.pumping_station USING gist(geometry);

-- Pumping station labels with point geometry for cartographic display  
CREATE MATERIALIZED VIEW IF NOT EXISTS rbt.pumping_station_label AS
	SELECT
		id,
		osm_id,
		subclass,
		name,
		name_en,
		operator,
		substation,
		substance,
		pumping_station,
		area,
		ST_PointOnSurface(geometry)::geometry(Point,4326) as geometry
	FROM rbt.pumping_station;

-- Create utility station table combining data from power and man_made multipolygons
CREATE MATERIALIZED VIEW IF NOT EXISTS utility.station AS
WITH combined_stations AS (
    -- Get stations from power multipolygons
    SELECT 
        osm_id,
        name,
        other_tags -> 'pipeline' as pipeline,
        man_made,
        operator,
        other_tags -> 'substation' as substation,
        other_tags -> 'substance' as substance,
        power,
        other_tags as tags,
        geometry,
        'power_multipolygon' as source_table
    FROM utility.power_multipolygon
    WHERE 
        man_made IN (
            'pumping_station', 
            'storage_tank', 
            'wastewater_plant', 
            'water_works', 
            'works', 
            'watermill', 
            'gasometer'
        ) 
        OR power IN (
            'generator',
            'converter',
            'compensator',
            'plant',
            'substation',
            'switchgear'
        )
    
    UNION ALL
    
    -- Get stations from man_made multipolygons
    SELECT 
        osm_id,
        name,
        other_tags -> 'pipeline' as pipeline,
        man_made,
        operator,
        other_tags -> 'substation' as substation,
        other_tags -> 'substance' as substance,
        power,
        other_tags as tags,
        geometry,
        'man_made_multipolygon' as source_table
    FROM utility.man_made_multipolygon
    WHERE 
        man_made IN (
            'pumping_station', 
            'storage_tank', 
            'wastewater_plant', 
            'water_works', 
            'works', 
            'watermill', 
            'gasometer'
        ) 
        OR power IN (
            'generator',
            'converter',
            'compensator',
            'plant',
            'substation',
            'switchgear'
        )
),
-- Remove duplicates, keeping the record from power_multipolygon when both exist
deduplicated_stations AS (
    SELECT DISTINCT ON (osm_id)
        osm_id,
        name,
        pipeline,
        man_made,
        operator,
        substation,
        substance,
        power,
        tags,
        geometry
    FROM combined_stations
    ORDER BY osm_id, source_table  -- 'power_multipolygon' comes before 'man_made_multipolygon' alphabetically
)
SELECT * FROM deduplicated_stations;

CREATE MATERIALIZED VIEW IF NOT EXISTS rbt.utility_point AS
SELECT
	osm_id,
	NULLIF(class,'') as class,
	NULLIF(subclass,'') as subclass,
	NULLIF(name,'') as name,
	NULLIF(name_en,'') as name_en,
	NULLIF(substation,'') as substation,
	NULLIF(pumping_station,'') as pumping_station,
	NULLIF(operator,'') as operator,
	NULLIF(plant_source,'') as plant_source,
	NULLIF(plant_method,'') as plant_method,
	NULLIF(plant_storage,'') as plant_storage,
	NULLIF(plant_output,'') as plant_output,
	NULLIF(generator_source,'') as generator_source,
	NULLIF(generator_method,'') as generator_method,
	NULLIF(generator_type,'') as generator_type,
	NULLIF(generator_plant,'') as generator_plant,
	NULLIF(seamark_pylon_category,'') as seamark_pylon_category,
	NULLIF(seamark_platform_category,'') as seamark_platform_category,
	NULLIF(seamark_production_area_category,'') as seamark_production_area_category,
	NULLIF(seamark_name,'') as seamark_name,
	NULLIF(seamark_platform_height,'') as seamark_platform_height,
	NULLIF(tower_type,'') as tower_type,
	NULLIF(tower_construction,'') as tower_construction,
	NULLIF(mast_type,'') as mast_type,
	NULLIF(rotor_diameter,'') as rotor_diameter,
	NULLIF(service,'') as service,
	NULLIF(height,'') as height,
	NULLIF(content,'') as content,
	NULLIF(substance,'') as substance,
	NULLIF(capacity,'') as capacity,
	NULLIF(location,'') as location,
	NULLIF(access,'') as access,
	geometry
FROM import.utility_stations_label
WHERE subclass IN (
	'oil_well',
	'petroleum_well',
	'antenna',
	'chimney',
	'communications_tower',
	'crane',
	'flare',
	'gasometer',
	'lighthouse',
	'mast',
	'obelisk',
	'offshore_platform',
	'pumping_station',
	'silo',
	'storage_tank',
	'stupa',
	'tower',
	'utility_pole',
	'water_tower',
	'windmill',
	'windpump',
	'generator',
	'pole',
	'portal',
	'substation',
	'tower',
	'light_major',
	'platform',
	'pylon',
	'gate'
	);

-- Zoom-level specific views based on utility_filter
DROP VIEW IF EXISTS rbt.utility_point_z6 CASCADE;
CREATE VIEW rbt.utility_point_z6 AS
SELECT * FROM rbt.utility_point
WHERE subclass NOT IN ('utility_pole', 'pole', 'tower');

DROP VIEW IF EXISTS rbt.utility_point_z12 CASCADE;
CREATE VIEW rbt.utility_point_z12 AS
SELECT * FROM rbt.utility_point
WHERE subclass NOT IN ('utility_pole', 'pole');

-- Power transmission lines and electrical infrastructure
CREATE MATERIALIZED VIEW IF NOT EXISTS rbt.powerline AS
SELECT
	osm_id,
	class,
	subclass,
	name,
	location,
	cable_overhead_category,
	tags -> 'seamark:cable_submarine:category' AS cable_submarine_category,
	usage,
	voltage,
	operator,
	cables,
	other_tags -> 'wires' AS wires,
	geometry
FROM import.utility_linestrings
WHERE
	-- Include power-related infrastructure
	subclass IN (
		'line', 
		'minor_line', 
		'insulator', 
		'transmission', 
		'sub_station', 
		'substation',
		'cable', 
		'wire', 
		'cable_submarine', 
		'cable_overhead', 
		'busbar', 
		'bay', 
		'power'
	)
	-- Exclude ferry and mooring cables
	AND (
		cable_overhead_category IS NULL 
		OR cable_overhead_category NOT IN ('ferry', 'mooring')
	)
	AND (
		tags -> 'seamark:cable_submarine:category' IS NULL 
		OR tags -> 'seamark:cable_submarine:category' != 'ferry'
	);

-- Pipelines for various substances (oil, gas, water, etc.)
CREATE MATERIALIZED VIEW IF NOT EXISTS rbt.pipeline AS
SELECT
	osm_id,
	class,
	subclass,
	name,
	location,
	usage,
	substance,
	diameter,
	flow_direction,
	operator,
	pipeline_submarine_category,
	pipeline_submarine_product,
	NULLIF(tags -> 'seamark:pipeline_overhead:category', '') AS pipeline_overhead_category,
	NULLIF(tags -> 'seamark:pipeline_overhead:product', '') AS pipeline_overhead_product,
	NULLIF(tags -> 'product', '') AS product,
	NULLIF(tags -> 'content', '') AS content,
	NULLIF(tags -> 'height', '') AS height,
	NULLIF(tags -> 'ele', '') AS ele,
	NULLIF(tags -> 'operational_status', '') AS operational_status,
	NULLIF(tags -> 'condition', '') AS condition,
	geometry
FROM import.utility_linestrings
WHERE
	-- Include man_made and pipeline features, excluding power infrastructure
	(
		class IN ('man_made', 'pipeline') 
		AND subclass NOT IN (
			'line', 
			'minor_line', 
			'insulator', 
			'transmission', 
			'sub_station', 
			'substation',
			'cable', 
			'wire', 
			'cable_submarine', 
			'cable_overhead', 
			'busbar', 
			'bay', 
			'power'
		)
	)
	-- Include seamark pipeline types
	OR (
		class = 'seamark:type' 
		AND subclass IN ('pipeline_overhead', 'pipeline_submarine')
	);

\echo 'All additional cultural views created successfully'

-- ==============================================================================
-- STEP 6B: WRAPPER VIEWS FOR MATERIALIZED VIEW COMPATIBILITY
-- ==============================================================================

\echo 'Creating wrapper views to maintain naming compatibility...'

-- Create wrapper views that use the original names but reference the enhanced materialized views
-- This ensures backward compatibility while leveraging the performance benefits of materialized views



-- Port wrapper views - reference the enhanced materialized view
DROP VIEW IF EXISTS rbt.port_surface CASCADE;
CREATE VIEW rbt.port_surface AS SELECT * FROM rbt.port_surface_enhanced;



-- Hydrographic wrapper views - reference the enhanced materialized view
DROP VIEW IF EXISTS rbt.geonames_hydrographic CASCADE;
CREATE VIEW rbt.geonames_hydrographic AS SELECT * FROM rbt.geonames_hydrographic_enhanced;

\echo 'Wrapper views created successfully'

-- ==============================================================================
-- STEP 7: ANALYZE TABLES FOR OPTIMAL QUERY PLANNING
-- ==============================================================================

\echo 'Analyzing tables for optimal query planning...'

-- Analyze materialized views
ANALYZE rbt.port_surface_enhanced;
ANALYZE rbt.geonames_hydrographic_enhanced;

-- Analyze source tables
ANALYZE import.transportation_stations;
ANALYZE import.builtup_area;
ANALYZE import.shipway_linestring;
ANALYZE geonames.hydrographic;

\echo 'Table analysis completed'

-- ==============================================================================
-- STEP 8: FINAL VALIDATION AND COMMIT
-- ==============================================================================

\echo 'Performing final validation...'

DO $$
DECLARE
    rec RECORD;
    success_count INTEGER := 0;
    total_views INTEGER := 2;
    view_name TEXT;
    view_exists BOOLEAN;
    row_count BIGINT;
BEGIN
    RAISE NOTICE '=== CULTURAL LAYER PROCESSING SUMMARY ===';
    
    -- Check each materialized view
    FOR view_name IN VALUES 
        ('rbt.port_surface_enhanced'), 
        ('rbt.geonames_hydrographic_enhanced')
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
        AND table_name IN ('ferry', 'port_surface', 
                          'port_label', 'geonames_hydrographic');
        
        RAISE NOTICE '✓ Created % regular cultural-related views', view_count;
    END;
    
    -- Final summary
    RAISE NOTICE '=== PROCESSING RESULTS ===';
    RAISE NOTICE 'Materialized views: %/% successful', success_count, total_views;
    
    IF success_count > 0 THEN
        RAISE NOTICE '✓ Cultural layer processing completed with % successful materialized view(s)', success_count;
    ELSE
        RAISE WARNING '⚠ No materialized views were successfully created';
    END IF;
    
    RAISE NOTICE 'Transaction-based processing ensures that successful views are preserved';
    
END $$;

\echo 'Final validation completed successfully'

-- Commit transaction
COMMIT;


-- ==============================================================================
-- STEP 10: VACUUM AND ANALYZE FOR OPTIMAL PERFORMANCE
-- ==============================================================================

\echo 'Running final optimization...'

-- Vacuum and analyze all materialized views for optimal performance
VACUUM FULL ANALYZE rbt.port_surface_enhanced;
VACUUM FULL ANALYZE rbt.geonames_hydrographic_enhanced;

\echo '=============================================================================='
\echo 'CULTURAL LAYER PROCESSING COMPLETED SUCCESSFULLY'
\echo 'Enhanced script execution finished with optimizations:'
\echo '- Created materialized views for optimal performance'
\echo '- Added comprehensive indexes for fast queries'
\echo '- Implemented transaction management with error handling'
\echo '- Added dependency validation for reliable CI/CD execution'
\echo '- Applied spatial clustering optimizations'
\echo '=============================================================================='

-- Disable timing
\timing off
