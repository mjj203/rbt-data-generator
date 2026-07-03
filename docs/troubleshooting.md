# Troubleshooting

## First steps for any problem

=== "rbt CLI"

    ```bash
    # Pre-flight validation: config, tools, database, disk, memory, project layout
    rbt validate

    # Fast liveness probe (database round-trip + PATH warnings)
    rbt health

    # End-to-end sanity check: validate → bootstrap → schemas → tile dry-runs
    rbt smoke
    ```

=== "Docker Compose"

    ```bash
    # The container HEALTHCHECK already runs `rbt health` every 30s
    docker compose ps

    # Run the checks inside a running container
    docker compose exec rbt-tiles rbt validate
    docker compose exec rbt-tiles rbt health

    # One-shot smoke test (smoke profile)
    docker compose --profile smoke up rbt-smoke
    ```

## Log locations

All `rbt` commands that mutate state duplicate their logs to
`$SHARED_LOG_DIR` (default `./output/logs`):

- `rbt_<timestamp>.log` — per-invocation CLI log (override with the global
  `--log-file` option, disable with `--no-log-file`).
- `schema_<key>_<timestamp>.log` — `psql` output for each `rbt schema run` unit.
- `osm_import.log` — the OSM importer leaf script (`OSM_LOG_FILE` in
  `config/rbt.conf`).
- Per-layer tile logs live next to the tiles:
  `output/tiles/<layer_type>/<projection>/<layer>_<projection>.log`, plus
  `merge_<projection>.log` for tile-join and `<layer_type>_4326_mvt.log`
  for the EPSG:4326 backend.

## Database connection fails

```bash
# Check the configuration values being resolved
grep -E '^(DATABASE_|PG_)' config/rbt.conf

# Run the full validator (reports each connection value and tests the DB)
rbt validate
```

Common causes:

- `DATABASE_PASSWORD`/`PG_PASS` is unset and the server requires a password.
- The host in `DATABASE_HOST` is unreachable from the container (use the Compose service name, e.g. `postgres`, not `localhost`).
- PostgreSQL client version mismatch — the Dockerfiles install `postgresql-client-18`; older clients may miss features used by PG 18 servers.

## Setup failures (database initialization)

```bash
# Preview what setup would run, step by step
rbt setup --all --dry-run

# Re-run only the failed step
rbt setup --import-geonames
rbt setup --import-buildings

# Debug-level CLI logging
rbt --debug setup --import-reference-data

# The importer leaf scripts honor SCRIPT_* variables from config/rbt.conf;
# override per run to preserve temp files for inspection. Note: the OSM
# importer is the one exception — it honors OSM_CLEANUP_ON_EXIT, not
# SCRIPT_CLEAN_TEMP_FILES (which the buildings/geonames/reference importers use).
OSM_CLEANUP_ON_EXIT=false SCRIPT_DEBUG=true rbt import osm -- --all
```

## Tile generation issues

```bash
# Confirm the rbt.* views exist
psql "host=$DATABASE_HOST dbname=$DATABASE_NAME user=$DATABASE_USER password=$DATABASE_PASSWORD" -c "\dv rbt.*"
# ...and recreate them if missing
rbt schema run --all

# Dry-run a specific selection with verbose logs
rbt --verbose tiles --layer-type cultural --building --dry-run

# Generate a single layer in a single projection
rbt tiles layer water --projection 3857 --dry-run
```

### Stale FlatGeoBuf cache (3857/3395)

The Mercator backends export each layer to a FlatGeoBuf file before running
tippecanoe and **reuse an existing `.fgb` on the next run** (you will see a
`REUSING cached export` warning in the log). After a database refresh or
`rbt schema run`, the cached export is stale and silently produces stale
tiles. Pass `--force` to re-export:

```bash
rbt tiles --layer-type physical --projection 3857 --water --force
rbt tiles layer water --projection 3857 --force
```

### EPSG:4326 output is a directory, not MBTiles

The 4326 backend uses GDAL's MVT driver, not tippecanoe. Expect:

- Output is a **tile directory** (`output/tiles/<layer_type>/4326/<dataset>_tiles/{z}/{x}/{y}.pbf`
  plus `metadata.json`), never an `.mbtiles` file.
- `--tile-join` and `--add-btis` do not apply to 4326.
- Each run **deletes and rewrites the whole tile directory** — do not point a
  live tile server at it mid-generation.
- One multi-table `ogr2ogr -f MVT` call produces the dataset; check
  `<layer_type>_4326_mvt.log` in the output directory for driver errors.

### Deprecated bash escape hatch

If you suspect an engine regression, the deprecated bash generators are still
reachable for comparison (see [parity-runbook.md](parity-runbook.md)):

```bash
rbt tiles --mode bash --layer-type physical --projection 3857 --water --dry-run
```

## Missing `postgresql.conf`, `tile-server.json`, or `prometheus.yml`

These files are mounted by `docker-compose.yml` but templated/shipped under [`config/`](https://github.com/MJJ203/rbt-data-generator/blob/main/config/). The defaults are safe for single-node operation; tune them before production deployment.

## Tippecanoe or imposm not found

The production Dockerfile builds tippecanoe from the pinned felt/tippecanoe fork and downloads imposm3 0.14.2 with checksum verification. If building locally, ensure:

```bash
rbt validate
```

reports all required tools (`psql`, `ogr2ogr`, `imposm`, `tippecanoe`, `tile-join`, `wget`, `aws`).

## OSM updates not running

```bash
# Is the supervisor alive, and when was the last applied change?
rbt osm status

# Restart the supervisor
rbt osm stop
rbt osm run
```

`rbt osm status` exits non-zero when the supervisor is not running, so it is
safe to use in monitoring scripts. The supervisor writes its pidfile to
`$SHARED_TEMP_DIR/imposm-run.pid` (default `./output/temp/`); if a stale
pidfile points at a dead process it is cleaned up automatically.

## Insufficient resources

- Check disk space (`df -h`) and memory (`free -g` / `sysctl hw.memsize`) — `rbt validate` checks both against `DISK_SPACE_REQUIRED_GB`/`MEMORY_REQUIRED_GB`.
- `MAX_PARALLEL_JOBS` is reported by `rbt validate` but is not yet wired to any real parallelism in the Python CLI — lowering it has no effect today (see [Configuration](configuration.md)).
- Set `SCRIPT_PARALLEL_INGESTION=false` to reduce peak memory during setup.

## Configuration inspection

```bash
# rbt validate prints the resolved DATABASE_HOST/USER/NAME (not the port or
# password — the password is only flagged as unset, never printed)
rbt validate

# Validate referenced variables exist in the config file
grep -E "(DATABASE_|TILE_|OSM_)" config/rbt.conf

# Sanity-check the tile pipeline end to end without writing anything
rbt --verbose tiles --all --dry-run
```

## Advanced debugging

```bash
# Re-run a single schema unit with full psql output captured
rbt schema run water
tail -n 50 output/logs/schema_water_*.log

# Inspect a layer's full registry definition (zoom, filters, tippecanoe flags)
rbt layers show water

# Tile server health (serve profile)
curl http://localhost:8080/health

# Debug-level logging for any command
rbt --debug tiles --layer-type physical --water --dry-run
```
