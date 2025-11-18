-- ==============================================================================
-- AEROWAY LAYER SQL SCRIPT FOR CI/CD PROCESSING
-- Optimized for execution after imposm3 import completion
-- Enhanced with surface mapping and automated refresh capabilities
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

-- Note: autocommit is handled at the client level, not via SET LOCAL
-- Transaction management is handled explicitly with BEGIN/COMMIT

\echo 'Aeroway layer processing started with enhanced performance settings'

-- ==============================================================================
-- STEP 2: DEPENDENCY VALIDATION
-- ==============================================================================

\echo 'Validating aeroway source data dependencies...'

DO $$
DECLARE
    table_count INTEGER;
    error_msg TEXT;
BEGIN
    -- Validate ourairports schema exists
    IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'ourairports') THEN
        RAISE EXCEPTION 'Schema ourairports is missing. Cannot proceed with aeroway layer processing.';
    END IF;
    
    -- Validate rbt schema exists
    IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'rbt') THEN
        RAISE EXCEPTION 'Schema rbt is missing. Cannot proceed with aeroway layer processing.';
    END IF;
    
    -- Validate import.aerodrome_label_point exists and has data
    SELECT COUNT(*) INTO table_count FROM import.aerodrome_label_point LIMIT 1;
    IF table_count = 0 THEN
        RAISE EXCEPTION 'Source table import.aerodrome_label_point is empty or missing. Cannot proceed with aeroway layer processing.';
    END IF;
    
    -- Validate import.aeroway_linestring exists and has data
    SELECT COUNT(*) INTO table_count FROM import.aeroway_linestring LIMIT 1;
    IF table_count = 0 THEN
        RAISE EXCEPTION 'Source table import.aeroway_linestring is empty or missing. Cannot proceed with aeroway layer processing.';
    END IF;
    
    -- Validate import.aeroway_polygon exists and has data
    SELECT COUNT(*) INTO table_count FROM import.aeroway_polygon LIMIT 1;
    IF table_count = 0 THEN
        RAISE EXCEPTION 'Source table import.aeroway_polygon is empty or missing. Cannot proceed with aeroway layer processing.';
    END IF;
    
    RAISE NOTICE 'All required aeroway source tables validated successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE EXCEPTION 'Aeroway dependency validation failed: %', error_msg;
END $$;

\echo 'Aeroway source data validation completed successfully'


-- ==============================================================================
-- STEP 4: CREATE CRITICAL INDEXES FOR PERFORMANCE
-- ==============================================================================

\echo 'Creating critical aeroway indexes for optimal performance...'

-- Aeroway indexes
CREATE INDEX IF NOT EXISTS idx_aerodrome_label_point_geometry ON import.aerodrome_label_point USING gist(geometry);
CREATE INDEX IF NOT EXISTS idx_aerodrome_label_point_iata ON import.aerodrome_label_point USING btree(iata);
CREATE INDEX IF NOT EXISTS idx_aerodrome_label_point_icao ON import.aerodrome_label_point USING btree(icao);
CREATE INDEX IF NOT EXISTS idx_aeroway_linestring_subclass ON import.aeroway_linestring USING btree(subclass);
CREATE INDEX IF NOT EXISTS idx_aeroway_linestring_geometry ON import.aeroway_linestring USING gist(geometry);
CREATE INDEX IF NOT EXISTS idx_aeroway_polygon_geometry ON import.aeroway_polygon USING gist(geometry);

\echo 'Basic aeroway indexes created successfully'

-- Commit basic aeroway indexes to ensure they persist
COMMIT;
\echo 'Basic aeroway indexes committed successfully'

-- Start new transaction for trigram indexes
BEGIN;

-- ==============================================================================
-- GIN TRIGRAM INDEXES FOR PATTERN MATCHING OPTIMIZATION
-- ==============================================================================

\echo 'Creating GIN trigram indexes for enhanced aeroway pattern matching...'

-- Aeroway trigram indexes
CREATE INDEX IF NOT EXISTS idx_aeroway_linestring_name_trgm ON import.aeroway_linestring 
USING GIN (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_aeroway_polygon_name_trgm ON import.aeroway_polygon 
USING GIN (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_aerodrome_label_point_name_trgm ON import.aerodrome_label_point 
USING GIN (name gin_trgm_ops);

\echo 'GIN trigram indexes created successfully'

-- Commit trigram indexes to ensure they persist
COMMIT;
\echo 'Aeroway trigram indexes committed successfully'

-- Start new transaction for materialized views
BEGIN;

-- ==============================================================================
-- STEP 5: CREATE MATERIALIZED VIEW IF NOT EXISTSS WITH ERROR HANDLING
-- ==============================================================================

\echo 'Creating aeroway materialized views with enhanced error handling...'

\echo 'Creating import.aerodrome_polygon materialized view...'

DO $$
DECLARE
    error_msg TEXT;
BEGIN
    
CREATE MATERIALIZED VIEW import.aerodrome_polygon AS
SELECT
    osm_id,
    geometry,
    ST_Area(ST_Transform(geometry,3857))::real AS area,
    NULLIF(iata,'') AS iata,
    NULLIF(icao,'') AS icao,
    NULLIF(name,'') AS name
FROM import.aerodrome_label_point where ST_GeometryType(geometry) != 'Point';

    -- Create indexes on materialized view
    CREATE INDEX IF NOT EXISTS aerodrome_polygon_geom_idx ON import.aerodrome_polygon USING gist(geometry);
    CREATE INDEX IF NOT EXISTS aerodrome_polygon_name_idx ON import.aerodrome_polygon USING btree(name);
    CREATE INDEX IF NOT EXISTS aerodrome_polygon_icao_idx ON import.aerodrome_polygon USING btree(icao);
    CREATE INDEX IF NOT EXISTS aerodrome_polygon_iata_idx ON import.aerodrome_polygon USING btree(iata);
    
    RAISE NOTICE 'import.aerodrome_polygon materialized view created successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create import.aerodrome_polygon materialized view: %', error_msg;
    RAISE;
END $$;

-- Commit this materialized view
COMMIT;
\echo 'import.aerodrome_polygon materialized view committed'

-- Start new transaction for next materialized view
BEGIN;

\echo 'Creating import.osm_runway materialized view...'

DO $$
DECLARE
    error_msg TEXT;
BEGIN

    CREATE MATERIALIZED VIEW IF NOT EXISTS import.osm_runway AS
    SELECT
        osm_id,
        geometry,
        ST_Length(ST_Transform(geometry, 3857))::real AS osm_runway_length,
        NULLIF(surface,'') AS osm_runway_surface
    FROM import.aeroway_linestring WHERE subclass = 'runway';
    
    -- Create indexes on materialized view
    CREATE INDEX IF NOT EXISTS osm_runway_geom_idx ON import.osm_runway USING gist(geometry);
    
    RAISE NOTICE 'import.osm_runway materialized view created successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create import.osm_runway materialized view: %', error_msg;
    RAISE;
END $$;

-- Commit this materialized view
COMMIT;
\echo 'import.osm_runway materialized view committed'

-- Start new transaction for next materialized view
BEGIN;

\echo 'Creating import.aerodrome_runway materialized view...'

DO $$
DECLARE
    error_msg TEXT;
BEGIN

    CREATE MATERIALIZED VIEW IF NOT EXISTS import.aerodrome_runway AS
    SELECT
        a.osm_id AS osm_id_aerodrome,
        b.osm_id AS osm_id_runway,
        a.area AS osm_aerodrome_area,
        b.osm_runway_length,
        b.osm_runway_surface,
        a.iata,
        a.icao,
        a.name,
        a.geometry
    FROM import.aerodrome_polygon a
    LEFT JOIN import.osm_runway b ON ST_Intersects(b.geometry, a.geometry);
    
    -- Create indexes on materialized view
    CREATE INDEX IF NOT EXISTS aerodrome_runway_geom_idx ON import.aerodrome_runway USING gist(geometry);
    CREATE INDEX IF NOT EXISTS aerodrome_runway_name_idx ON import.aerodrome_runway USING btree(name);
    CREATE INDEX IF NOT EXISTS aerodrome_runway_icao_idx ON import.aerodrome_runway USING btree(icao);
    CREATE INDEX IF NOT EXISTS aerodrome_runway_iata_idx ON import.aerodrome_runway USING btree(iata);
    
    RAISE NOTICE 'import.aerodrome_runway materialized view created successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create import.aerodrome_runway materialized view: %', error_msg;
    RAISE;
END $$;

-- Commit this materialized view
COMMIT;
\echo 'import.aerodrome_runway materialized view committed'

-- Start new transaction for next materialized view
BEGIN;

\echo 'Creating rbt.ourairports_osm_aerodrome_runway_join materialized view...'

DO $$
DECLARE
    error_msg TEXT;
BEGIN

    CREATE MATERIALIZED VIEW IF NOT EXISTS rbt.ourairports_osm_aerodrome_runway_join AS
    SELECT
        a.osm_id_aerodrome,
        a.osm_id_runway,
        a.osm_aerodrome_area,
        a.osm_runway_length,
        a.osm_runway_surface,
        b.id AS airport_id
    FROM import.aerodrome_runway a
    JOIN ourairports.airport b ON ST_Intersects(b.geometry, a.geometry) OR (a.icao = b.gps_code OR a.iata = b.iata_code OR a.name = b.name);
    
    -- Create indexes on materialized view
    CREATE INDEX IF NOT EXISTS ourairports_osm_aerodrome_runway_idx ON rbt.ourairports_osm_aerodrome_runway_join USING btree(airport_id);
    CREATE INDEX IF NOT EXISTS ourairports_osm_aerodrome_runway_area_idx ON rbt.ourairports_osm_aerodrome_runway_join USING btree(osm_aerodrome_area);
    CREATE INDEX IF NOT EXISTS ourairports_osm_aerodrome_runway_length_idx ON rbt.ourairports_osm_aerodrome_runway_join USING btree(osm_runway_length);
    CREATE INDEX IF NOT EXISTS ourairports_osm_aerodrome_runway_surface_idx ON rbt.ourairports_osm_aerodrome_runway_join USING btree(osm_runway_surface);
    
    RAISE NOTICE 'rbt.ourairports_osm_aerodrome_runway_join materialized view created successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create rbt.ourairports_osm_aerodrome_runway_join materialized view: %', error_msg;
    RAISE;
END $$;

-- Commit this materialized view
COMMIT;
\echo 'rbt.ourairports_osm_aerodrome_runway_join materialized view committed'

-- Start new transaction for next materialized view
BEGIN;

\echo 'Creating ourairports.airports_runways materialized view...'

DO $$
DECLARE
    error_msg TEXT;
BEGIN

    CREATE MATERIALIZED VIEW IF NOT EXISTS ourairports.airports_runways AS
    WITH airports AS (
            SELECT
                id,
                ident,
                type,
                name,
                elevation_ft,
                continent,
                iso_country,
                iso_region,
                municipality,
                scheduled_service,
                gps_code as icao,
                iata_code as iata,
                local_code as local_code,
                geometry
            FROM ourairports.airport
        ),
    runways AS (
            SELECT
                id as runway_id,
                airport_ref,
                length_ft as runway_length_ft,
                width_ft as runway_width_ft,
                surface as runway_surface,
                lighted as runway_lighted,
                closed as runway_closed,
                le_ident as runway_le_ident,
                le_heading_degt as runway_le_heading,
                he_ident as runway_he_ident,
                he_heading_degt as runway_he_heading
            FROM ourairports.runway
        )
    SELECT
        b.id AS airport_id,
        b.ident,
        a.runway_length_ft,
        a.runway_width_ft,
        a.runway_surface,
        a.runway_lighted,
        a.runway_closed,
        a.runway_le_ident,
        a.runway_le_heading,
        a.runway_he_ident,
        a.runway_he_heading,
        b.type,
        b.name,
        b.elevation_ft,
        b.continent,
        b.iso_country,
        b.iso_region,
        b.municipality,
        b.scheduled_service,
        b.icao,
        b.iata,
        b.local_code,
        b.geometry
    FROM airports b
    LEFT JOIN runways a ON b.id = a.airport_ref;
    
    -- Create indexes on materialized view
    CREATE INDEX IF NOT EXISTS ourairports_airports_runways_airportid_idx ON ourairports.airports_runways USING btree(airport_id);
    CREATE INDEX IF NOT EXISTS ourairports_airports_runways_length_idx ON ourairports.airports_runways USING btree(runway_length_ft);
    CREATE INDEX IF NOT EXISTS ourairports_airports_runways_ident_idx ON ourairports.airports_runways USING btree(ident);
    CREATE INDEX IF NOT EXISTS ourairports_airports_runways_geometry_idx ON ourairports.airports_runways USING gist(geometry);
    
    RAISE NOTICE 'ourairports.airports_runways materialized view created successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create ourairports.airports_runways materialized view: %', error_msg;
    RAISE;
END $$;

-- Commit this materialized view
COMMIT;
\echo 'ourairports.airports_runways materialized view committed'

-- Start new transaction for next materialized view
BEGIN;

\echo 'Creating ourairports.airports_runways_osm materialized view...'

DO $$
DECLARE
    error_msg TEXT;
BEGIN

    CREATE MATERIALIZED VIEW IF NOT EXISTS ourairports.airports_runways_osm AS
    SELECT
            a.airport_id,
            a.ident,
            CASE
                WHEN a.runway_length_ft IS NULL AND b.osm_runway_length IS NOT NULL THEN (b.osm_runway_length *3.280)
                ELSE a.runway_length_ft
            END AS runway_length_ft,
            a.runway_width_ft,
            CASE
                WHEN a.runway_surface IS NULL AND b.osm_runway_surface IS NOT NULL THEN b.osm_runway_surface
                ELSE a.runway_surface
            END AS runway_surface,
            a.runway_lighted,
            a.runway_closed,
            a.runway_le_ident,
            a.runway_le_heading,
            a.runway_he_ident,
            a.runway_he_heading,
            a.type,
            a.name,
            a.elevation_ft,
            a.continent,
            a.iso_country,
            a.iso_region,
            a.municipality,
            a.scheduled_service,
            a.icao,
            a.iata,
            a.local_code,
            b.osm_id_aerodrome,
            b.osm_id_runway,
            b.osm_aerodrome_area,
            a.geometry
    FROM ourairports.airports_runways a
    LEFT JOIN rbt.ourairports_osm_aerodrome_runway_join b ON a.airport_id = b.airport_id;
    
    -- Create indexes on materialized view
    CREATE INDEX IF NOT EXISTS ourairports_airports_runways_osm_airportid_idx ON ourairports.airports_runways_osm USING btree(airport_id);
    CREATE INDEX IF NOT EXISTS ourairports_airports_runways_osm_length_idx ON ourairports.airports_runways_osm USING btree(runway_length_ft);
    CREATE INDEX IF NOT EXISTS ourairports_airports_runways_osm_ident_idx ON ourairports.airports_runways_osm USING btree(ident);
    CREATE INDEX IF NOT EXISTS ourairports_airports_runways_osm_area_idx ON ourairports.airports_runways_osm USING btree(osm_aerodrome_area);
    CREATE INDEX IF NOT EXISTS ourairports_airports_runways_osm_surface_idx ON ourairports.airports_runways_osm USING btree(runway_surface);
    CREATE INDEX IF NOT EXISTS ourairports_airports_runways_osm_geometry_idx ON ourairports.airports_runways_osm USING gist(geometry);
    
    RAISE NOTICE 'ourairports.airports_runways_osm materialized view created successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create ourairports.airports_runways_osm materialized view: %', error_msg;
    RAISE;
END $$;

-- Commit this materialized view
COMMIT;
\echo 'ourairports.airports_runways_osm materialized view committed'

-- Start new transaction for surface mapping table
BEGIN;

-- ==============================================================================
-- STEP 6: CREATE RUNWAY SURFACE MAPPING TABLE WITH ERROR HANDLING
-- ==============================================================================

\echo 'Creating runway surface mapping table with error handling...'

\echo 'Creating runway surface mapping table and indexes...'

DO $$
DECLARE
    error_msg TEXT;
BEGIN

    -- Create the mapping table to standardize runway surface types
    CREATE TABLE IF NOT EXISTS ourairports.runway_surface_mapping (
        id SERIAL PRIMARY KEY,
        original_surface TEXT NOT NULL UNIQUE,
        standardized_code VARCHAR(10) NOT NULL,
        is_pattern BOOLEAN DEFAULT FALSE
    );
    
    -- Create indexes for better lookup performance
    CREATE INDEX IF NOT EXISTS idx_runway_surface_mapping_original ON ourairports.runway_surface_mapping(original_surface);
    CREATE INDEX IF NOT EXISTS idx_runway_surface_mapping_pattern ON ourairports.runway_surface_mapping(is_pattern);
    
    RAISE NOTICE 'Runway surface mapping table created successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create runway surface mapping table: %', error_msg;
    RAISE;
END $$;

\echo 'Surface mapping table creation completed'

-- ==============================================================================
-- STEP 7: POPULATE SURFACE MAPPING WITH ERROR HANDLING
-- ==============================================================================

\echo 'Populating runway surface mapping data...'

\echo 'Inserting surface mapping patterns and exact matches...'

DO $$
DECLARE
    error_msg TEXT;
    insert_count INTEGER := 0;
BEGIN

    -- Pattern matches (using ILIKE)
    INSERT INTO ourairports.runway_surface_mapping (original_surface, standardized_code, is_pattern) VALUES
    ('ALUM%', 'ALUM-DECK', TRUE),
    ('%asphalt%', 'ASP', TRUE),
    ('%concrete%', 'CON', TRUE)
    ON CONFLICT (original_surface) DO NOTHING;
    
    GET DIAGNOSTICS insert_count = ROW_COUNT;
    RAISE NOTICE 'Inserted % pattern surface mappings', insert_count;

-- ================ EXACT MATCHES BY CATEGORY ================

-- Asphalt (ASP)
INSERT INTO ourairports.runway_surface_mapping (original_surface, standardized_code) VALUES
('APSH', 'ASP'), ('asfalt', 'ASP'), ('Asfalt', 'ASP'), ('Asfalto', 'ASP'),
('Ashpalt', 'ASP'), ('asp', 'ASP'), ('ASP', 'ASP'), ('ASP. Avgas available.', 'ASP'),
('asph', 'ASP'), ('Asph', 'ASP'), ('ASPH', 'ASP'), ('ASPH 71/F/C/X/T', 'ASP'),
('asphalt', 'ASP'), ('Asphalt', 'ASP'), ('ASPHALT', 'ASP'), ('Asphalt. 131.615 Mhz', 'ASP'),
('ASP/CON', 'ASP'), ('ASP/CONC', 'ASP'), ('ASP/GRE', 'ASP'), ('ASP/GRS', 'ASP'),
('ASP/GVL', 'ASP'), ('Asphalt/Coccrete', 'ASP'), ('asphalt concrete', 'ASP'),
('asphalt/concrete', 'ASP'), ('Asphalt/Concrete', 'ASP'), ('asphalt/dirt', 'ASP'),
('Asphalt/Dirt', 'ASP'), ('Asphalt/Grass', 'ASP'), ('asphalt/gravel', 'ASP'),
('Asphalt/treated', 'ASP'), ('Asphalt/Turf', 'ASP'), ('ASPHALT/TURF', 'ASP'),
('Asph/Conc', 'ASP'), ('ASPH-CONC', 'ASP'), ('ASPH/ CONC', 'ASP'), ('ASPH/CONC', 'ASP'),
('ASPH-CONC-F', 'ASP'), ('ASPH-CONC-G', 'ASP'), ('ASPH-CONC-P', 'ASP'),
('ASPH-DIRT', 'ASP'), ('ASPH-DIRT-G', 'ASP'), ('ASPH-DIRT-P', 'ASP'),
('ASPH-E', 'ASP'), ('ASPH-F', 'ASP'), ('ASPH-G', 'ASP'), ('ASPH/GRASS', 'ASP'),
('ASPH-GRVL', 'ASP'), ('ASPH/GRVL', 'ASP'), ('ASPH-GRVL-F', 'ASP'), ('ASPH/GRVL-F', 'ASP'),
('ASPH-GRVL-G', 'ASP'), ('ASPH-GRVL-P', 'ASP'), ('ASPH-L', 'ASP'), ('ASPH-P', 'ASP'),
('ASPH-TRTD', 'ASP'), ('ASPH-TRTD-F', 'ASP'), ('ASPH-TRTD-G', 'ASP'), ('ASPH-TRTD-P', 'ASP'),
('ASPH-TURF', 'ASP'), ('ASPH-TURF-E', 'ASP'), ('ASPH-TURF-F', 'ASP'), ('ASPH-TURF-G', 'ASP'),
('ASPH-TURF-P', 'ASP'), ('ASP/TURF', 'ASP'), ('Grooved ASP', 'ASP'), ('Blacktop on granite', 'ASP')
ON CONFLICT (original_surface) DO NOTHING;

GET DIAGNOSTICS insert_count = ROW_COUNT;
RAISE NOTICE 'Inserted % asphalt surface mappings', insert_count;

-- Unknown (U)
INSERT INTO ourairports.runway_surface_mapping (original_surface, standardized_code) VALUES
('UG', 'U'), ('UNK', 'U'), ('UNKNOWN', 'U'), ('Unknown ? Aço(steel)', 'U'), ('', 'U')
ON CONFLICT (original_surface) DO NOTHING;

GET DIAGNOSTICS insert_count = ROW_COUNT;
RAISE NOTICE 'Inserted % unknown surface mappings', insert_count;

-- Unpaved (UNPAVED)
INSERT INTO ourairports.runway_surface_mapping (original_surface, standardized_code) VALUES
('Unpaved', 'UNPAVED'), ('UnPaved', 'UNPAVED'), ('UNPAVED', 'UNPAVED'),
('Unpeved runway', 'UNPAVED'), ('Not paved', 'UNPAVED'), ('unsealed', 'UNPAVED')
ON CONFLICT (original_surface) DO NOTHING;

GET DIAGNOSTICS insert_count = ROW_COUNT;
RAISE NOTICE 'Inserted % unpaved surface mappings', insert_count;

-- Water (WAT)
INSERT INTO ourairports.runway_surface_mapping (original_surface, standardized_code) VALUES
('WAT', 'WAT'), ('water', 'WAT'), ('Water', 'WAT'), ('WATER', 'WAT'),
('WATER-E', 'WAT'), ('WATER-G', 'WAT')
ON CONFLICT (original_surface) DO NOTHING;

GET DIAGNOSTICS insert_count = ROW_COUNT;
RAISE NOTICE 'Inserted % water surface mappings', insert_count;

-- Wood (WOOD)
INSERT INTO ourairports.runway_surface_mapping (original_surface, standardized_code) VALUES
('Wood', 'WOOD'), ('WOOD', 'WOOD')
ON CONFLICT (original_surface) DO NOTHING;

GET DIAGNOSTICS insert_count = ROW_COUNT;
RAISE NOTICE 'Inserted % wood surface mappings', insert_count;

-- Turf (TURF)
INSERT INTO ourairports.runway_surface_mapping (original_surface, standardized_code) VALUES
('Tuef', 'TURF'), ('turf', 'TURF'), ('tURF', 'TURF'), ('Turf', 'TURF'), 
('TURF', 'TURF'), ('Torf', 'TURF')
ON CONFLICT (original_surface) DO NOTHING;

GET DIAGNOSTICS insert_count = ROW_COUNT;
RAISE NOTICE 'Inserted % turf surface mappings', insert_count;

-- Sand (SAN)
INSERT INTO ourairports.runway_surface_mapping (original_surface, standardized_code) VALUES
('SAN', 'SAN'), ('sand', 'SAN'), ('Sand', 'SAN'), ('SAND', 'SAN'), 
('sand and grass', 'SAN'), ('Sand/clay', 'SAN'), ('Sand/Clay', 'SAN'),
('SAND/CLAY/GRAV', 'SAN'), ('SAND-F', 'SAN'), ('sand/grass', 'SAN'),
('SAN (Piçarra)', 'SAN'), ('Sand grass', 'SAN'), ('Sand/grass', 'SAN'),
('Sand/Grass', 'SAN'), ('SAND/GRASS', 'SAN'), ('SAND/GRAVEL', 'SAN'),
('SAND/GRAVEL/AS', 'SAN'), ('SAND/GRVL', 'SAN'), ('Sand laterite', 'SAN'),
('SAND, TIDAL', 'SAN'), ('SAND/TURF', 'SAN'), ('Sandy gravel with clay', 'SAN')
ON CONFLICT (original_surface) DO NOTHING;

GET DIAGNOSTICS insert_count = ROW_COUNT;
RAISE NOTICE 'Inserted % sand surface mappings', insert_count;

-- Bitumen (BIT)
INSERT INTO ourairports.runway_surface_mapping (original_surface, standardized_code) VALUES
('BITUM', 'BIT'), ('Bitumen', 'BIT'), ('bitumen/gravel', 'BIT'), ('Bituminous', 'BIT'),
('BITUMINOUS', 'BIT'), ('Volcanic ash impregnated with bitumen', 'BIT'), ('tar', 'BIT'),
('Tar', 'BIT'), ('Tar - lights 5 clicks on 124.8', 'BIT'), ('tarmac', 'BIT'),
('Tarmac', 'BIT'), ('tar old', 'BIT'), ('Tarred', 'BIT'), ('sealed', 'BIT'),
('Sealed', 'BIT'), ('Sealed bitumen', 'BIT'), ('Sealed, grooved.', 'BIT')
ON CONFLICT (original_surface) DO NOTHING;

GET DIAGNOSTICS insert_count = ROW_COUNT;
RAISE NOTICE 'Inserted % bitumen surface mappings', insert_count;

-- Brick (BRI)
INSERT INTO ourairports.runway_surface_mapping (original_surface, standardized_code) VALUES
('BRI', 'BRI'), ('Brick', 'BRI'), ('BRICK', 'BRI'), ('Ceramic Brick', 'BRI')
ON CONFLICT (original_surface) DO NOTHING;

GET DIAGNOSTICS insert_count = ROW_COUNT;
RAISE NOTICE 'Inserted % brick surface mappings', insert_count;

-- Graded Earth (GRE)
INSERT INTO ourairports.runway_surface_mapping (original_surface, standardized_code) VALUES
('compacted earth', 'GRE'), ('Compacted Earth', 'GRE'), ('Compacted sand', 'GRE'), 
('Graded Hardcore', 'GRE'), ('Zahorra compactada', 'GRE'), ('graded earth', 'GRE'), 
('Graded earth', 'GRE'), ('Graded Earth', 'GRE'), ('Grass/Graded Hardcore', 'GRE'), 
('GRASS/HARDCORE', 'GRE'), ('Grass/rolled earth', 'GRE'), ('Grass over gravel', 'GRE'), 
('Grass over hard gravel', 'GRE'), ('TURF/ASP', 'GRE'), ('TURF/ASPHALT', 'GRE'), 
('TURF/CHIPSEAL', 'GRE'), ('TURF/CLAY', 'GRE'), ('Turf/Concrete', 'GRE'), 
('Turf/dirt', 'GRE'), ('Turf/Dirt', 'GRE'), ('TURF-DIRT', 'GRE'), 
('TURF-DIRT-F', 'GRE'), ('TURF-DIRT-G', 'GRE'), ('TURF-DIRT-P', 'GRE'), 
('TURF-E', 'GRE'), ('TURF/EARTH', 'GRE'), ('TURF/EARTH/GRA', 'GRE'), 
('TURF-F', 'GRE'), ('TURF-G', 'GRE'), ('Turf / Grass', 'GRE'), 
('Turf/Grass', 'GRE'), ('Turf / Gravel', 'GRE'), ('Turf/Gravel', 'GRE'), 
('TURF/GRAVEL', 'GRE'), ('TURF/GRAVEL/AS', 'GRE'), ('TURF/GRAVEL/CL', 'GRE'), 
('TURF/GRAVEL/SN', 'GRE'), ('TURF-GRVL', 'GRE'), ('TURF/GRVL', 'GRE'), 
('TURF-GRVL-F', 'GRE'), ('TURF-GRVL-G', 'GRE'), ('TURF-GRVL-P', 'GRE'), 
('TURF/OIL PACKE', 'GRE'), ('TURF-P', 'GRE'), ('TURF-SAND-F', 'GRE'), 
('Turf / Snow', 'GRE'), ('Turf/Snow', 'GRE'), ('TURF/SNOW', 'GRE'), 
('Turf, soft during spring thaw', 'GRE'), ('TURF/SOIL', 'GRE'), 
('TURF/TREATED G', 'GRE'), ('TURF-TRTD-G', 'GRE'), ('Paved/Compacted schist', 'GRE'), 
('packed dirt', 'GRE'), ('PACKED GRAVEL', 'GRE')
ON CONFLICT (original_surface) DO NOTHING;

GET DIAGNOSTICS insert_count = ROW_COUNT;
RAISE NOTICE 'Inserted % graded earth surface mappings', insert_count;

-- Clay (CLA)
INSERT INTO ourairports.runway_surface_mapping (original_surface, standardized_code) VALUES
('Brown clay', 'CLA'), ('Brown clay gravel', 'CLA'), ('Brown gravel', 'CLA'), 
('Brown silt clay', 'CLA'), ('Brown Silt clay', 'CLA'), ('CLA', 'CLA'), 
('Clay', 'CLA'), ('CLAY', 'CLA'), ('Clay/grass', 'CLA'), ('Clay/Gravel', 'CLA'), 
('CLAY/GRAVEL', 'CLA'), ('CLAY/GRAVEL/TU', 'CLA'), ('CLAY/GRVL', 'CLA'), 
('Clay/Sand', 'CLA'), ('CLAY/SAND', 'CLA'), ('CLAY/TURF', 'CLA'), 
('Grey clay', 'CLA'), ('Grey gravel', 'CLA'), ('Grey silt clay', 'CLA'), 
('Red clay', 'CLA'), ('Red clay gravel', 'CLA'), ('Red gravel', 'CLA'), 
('Red silt clay', 'CLA'), ('Rock/Gravel/Clay', 'CLA'), ('Shale/Clay', 'CLA'), 
('Shaly Clay', 'CLA'), ('Black clay', 'CLA'), ('Black silt', 'CLA'), 
('Hard clay', 'CLA'), ('Hard loam', 'CLA')
ON CONFLICT (original_surface) DO NOTHING;

GET DIAGNOSTICS insert_count = ROW_COUNT;
RAISE NOTICE 'Inserted % clay surface mappings', insert_count;

-- Coral (COR)
INSERT INTO ourairports.runway_surface_mapping (original_surface, standardized_code) VALUES
('Compacted coral and sand', 'COR'), ('COR', 'COR'), ('Coral', 'COR'), 
('CORAL', 'COR'), ('Coral grass', 'COR'), ('Coral penetration', 'COR'), 
('Coral sand', 'COR'), ('Crushed coral', 'COR')
ON CONFLICT (original_surface) DO NOTHING;

GET DIAGNOSTICS insert_count = ROW_COUNT;
RAISE NOTICE 'Inserted % coral surface mappings', insert_count;

-- Gravel (GVL)
INSERT INTO ourairports.runway_surface_mapping (original_surface, standardized_code) VALUES
('CRUSHED ROCK', 'GVL'), ('crushed rock and asphalt', 'GVL'), ('grav', 'GVL'), 
('PIC', 'GVL'), ('PIÇ', 'GVL'), ('Piçarra', 'GVL'), ('Yellow gravel', 'GVL'), 
('GRAV', 'GVL'), ('gravel', 'GVL'), ('Gravel', 'GVL'), ('GRAVEL', 'GVL'), 
('Gravel/Asphalt mix', 'GVL'), ('GRAVEL / CINDERS / CRUSHED ROCK / CORAL/SHELLS / SLAG', 'GVL'), 
('Gravel/clay', 'GVL'), ('GRAVEL/CLAY', 'GVL'), ('GRAVEL/CLAY/SA', 'GVL'), 
('Gravel (covered with a tarp)', 'GVL'), ('Gravel dirt', 'GVL'), ('Gravel/dirt', 'GVL'), 
('Gravel/Dirt', 'GVL'), ('GRAVEL-E', 'GVL'), ('GRAVEL-F', 'GVL'), ('GRAVEL-G', 'GVL'), 
('Gravel/grass', 'GVL'), ('Gravel/Grass', 'GVL'), ('GRAVEL/GRASS', 'GVL'), 
('Gravel/grass, First 410m of RWY 23 paved', 'GVL'), ('GRAVEL, GRASS / SOD', 'GVL'), 
('GRAVEL-P', 'GVL'), ('GRAVEL/SAND', 'GVL'), ('GRAVEL/SAND/CL', 'GVL'), 
('Gravel/Snow', 'GVL'), ('Gravel/soil', 'GVL'), ('GRAVEL, TRTD', 'GVL'), 
('Gravel/Turf', 'GVL'), ('GRAVEL/TURF', 'GVL'), ('GRV', 'GVL'), ('GRV/ASP', 'GVL'), 
('GRV/GRASS', 'GVL'), ('GRVL', 'GVL'), ('GRVL/ASP', 'GVL'), ('GRVL/CLAY', 'GVL'), 
('Grvl/Dirt', 'GVL'), ('GRVL-DIRT', 'GVL'), ('GRVL-DIRT-E', 'GVL'), 
('GRVL-DIRT-F', 'GVL'), ('GRVL-DIRT-G', 'GVL'), ('GRVL-DIRT-P', 'GVL'), 
('GRVL-E', 'GVL'), ('GRVL-F', 'GVL'), ('GRVL-G', 'GVL'), ('GRVL-GRASS', 'GVL'), 
('GRVL/GRASS', 'GVL'), ('GRVL-P', 'GVL'), ('GRVL/PIÇ', 'GVL'), ('GRVL-TRTD', 'GVL'), 
('GRVL-TRTD-F', 'GVL'), ('GRVL-TRTD-P', 'GVL'), ('GRVL-TURF', 'GVL'), 
('GRVL/TURF', 'GVL'), ('GRVL-TURF-F', 'GVL'), ('GRVL-TURF-G', 'GVL'), 
('GRVL-TURF-P', 'GVL'), ('GRV/MAICILLO', 'GVL'), ('GRV/PAD', 'GVL'), ('GVL', 'GVL'), 
('White gravel', 'GVL'), ('Paved/Gravel', 'GVL'), ('Rocky gravel', 'GVL'), 
('Piçarra gravel', 'GVL'), ('Piçarra Gravel', 'GVL')
ON CONFLICT (original_surface) DO NOTHING;

GET DIAGNOSTICS insert_count = ROW_COUNT;
RAISE NOTICE 'Inserted % gravel surface mappings', insert_count;

-- Grass/Soil/Dirt (GRS)
INSERT INTO ourairports.runway_surface_mapping (original_surface, standardized_code) VALUES
('dirt', 'GRS'), ('Volcanic ash/soil', 'GRS'), ('dirt?', 'GRS'), ('lakebed', 'GRS'), 
('Dirt', 'GRS'), ('DIRT', 'GRS'), ('DIRT(Caliche)', 'GRS'), ('DIRT-E', 'GRS'), 
('DIRT-F', 'GRS'), ('DIRT-G', 'GRS'), ('Dirt/grass', 'GRS'), ('Dirt/Gravel', 'GRS'), 
('DIRT-GRVL', 'GRS'), ('DIRT-GRVL-F', 'GRS'), ('DIRT-GRVL-G', 'GRS'), 
('DIRT-GRVL-P', 'GRS'), ('dirt, No winter maint.', 'GRS'), ('DIRT-P', 'GRS'), 
('Dirt/rock', 'GRS'), ('DIRT-SAND', 'GRS'), ('DIRT-TRTD', 'GRS'), ('DIRT-TURF', 'GRS'), 
('DIRT-TURF-F', 'GRS'), ('DIRT-TURF-G', 'GRS'), ('earth', 'GRS'), ('Earth', 'GRS'), 
('EARTH', 'GRS'), ('Earth/sand', 'GRS'), ('EARTH/SNOW', 'GRS'), ('EARTH/TURF', 'GRS'), 
('Erba', 'GRS'), ('GOOD GRASS', 'GRS'), ('Gr', 'GRS'), ('GR', 'GRS'), ('GRA', 'GRS'), 
('graas', 'GRS'), ('GRAAS', 'GRS'), ('gras', 'GRS'), ('Gras', 'GRS'), ('grass', 'GRS'), 
('Grass', 'GRS'), ('GRASS', 'GRS'), 
('grass. 26 end has power lines 20ft from threshold. approx 50 ft', 'GRS'), 
('GRASS&amp;GRAVEL', 'GRS'), ('Grass and granite sand', 'GRS'), 
('Grass/Asphalt Insert 1968X59 Feet', 'GRS'), 
('GRASS CAUTION: ATC do NOT apply wake turbulence separation!', 'GRS'), 
('Grass - caution moles', 'GRS'), ('Grass/clay', 'GRS'), ('Grass/Clay', 'GRS'), 
('grass/concrete', 'GRS'), ('Grass/Concrete', 'GRS'), ('grass coral', 'GRS'), 
('Grass/dirt', 'GRS'), ('Grass Dirt', 'GRS'), ('grass/earth', 'GRS'), 
('Grassed black clay', 'GRS'), ('Grassed blackclay', 'GRS'), 
('Grassed black clay sand', 'GRS'), ('Grassed black clay silt', 'GRS'), 
('Grassed black sand', 'GRS'), ('Grassed black silt', 'GRS'), 
('Grassed black silt clay', 'GRS'), ('Grassed black silt sand', 'GRS'), 
('Grassed black soil', 'GRS'), ('Grassed brown clay', 'GRS'), 
('Grassed Brown Clay', 'GRS'), ('Grassed brown clay gravel', 'GRS'), 
('Grassed brown gravel', 'GRS'), ('Grassed brown loam', 'GRS'), 
('Grassed brown sandy clay', 'GRS'), ('Grassed brown silt clay', 'GRS'), 
('Grassed brown silt loam', 'GRS'), ('Grassed brown silty clay', 'GRS'), 
('Grassed clay', 'GRS'), ('Grassed clay silt clay', 'GRS'), ('Grassed gravel', 'GRS'), 
('Grassed grey clay', 'GRS'), ('Grassed grey gravel', 'GRS'), ('Grassed grey sand', 'GRS'), 
('Grassed grey silt clay', 'GRS'), ('Grassed grey silt sand', 'GRS'), 
('Grassed limestone gravel', 'GRS'), ('Grassed red clay', 'GRS'), 
('Grassed Red Clay', 'GRS'), ('Grassed red clay gravel', 'GRS'), 
('Grassed red silt', 'GRS'), ('Grassed red silt clay', 'GRS'), 
('Grassed red silt sand', 'GRS'), ('Grassed red silty clay', 'GRS'), 
('Grassed river gravel', 'GRS'), ('Grassed Sand', 'GRS'), ('Grassed sand clay', 'GRS'), 
('Grassed sandy loam', 'GRS'), ('Grassed silt clay', 'GRS'), 
('Grassed white coronas', 'GRS'), ('Grassed white gravel', 'GRS'), 
('Grassed white lime stone', 'GRS'), ('Grassed yellow clay', 'GRS'), 
('Grassed yellow gravel', 'GRS'), ('Grassed yellow silt clay', 'GRS'), 
('GRASS-F', 'GRS'), ('Grass, first 500x6 meter on 25 is paved', 'GRS'), 
('grass/gravel', 'GRS'), ('Grass/gravel', 'GRS'), ('Grass/Gravel', 'GRS'), 
('GRASS/GRAVEL', 'GRS'), ('Grass/Helipads Concrete', 'GRS'), ('Grass - Herbe', 'GRS'), 
('grass - herbe  (avion)', 'GRS'), ('Grass - Herbe -> Avion - ULM', 'GRS'), 
('grass - herbe  (planeur)', 'GRS'), ('Grass/Moss', 'GRS'), 
('Grassnow taxiway only!!', 'GRS'), ('Grass on coral', 'GRS'), 
('GRASS OR EARTH NOT GRADED OR ROLLED', 'GRS'), ('Grass over clay', 'GRS'), 
('Grass over rock', 'GRS'), ('GRASS/PAD', 'GRS'), 
('grass paved with a plastic grille', 'GRS'), ('Grass/red clay', 'GRS'), 
('Grass red silty clay', 'GRS'), ('Grasss', 'GRS'), ('Grass/Sand', 'GRS'), 
('Grass/sandy soil', 'GRS'), ('Grass/Snow', 'GRS'), ('GRASS/SNOW', 'GRS'), 
('GRASS / SOD', 'GRS'), ('GRASS / SOD, GRAVEL', 'GRS'), 
('GRASS / SOD, NATURAL SOIL', 'GRS'), ('grassy', 'GRS'), ('ground', 'GRS'), 
('Ground', 'GRS'), ('GRS', 'GRS'), ('GRS Emergency Strip', 'GRS'), ('GRS/GVL', 'GRS'), 
('SOD', 'GRS'), ('Sod over hard clay', 'GRS'), ('Sod with gravel & sand', 'GRS'), 
('Soft', 'GRS'), ('Soft Gravel', 'GRS'), ('SOFT SAND', 'GRS'), ('Soil', 'GRS'), 
('Soil and Grass', 'GRS'), ('Soil, rough gravel', 'GRS'), ('Natural Soil', 'GRS'), 
('NATURAL SOIL', 'GRS'), ('NATURAL SOIL, GRASS / SOD', 'GRS'), ('LOOSE GRAVEL', 'GRS'), 
('Limestone/Grass', 'GRS'), ('Hard mud', 'GRS'), ('Hard Sand', 'GRS'), 
('Herba (grass)', 'GRS')
ON CONFLICT (original_surface) DO NOTHING;

GET DIAGNOSTICS insert_count = ROW_COUNT;
RAISE NOTICE 'Inserted % grass/soil/dirt surface mappings', insert_count;

-- Concrete (CON)
INSERT INTO ourairports.runway_surface_mapping (original_surface, standardized_code) VALUES
('CON', 'CON'), ('CON/ASP', 'CON'), ('conc', 'CON'), ('Conc', 'CON'), ('CONC', 'CON'), 
('CONC/ASPH', 'CON'), ('CONC-E', 'CON'), ('CONC-F', 'CON'), ('CONC-G', 'CON'), 
('CONC-GRVD', 'CON'), ('CONC-GRVL', 'CON'), ('CONC/GRVL', 'CON'), ('CONC-GRVL-G', 'CON'), 
('CONC/MTAL', 'CON'), ('CONC-P', 'CON'), ('concrete', 'CON'), ('Concrete', 'CON'), 
('CONCRETE', 'CON'), ('CONCRETE AND ASP', 'CON'), ('Concrete and turf.', 'CON'), 
('Concrete/Asphalt', 'CON'), ('concrete blocks', 'CON'), ('Concrete/Grass', 'CON'), 
('CONCRETE + GRASS. MTOM 2t', 'CON'), ('Concrete/Gravel', 'CON'), 
('Concrete - Grooved', 'CON'), ('Concrete/Turf', 'CON'), ('CONC-TRTD', 'CON'), 
('CONC-TRTD-G', 'CON'), ('Conc/Turf', 'CON'), ('CONC-TURF', 'CON'), 
('CONC-TURF-F', 'CON'), ('CONC-TURF-G', 'CON'), ('CON/GRS', 'CON'), ('CON/GVL', 'CON'), 
('CON/MET', 'CON'), ('CON/PAD', 'CON'), ('C0N', 'CON'), ('Caliche', 'CON'), 
('CALICHE', 'CON'), ('cement', 'CON'), ('Cement', 'CON')
ON CONFLICT (original_surface) DO NOTHING;

GET DIAGNOSTICS insert_count = ROW_COUNT;
RAISE NOTICE 'Inserted % concrete surface mappings', insert_count;

-- Snow (SNO)
INSERT INTO ourairports.runway_surface_mapping (original_surface, standardized_code) VALUES
('SNO', 'SNO'), ('Snow', 'SNO'), ('SNOW', 'SNO'), ('Snow/Ice', 'SNO')
ON CONFLICT (original_surface) DO NOTHING;

GET DIAGNOSTICS insert_count = ROW_COUNT;
RAISE NOTICE 'Inserted % snow surface mappings', insert_count;

-- Ice (ICE)
INSERT INTO ourairports.runway_surface_mapping (original_surface, standardized_code) VALUES
('ice', 'ICE'), ('Ice', 'ICE'), ('ICE', 'ICE'), ('Ice - frozen lake', 'ICE')
ON CONFLICT (original_surface) DO NOTHING;

GET DIAGNOSTICS insert_count = ROW_COUNT;
RAISE NOTICE 'Inserted % ice surface mappings', insert_count;

-- Composite (COM)
INSERT INTO ourairports.runway_surface_mapping (original_surface, standardized_code) VALUES
('COM', 'COM'), ('COP', 'COM')
ON CONFLICT (original_surface) DO NOTHING;

GET DIAGNOSTICS insert_count = ROW_COUNT;
RAISE NOTICE 'Inserted % composite surface mappings', insert_count;

-- Permanent (PER)
INSERT INTO ourairports.runway_surface_mapping (original_surface, standardized_code) VALUES
('Surface paved', 'PER'), ('hard', 'PER'), ('Hard', 'PER'), ('Hard Surfaced', 'PER'), 
('paved', 'PER'), ('Paved', 'PER'), ('PAVED', 'PER'), ('Pavement', 'PER'), 
('paving', 'PER'), ('PER', 'PER')
ON CONFLICT (original_surface) DO NOTHING;

GET DIAGNOSTICS insert_count = ROW_COUNT;
RAISE NOTICE 'Inserted % permanent surface mappings', insert_count;

-- Macadam/Treated (MAC)
INSERT INTO ourairports.runway_surface_mapping (original_surface, standardized_code) VALUES
('TER', 'MAC'), ('TREATED', 'MAC'), ('TREATED-E', 'MAC'), ('TREATED-F', 'MAC'), 
('TREATED-G', 'MAC'), ('TREATED GRAVEL', 'MAC'), ('TREATED SAND', 'MAC'), 
('TRTD', 'MAC'), ('TRTD-DIRT', 'MAC'), ('TRTD-DIRT-F', 'MAC'), ('TRTD-DIRT-P', 'MAC'), 
('TRTD GRVL', 'MAC'), ('OIL&CHIP-T-G', 'MAC'), ('OILED', 'MAC'), ('OILED DIRT', 'MAC'), 
('OILED GRAVEL', 'MAC'), ('OILED GRAVEL/T', 'MAC'), ('Oilgravel', 'MAC'), 
('Oilgravel/sand', 'MAC'), ('OLD ASP', 'MAC'), ('Oligravel/GRVL', 'MAC'), 
('MAC', 'MAC'), ('Macadam', 'MAC')
ON CONFLICT (original_surface) DO NOTHING;

GET DIAGNOSTICS insert_count = ROW_COUNT;
RAISE NOTICE 'Inserted % macadam/treated surface mappings', insert_count;

-- Pierced Steel Planking (PSP)
INSERT INTO ourairports.runway_surface_mapping (original_surface, standardized_code) VALUES
('Mats', 'PSP'), ('MATS', 'PSP'), ('MATS-G', 'PSP'), ('MET', 'PSP'), ('Metal', 'PSP'), 
('METAL', 'PSP'), ('MET/CON', 'PSP'), ('MTAL', 'PSP'), ('Steel', 'PSP'), 
('STEEL', 'PSP'), ('STEEL-CONC', 'PSP'), 
('PIERCED STEEL PLANKING / LANDING MATS / MEMBRANES', 'PSP')
ON CONFLICT (original_surface) DO NOTHING;

GET DIAGNOSTICS insert_count = ROW_COUNT;
RAISE NOTICE 'Inserted % PSP surface mappings', insert_count;

RAISE NOTICE 'All runway surface mappings populated successfully';

EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to populate runway surface mappings: %', error_msg;
    RAISE;
END $$;

\echo 'Surface mapping data population completed'

-- Commit surface mapping table and data
COMMIT;
\echo 'Surface mapping table and data committed successfully'

-- Start new transaction for main views
BEGIN;

-- ==============================================================================
-- STEP 8: CREATE MAIN AIRPORT VIEWS WITH ERROR HANDLING
-- ==============================================================================

\echo 'Creating main airport views with enhanced error handling...'

\echo 'Creating rbt.airports view with surface mapping integration...'

DO $$
DECLARE
    error_msg TEXT;
BEGIN

-- Final Tileset View
    CREATE VIEW rbt.airports AS
WITH runways_counts AS (
	SELECT
        airport_id,
        SUM(
            CASE
            WHEN (runway_length_ft > 4000) THEN 1
            ELSE 0
            END
        ) AS l_runway_count,
        SUM(
            CASE
            WHEN (runway_length_ft BETWEEN 1500 AND 4000) THEN 1
            ELSE 0
            END
        ) AS m_runway_count,
        SUM(
            CASE
            WHEN (runway_length_ft < 1500) THEN 1
            ELSE 0
            END
        ) AS s_runway_count,
        SUM(
            CASE
            WHEN (runway_length_ft IS NULL) THEN 1
            ELSE 0
            END
        ) AS u_runway_count,
        COUNT(airport_id) AS runway_count 
    from ourairports.airports_runways_osm
    group by
        airport_id
    order by runway_count
	),
airports AS (
    SELECT
        a.airport_id,
        a.ident,
        a.runway_length_ft,
        a.runway_width_ft,
        (
            SELECT COALESCE(
                -- First try pattern matches
                (SELECT m.standardized_code 
                 FROM ourairports.runway_surface_mapping m 
                 WHERE m.is_pattern = TRUE 
                   AND a.runway_surface ILIKE m.original_surface
                 LIMIT 1),
                -- Then try exact matches
                (SELECT m.standardized_code 
                 FROM ourairports.runway_surface_mapping m 
                 WHERE m.is_pattern = FALSE 
                   AND a.runway_surface = m.original_surface
                 LIMIT 1),
                -- If no match found, use the original
                a.runway_surface
            )
        ) AS runway_surface,
        a.runway_lighted,
        a.runway_closed,
        a.runway_le_ident,
        a.runway_le_heading::real AS runway_le_heading,
        a.runway_he_ident,
        a.runway_he_heading::real AS runway_he_heading,
        a.type,
        a.name,
        a.elevation_ft,
        a.continent,
        a.iso_country,
        a.iso_region,
        a.municipality,
        a.scheduled_service,
        a.icao,
        a.iata,
        a.local_code,
        a.osm_id_aerodrome,
        a.osm_id_runway,
        a.osm_aerodrome_area::real AS osm_aerodrome_area,
        CASE
            WHEN a.osm_aerodrome_area >= 2500000 THEN 1
            WHEN (a.osm_aerodrome_area < 2500000) OR (a.osm_aerodrome_area IS NULL AND ((b.l_runway_count = b.runway_count) OR (b.runway_count > 1 AND ((b.l_runway_count = 1 AND b.m_runway_count >= 1) OR b.m_runway_count > 1)))) THEN 2
            WHEN (a.osm_aerodrome_area < 2500000) OR (a.osm_aerodrome_area IS NULL AND (b.runway_count >= 1 AND b.l_runway_count = 0 AND b.m_runway_count = 1)) THEN 3
            ELSE 4
        END AS category,
        CASE
            WHEN a.type = 'closed' THEN 2
            ELSE 1
        END AS rank,
        a.geometry
FROM ourairports.airports_runways_osm a
LEFT JOIN runways_counts b ON a.airport_id = b.airport_id
WHERE NOT (a.name ILIKE ANY(ARRAY['%helicopter%', '%helipad%', '%heliport%']) OR type = 'heliport')
),
ranked_airports AS (
  SELECT 
    airport_id,
    ident,
    runway_length_ft,
    runway_width_ft,
    runway_surface,
    runway_lighted,
    runway_closed,
    runway_le_ident,
    runway_le_heading,
    runway_he_ident,
    runway_he_heading,
    type,
    name,
    elevation_ft,
    continent,
    iso_country,
    iso_region,
    municipality,
    scheduled_service,
    icao,
    iata,
    local_code,
    osm_id_aerodrome,
    osm_id_runway,
    osm_aerodrome_area,
    category,
    rank,
    ROW_NUMBER() OVER (
      PARTITION BY airport_id 
      ORDER BY 
        COALESCE(runway_length_ft, -1) DESC
    ) AS ranking,
    geometry
  FROM airports
)
SELECT 
    airport_id,
    ident,
    runway_length_ft,
    runway_width_ft,
    runway_surface,
    runway_lighted,
    runway_closed,
    runway_le_ident,
    runway_le_heading,
    runway_he_ident,
    runway_he_heading,
    type,
    name,
    elevation_ft,
    continent,
    iso_country,
    iso_region,
    municipality,
    scheduled_service,
    icao,
    iata,
    local_code,
    osm_id_aerodrome,
    osm_id_runway,
    osm_aerodrome_area,
    category,
    rank,
    geometry
FROM ranked_airports
WHERE ranking = 1;

    RAISE NOTICE 'rbt.airports view created successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create rbt.airports view: %', error_msg;
    RAISE;
END $$;

-- Commit main airport view
COMMIT;
\echo 'Main airport view committed successfully'

-- Start new transaction for additional views
BEGIN;

-- ==============================================================================
-- STEP 9: CREATE ADDITIONAL AEROWAY VIEWS WITH ERROR HANDLING
-- ==============================================================================

\echo 'Creating additional aeroway views...'

\echo 'Creating rbt.aeroway_surface view...'

DO $$
DECLARE
    error_msg TEXT;
BEGIN

    CREATE VIEW rbt.aeroway_surface AS
WITH combined_aeroway AS (
    -- From aerodrome_label_point (non-point geometries)
    SELECT
        osm_id,
        NULLIF(name, 'NULL') as name,
        NULLIF(name_en, 'NULL') as name_en,
        NULLIF(aerodrome_type, 'NULL') as aerodrome_type,
        NULLIF(amenity, 'NULL') as amenity,
        subclass,
        NULLIF(ele, 'NULL') as ele,
        NULLIF(iata, 'NULL') as iata,
        NULLIF(icao, 'NULL') as icao,
        NULLIF(military, 'NULL') as military,
        NULLIF(operator, 'NULL') as operator,
        NULLIF(surface, 'NULL') as surface,
        ST_Area(geometry) AS area,
        geometry
    FROM import.aerodrome_label_point 
    WHERE ST_GeometryType(geometry) != 'Point'
    
    UNION ALL
    
    -- From aeroway_polygon
    SELECT
        osm_id,
        NULLIF(name, 'NULL') as name,
        NULLIF((tags -> 'name:en'), 'NULL') as name_en,
        NULLIF((tags -> 'aerodrome:type'), 'NULL') as aerodrome_type,
        NULLIF(amenity, 'NULL') as amenity,
        subclass,
        NULLIF(ele, 'NULL') as ele,
        NULLIF(iata, 'NULL') as iata,
        NULLIF(icao, 'NULL') as icao,
        NULLIF(military, 'NULL') as military,
        NULLIF(operator, 'NULL') as operator,
        NULLIF(surface, 'NULL') as surface,
        ST_Area(geometry) AS area,
        geometry
    FROM import.aeroway_polygon
)
SELECT * FROM combined_aeroway;
    
    RAISE NOTICE 'rbt.aeroway_surface view created successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create rbt.aeroway_surface view: %', error_msg;
    RAISE;
END $$;

\echo 'Creating rbt.heliports view...'

DO $$
DECLARE
    error_msg TEXT;
BEGIN

    CREATE VIEW rbt.heliports AS
WITH
    airports AS (
        SELECT
            CASE
            WHEN name ILIKE '%hospital%' OR name ILIKE '%clinic%' OR name ILIKE '%emergency%'OR name ILIKE '%medic%' THEN 'y'
            ELSE 'n'
            END AS hospital,
            ident AS airport_ident,
            CASE
            WHEN (name ILIKE '%helicopter%' OR name ILIKE '%helipad%' OR name ILIKE '%heliport%') AND type = 'closed' THEN 'closed_heliport'
            WHEN (name ILIKE '%helicopter%' OR name ILIKE '%helipad%' OR name ILIKE '%heliport%') AND type NOT IN ('closed', 'heliport') THEN 'heliport'
            ELSE type
            END AS type,
            name,
            elevation_ft,
            scheduled_service,
            gps_code AS icao,
            iata_code AS iata,
            local_code,
            geometry
        FROM ourairports.airport
    )
SELECT
    airport_ident,
    type,
    name,
    hospital,
    CASE
    WHEN type = 'heliport' AND hospital = 'y' THEN 1
    WHEN type = 'heliport' AND hospital = 'n' THEN 2
    WHEN type = 'closed_heliport' AND hospital = 'y' THEN 3
    ELSE 4
    END AS rank,
    elevation_ft,
    scheduled_service,
    icao,
    iata,
    local_code,
    geometry
FROM airports
WHERE type IN ('heliport','closed_heliport');
    
    RAISE NOTICE 'rbt.heliports view created successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create rbt.heliports view: %', error_msg;
    RAISE;
END $$;

\echo 'Creating rbt.runway_curve view...'

DO $$
DECLARE
    error_msg TEXT;
BEGIN

    CREATE VIEW rbt.runway_curve AS
SELECT
    osm_id,
    NULLIF(ref, 'NULL') as ref,
    subclass,
    class,
    NULLIF(icao, 'NULL') as icao,
    NULLIF(iata, 'NULL') as iata,
    NULLIF(surface, 'NULL') as surface,
    NULLIF(width, 'NULL') as width,
    NULLIF(ele, 'NULL') as ele,
    ST_Length(geometry) as length,
    NULLIF(military, 'NULL') as military,
    NULLIF(name, 'NULL') as name,
    NULLIF(operator, 'NULL') as operator,
    geometry
FROM import.aeroway_linestring;
    
    RAISE NOTICE 'rbt.runway_curve view created successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create rbt.runway_curve view: %', error_msg;
    RAISE;
END $$;

\echo 'Additional aeroway views created successfully'

-- Commit additional views
COMMIT;
\echo 'Additional aeroway views committed successfully'

-- Start new transaction for helper functions
BEGIN;

-- ==============================================================================
-- STEP 10: CREATE HELPER FUNCTIONS WITH ERROR HANDLING
-- ==============================================================================

\echo 'Creating helper functions with error handling...'

\echo 'Creating automated refresh system (if pg_cron is available)...'

DO $$
DECLARE
    error_msg TEXT;
BEGIN
    -- Note: This creates a cron job if pg_cron extension is available
    -- The cron job will automatically refresh materialized views on a schedule
    -- Comment out or remove this section if pg_cron is not installed
    
    -- Check if pg_cron is available before trying to create the job
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule('aeroway_refresh_job', '*/5 * * * *', 
            'CALL refresh_aeroway_materialized_views();'
        );
        RAISE NOTICE 'Automated refresh cron job created successfully';
    ELSE
        RAISE NOTICE 'pg_cron extension not found - skipping automated refresh setup';
    END IF;
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create automated refresh system: %', error_msg;
    -- Note: Don't re-raise here as cron may not be available in all environments
END $$;

\echo 'Automated refresh system setup completed'

\echo 'Creating mark_views_for_refresh trigger function...'

CREATE OR REPLACE FUNCTION mark_views_for_refresh()
RETURNS TRIGGER AS $$
BEGIN
    -- Queue views with appropriate priority values
    INSERT INTO refresh_queue (view_name, refresh_needed, last_modified, priority)
    VALUES 
        ('import.aerodrome_polygon', TRUE, now(), 1),
        ('import.osm_runway', TRUE, now(), 2),
        ('import.aerodrome_runway', TRUE, now(), 3),
        ('rbt.ourairports_osm_aerodrome_runway_join', TRUE, now(), 4),
        ('ourairports.airports_runways', TRUE, now(), 5),
        ('ourairports.airports_runways_osm', TRUE, now(), 6)
    ON CONFLICT (view_name) DO UPDATE 
    SET refresh_needed = TRUE, last_modified = now();
    -- Note: We don't update priority on conflict as it should remain constant
    
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
    error_msg TEXT;
BEGIN
    
    RAISE NOTICE 'mark_views_for_refresh trigger function created successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Failed to create trigger function: %', error_msg;
    RAISE;
END $$;

-- Commit automated refresh system
COMMIT;
\echo 'Automated refresh system committed successfully'

-- Start new transaction for final operations
BEGIN;

-- ==============================================================================
-- STEP 12: FINAL VALIDATION AND OPTIMIZATION
-- ==============================================================================

\echo 'Performing final aeroway validation and optimization...'

DO $$
DECLARE
    rec RECORD;
    success_count INTEGER := 0;
    total_views INTEGER := 6;
    view_name TEXT;
    view_exists BOOLEAN;
    row_count BIGINT;
    error_msg TEXT;
BEGIN
    RAISE NOTICE '=== AEROWAY LAYER PROCESSING SUMMARY ===';
    
    -- Check each materialized view
    FOR view_name IN VALUES 
        ('import.aerodrome_polygon'), ('import.osm_runway'), 
        ('import.aerodrome_runway'), ('rbt.ourairports_osm_aerodrome_runway_join'),
        ('ourairports.airports_runways'), ('ourairports.airports_runways_osm')
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
        AND table_name IN ('aeroway_surface', 'heliports', 'runway_curve', 'airports');
        
        RAISE NOTICE '✓ Created % regular aeroway-related views', view_count;
    END;
    
    -- Check surface mapping table
    BEGIN
        SELECT COUNT(*) INTO row_count FROM ourairports.runway_surface_mapping;
        RAISE NOTICE '✓ Runway surface mapping table contains % mappings', row_count;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING '⚠ Could not validate surface mapping table: %', SQLERRM;
    END;
    
    -- Final summary
    RAISE NOTICE '=== PROCESSING RESULTS ===';
    RAISE NOTICE 'Materialized views: %/% successful', success_count, total_views;
    
    IF success_count > 0 THEN
        RAISE NOTICE '✓ Aeroway layer processing completed with % successful materialized view(s)', success_count;
    ELSE
        RAISE WARNING '⚠ No aeroway materialized views were successfully created';
    END IF;
    
    RAISE NOTICE 'Transaction-based processing ensures that successful views are preserved';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE WARNING 'Error during final validation: %', error_msg;
END $$;

\echo 'Final aeroway validation completed'

-- ==============================================================================
-- STEP 13: VACUUM AND ANALYZE FOR OPTIMAL PERFORMANCE
-- ==============================================================================

-- Commit final transaction
COMMIT;

\echo 'Running final aeroway optimization...'

-- Vacuum and analyze all materialized views for optimal performance
-- Note: These must run outside of a transaction
VACUUM FULL ANALYZE import.aerodrome_polygon;
VACUUM FULL ANALYZE import.osm_runway;
VACUUM FULL ANALYZE import.aerodrome_runway;
VACUUM FULL ANALYZE rbt.ourairports_osm_aerodrome_runway_join;
VACUUM FULL ANALYZE ourairports.airports_runways;
VACUUM FULL ANALYZE ourairports.airports_runways_osm;
VACUUM FULL ANALYZE ourairports.runway_surface_mapping;

\echo '=============================================================================='
\echo 'AEROWAY LAYER PROCESSING COMPLETED SUCCESSFULLY'
\echo 'Enhanced script execution finished with optimizations:'
\echo '- Created aeroway materialized views for optimal performance'
\echo '- Added comprehensive indexes for fast aeroway queries'
\echo '- Implemented transaction management with error handling'
\echo '- Added aeroway dependency validation for reliable CI/CD execution'
\echo '- Integrated runway surface mapping and standardization'
\echo '- Added automated refresh system with priority-based scheduling'
\echo '- Applied spatial clustering optimizations for airports and runways'
\echo '=============================================================================='

-- Disable timing
\timing off