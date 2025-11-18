-- ==============================================================================
-- CONTOUR LAYER SQL SCRIPT FOR CI/CD PROCESSING
-- Optimized for execution after imposm3 import completion
-- Handles contour lines and glacier contours with zoom-level views
-- ==============================================================================

-- Enable timing for CI/CD monitoring
\timing on

-- Start transaction with error handling
BEGIN;

-- ==============================================================================
-- STEP 1: CONFIGURATION AND PERFORMANCE SETTINGS
-- ==============================================================================

-- Set memory configurations for heavy spatial operations
SET LOCAL work_mem = '512MB';
SET LOCAL maintenance_work_mem = '1GB';
SET LOCAL max_parallel_workers_per_gather = 2;
SET LOCAL parallel_tuple_cost = 0.1;
SET LOCAL parallel_setup_cost = 1000;
SET LOCAL enable_parallel_hash = on;

-- Disable autocommit to ensure transaction consistency
SET LOCAL autocommit = off;

\echo 'Contour layer processing started with enhanced performance settings'

-- ==============================================================================
-- STEP 2: DEPENDENCY VALIDATION
-- ==============================================================================

\echo 'Validating contour data dependencies...'

DO $$
DECLARE
    contour_exists BOOLEAN := false;
    glacier_contour_exists BOOLEAN := false;
    error_msg TEXT;
BEGIN
    -- Check if contour table exists
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'rbt' AND table_name = 'contour') THEN
        contour_exists := true;
        RAISE NOTICE 'Contour table found - will create contour indexes and views';
    ELSE
        RAISE NOTICE 'Contour table not found - skipping contour processing';
    END IF;
    
    -- Check if contour_glacier table exists
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'rbt' AND table_name = 'contour_glacier') THEN
        glacier_contour_exists := true;
        RAISE NOTICE 'Glacier contour table found - will create glacier contour indexes and views';
    ELSE
        RAISE NOTICE 'Glacier contour table not found - skipping glacier contour processing';
    END IF;
    
    -- Validate that at least one contour table exists
    IF NOT contour_exists AND NOT glacier_contour_exists THEN
        RAISE EXCEPTION 'No contour tables found (rbt.contour or rbt.contour_glacier). Cannot proceed with contour layer processing.';
    END IF;
    
    RAISE NOTICE 'Contour data validation completed successfully';
    
EXCEPTION WHEN OTHERS THEN
    error_msg := SQLERRM;
    RAISE EXCEPTION 'Contour dependency validation failed: %', error_msg;
END $$;

\echo 'Contour data validation completed successfully'

-- ==============================================================================
-- STEP 3: DROP EXISTING CONTOUR VIEWS FOR CLEAN REBUILD
-- ==============================================================================

\echo 'Dropping existing contour views for clean rebuild...'

-- Drop regular contour views
DROP VIEW IF EXISTS rbt.contour_z8 CASCADE;
DROP VIEW IF EXISTS rbt.contour_z10 CASCADE;
DROP VIEW IF EXISTS rbt.contour_z12 CASCADE;

-- Drop glacier contour views
DROP VIEW IF EXISTS rbt.contour_glacier_z8 CASCADE;
DROP VIEW IF EXISTS rbt.contour_glacier_z10 CASCADE;
DROP VIEW IF EXISTS rbt.contour_glacier_z12 CASCADE;

\echo 'Existing contour views dropped successfully'

-- ==============================================================================
-- STEP 4: CREATE CONTOUR INDEXES FOR PERFORMANCE
-- ==============================================================================

\echo 'Creating contour indexes for optimal performance...'

-- Standard contour indexes (conditional)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'rbt' AND table_name = 'contour') THEN
        CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_contour_nth_line ON rbt.contour USING btree(nth_line);
        CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_contour_elevation ON rbt.contour USING btree(elevation);
        CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_contour_geometry ON rbt.contour USING gist(geometry);
        RAISE NOTICE 'Standard contour indexes created successfully';
    ELSE
        RAISE NOTICE 'Standard contour table not found, skipping standard contour indexes';
    END IF;
    
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'rbt' AND table_name = 'contour_glacier') THEN
        CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_contour_glacier_nth_line ON rbt.contour_glacier USING btree(nth_line);
        CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_contour_glacier_elevation ON rbt.contour_glacier USING btree(elevation);
        CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_contour_glacier_geometry ON rbt.contour_glacier USING gist(geometry);
        RAISE NOTICE 'Glacier contour indexes created successfully';
    ELSE
        RAISE NOTICE 'Glacier contour table not found, skipping glacier contour indexes';
    END IF;
END $$;

\echo 'Contour indexes created successfully'

-- ==============================================================================
-- STEP 5: CREATE CONTOUR VIEWS FOR ZOOM LEVELS
-- ==============================================================================

\echo 'Creating contour views for zoom levels...'

-- Standard contour views (conditional creation)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'rbt' AND table_name = 'contour') THEN
        EXECUTE '
        CREATE VIEW rbt.contour_z8 AS 
        SELECT elevation, nth_line, negative, geometry 
        FROM rbt.contour 
        WHERE nth_line = 10;
        
        CREATE VIEW rbt.contour_z10 AS 
        SELECT elevation, nth_line, negative, geometry 
        FROM rbt.contour 
        WHERE nth_line = 5;
        
        CREATE VIEW rbt.contour_z12 AS 
        SELECT elevation, nth_line, negative, geometry 
        FROM rbt.contour 
        WHERE nth_line = 2;
        ';
        
        RAISE NOTICE 'Standard contour views created successfully';
    ELSE
        RAISE NOTICE 'Standard contour table not found, skipping standard contour views';
    END IF;
    
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'rbt' AND table_name = 'contour_glacier') THEN
        EXECUTE '
        CREATE VIEW rbt.contour_glacier_z8 AS 
        SELECT elevation, nth_line, negative, geometry 
        FROM rbt.contour_glacier 
        WHERE nth_line = 10;
        
        CREATE VIEW rbt.contour_glacier_z10 AS 
        SELECT elevation, nth_line, negative, geometry 
        FROM rbt.contour_glacier 
        WHERE nth_line = 5;
        
        CREATE VIEW rbt.contour_glacier_z12 AS 
        SELECT elevation, nth_line, negative, geometry 
        FROM rbt.contour_glacier 
        WHERE nth_line = 2;
        ';
        
        RAISE NOTICE 'Glacier contour views created successfully';
    ELSE
        RAISE NOTICE 'Glacier contour table not found, skipping glacier contour views';
    END IF;
END $$;

\echo 'Contour views created successfully'

-- ==============================================================================
-- STEP 6: ANALYZE CONTOUR TABLES FOR OPTIMAL QUERY PLANNING
-- ==============================================================================

\echo 'Analyzing contour tables for optimal query planning...'

-- Analyze contour tables (conditional)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'rbt' AND table_name = 'contour') THEN
        ANALYZE rbt.contour;
        RAISE NOTICE 'Standard contour table analyzed successfully';
    END IF;
    
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'rbt' AND table_name = 'contour_glacier') THEN
        ANALYZE rbt.contour_glacier;
        RAISE NOTICE 'Glacier contour table analyzed successfully';
    END IF;
END $$;

\echo 'Contour table analysis completed'

-- ==============================================================================
-- STEP 7: FINAL VALIDATION AND COMMIT
-- ==============================================================================

\echo 'Performing final contour validation...'

DO $$
DECLARE
    rec RECORD;
    error_count INTEGER := 0;
    contour_exists BOOLEAN := false;
    glacier_contour_exists BOOLEAN := false;
BEGIN
    -- Check if contour tables exist
    contour_exists := EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'rbt' AND table_name = 'contour');
    glacier_contour_exists := EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'rbt' AND table_name = 'contour_glacier');
    
    -- Validate standard contour views if table exists
    IF contour_exists THEN
        FOR rec IN 
            SELECT 'rbt.contour_z8' as view_name
            UNION ALL SELECT 'rbt.contour_z10'
            UNION ALL SELECT 'rbt.contour_z12'
        LOOP
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.views 
                WHERE table_schema = split_part(rec.view_name, '.', 1) 
                AND table_name = split_part(rec.view_name, '.', 2)
            ) THEN
                RAISE WARNING 'Contour view % was not created successfully', rec.view_name;
                error_count := error_count + 1;
            END IF;
        END LOOP;
        
        -- Check row count for standard contour table
        EXECUTE 'SELECT COUNT(*) FROM rbt.contour' INTO rec;
        RAISE NOTICE 'Standard contour table has % rows', rec.count;
    END IF;
    
    -- Validate glacier contour views if table exists
    IF glacier_contour_exists THEN
        FOR rec IN 
            SELECT 'rbt.contour_glacier_z8' as view_name
            UNION ALL SELECT 'rbt.contour_glacier_z10'
            UNION ALL SELECT 'rbt.contour_glacier_z12'
        LOOP
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.views 
                WHERE table_schema = split_part(rec.view_name, '.', 1) 
                AND table_name = split_part(rec.view_name, '.', 2)
            ) THEN
                RAISE WARNING 'Glacier contour view % was not created successfully', rec.view_name;
                error_count := error_count + 1;
            END IF;
        END LOOP;
        
        -- Check row count for glacier contour table
        EXECUTE 'SELECT COUNT(*) FROM rbt.contour_glacier' INTO rec;
        RAISE NOTICE 'Glacier contour table has % rows', rec.count;
    END IF;
    
    IF error_count > 0 THEN
        RAISE EXCEPTION 'Contour layer processing completed with % errors. Review warnings above.', error_count;
    ELSE
        RAISE NOTICE 'All contour views created successfully and validated';
    END IF;
END $$;

\echo 'Final contour validation completed successfully'

-- Commit transaction
COMMIT;

\echo '=============================================================================='
\echo 'CONTOUR LAYER PROCESSING COMPLETED SUCCESSFULLY'
\echo 'Enhanced contour script execution finished with optimizations:'
\echo '- Created contour indexes for optimal performance'
\echo '- Added zoom-level views for both standard and glacier contours'
\echo '- Implemented transaction management with error handling'
\echo '- Added dependency validation for reliable CI/CD execution'
\echo '=============================================================================='

-- Disable timing
\timing off
