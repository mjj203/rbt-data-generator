# Configuration Reference

RBT Vector Tiles uses a centralized configuration file (`config/rbt.conf`) as the single source of truth. Environment variables override values in the file at process start; legacy `PG_*` names are still accepted.

## Resolution order (highest priority first)

1. Environment variables exported at the shell (or passed via `docker-compose`).
2. Values in [`config/rbt.conf`](https://github.com/MJJ203/rbt-data-generator/blob/main/config/rbt.conf).
3. Built-in defaults — the `Settings` dataclass fields in `src/rbt/config.py` for the Python CLI; defensive fallbacks in `scripts/lib/config.sh` for the bash leaf scripts.

## Variable ownership

Every table below has an **Owner** column, verified against the actual consumers (not just where a variable is declared in `rbt.conf`):

| Owner | Meaning |
|---|---|
| **Python** | Read by `load_settings()` in [`src/rbt/config.py`](https://github.com/MJJ203/rbt-data-generator/blob/main/src/rbt/config.py) only. The bash leaf scripts never see it, even indirectly. |
| **Bash** | Read only by the bash leaf scripts under `setup/data-sources/` (directly, or via `scripts/lib/config.sh`/`logging.sh`) or the deprecated `production/` generators. The Python CLI never reads it. |
| **Shared** | Read by both: either the same name resolves in `Settings` *and* in a bash script, or Python passes it to child processes via `Settings.subprocess_env()`. |
| **Unused** | Declared in `rbt.conf` but not read by anything in this repository today — likely a holdover from a retired script. Kept for backward compatibility with external tooling; safe to ignore. |

### General processing

| Variable | Owner | Default | Purpose |
|---|---|---|---|
| `MAX_PARALLEL_JOBS` | Python | `4` | Reported by `rbt validate`; not yet wired to real parallelism (see [Performance](performance.md)). Distinct from `SCRIPT_MAX_PARALLEL_JOBS` below. |
| `RETRY_COUNT` | Python | `3` | Retry attempts for `rbt.process.run_with_retry`. |
| `RETRY_DELAY` | Shared | `30` (Python) / `10` (bash) | Python retry backoff seconds, default `30` (`config.py`). `import-osm-data.sh` also falls back to this name but with its own unsourced default of `10` (the other three importers use `SCRIPT_RETRY_DELAY` instead — a pre-existing inconsistency, not a typo). |
| `LOG_LEVEL` | Python | `INFO` | `DEBUG`, `INFO`, `WARN`, `ERROR`. |
| `DEBUG` | Shared | `false` | Canonical name resolved first by `Settings.debug`; `SCRIPT_DEBUG` (below) is the fallback alias. |
| `VERBOSE` | Shared | `false` | Canonical name resolved first by `Settings.verbose`; `SCRIPT_VERBOSE` (below) is the fallback alias. |
| `CLEAN_TEMP_FILES` | Unused | `true` | Declared in `rbt.conf` but shadowed: `import-buildings.sh`/`import-geonames.sh`/`import-reference-data.sh` each read a local `CLEAN_TEMP_FILES` seeded from `SCRIPT_CLEAN_TEMP_FILES` (default `false`) instead of this key. |
| `PARALLEL_INGESTION` | Unused | `false` | Same shadowing pattern — the importers read `SCRIPT_PARALLEL_INGESTION` into a local `PARALLEL_INGESTION`, ignoring this top-level key. |
| `VALIDATE_DOWNLOADS` | Bash | `true` | Root-level fallback consumed by `import-osm-data.sh` only when `OSM_VALIDATE_DOWNLOADS` is unset (see OSM import section). |

### Tile generation

| Variable | Owner | Default | Purpose |
|---|---|---|---|
| `TILE_CACHE_DIR` | Shared | `./output/tiles` | Where MBTiles/PBF tiles are written. Read by both the native engine and the deprecated bash generators (`--mode bash`). |
| `TILE_TEMP_DIR` | Shared | `/tmp/tiles` | Scratch space for `tippecanoe -t`. Keep on fast storage. |
| `TILE_MAX_ZOOM` | Shared | `13` | Maximum zoom level. |
| `TILE_MIN_ZOOM` | Shared | `0` | Minimum zoom level. |
| `SUPPORTED_PROJECTIONS` | Bash | `"3857 3395 4326"` | Read-only; the Python CLI derives supported projections from `config/layers.yml` instead. |
| `DEFAULT_PROJECTION` | Unused (by `rbt tiles`) | `3857` | Loaded into `Settings.default_projection` but not read by `rbt tiles` or `rbt tiles layer` — Typer supplies its own defaults (`--projection all` and `--projection 3857` respectively) regardless of this value. Only consumed by `production/generate-tiles.sh` when invoked directly (outside `--mode bash`). |
| `LAYER_TYPES` | Bash | `"physical cultural"` | Read-only; the Python CLI hardcodes the same two types. |

### Database connection

| Variable | Owner | Legacy | Default | Purpose |
|---|---|---|---|---|
| `DATABASE_HOST` | Shared | `PG_HOST` | `localhost` | PostgreSQL host. |
| `DATABASE_PORT` | Shared | `PG_PORT` | `5432` | PostgreSQL port. |
| `DATABASE_NAME` | Shared | `PG_DATABASE` | `rbt` | Database name. |
| `DATABASE_USER` | Shared | `PG_USR` | `postgres` | Database user. |
| `DATABASE_PASSWORD` | Shared | `PG_PASS` | *(unset)* | Database password. |

These five are resolved independently by both sides using identical rules (`Settings` in Python, `rbt_config_load` in `scripts/lib/config.sh`) — see [Project Tour](project-structure.md#configuration-resolution) for why. Python also bundles them into a `PG*`/`PG_*`/`DATABASE_*` environment for every child process it spawns (`Settings.subprocess_env()`).

### Database performance tuning

| Variable | Owner | Default | Purpose |
|---|---|---|---|
| `DATABASE_WORK_MEM` | Bash | `32GB` | Session `work_mem` (ok to lower for small boxes). Ops/docs reference only — not read by any script. |
| `DATABASE_MAINTENANCE_WORK_MEM` | Bash | `64GB` | `maintenance_work_mem` during index builds. Ops/docs reference only. |
| `DATABASE_MAX_PARALLEL_WORKERS` | Bash | `8` | Matches `max_parallel_workers_per_gather`. Ops/docs reference only. |
| `DATABASE_EFFECTIVE_CACHE_SIZE` | Bash | `192GB` | Planner hint; set to ~75% of system RAM. Ops/docs reference only. |
| `DATABASE_MAX_CONNECTIONS` | Bash | `100` | Used by docs/ops only; set on the server. |
| `DATABASE_CONNECTION_TIMEOUT` | Bash | `300` | Client-side psql timeout seconds. Ops/docs reference only. |
| `DATABASE_EXTENSIONS` | Python | `"postgis postgis_raster hstore pg_trgm"` | Created during `rbt setup`; checked by `rbt validate`. |
| `DATABASE_SCHEMAS` | Python | `"fieldmap mirta naturalearth ourairports rbt geonames overture"` | Expected schemas after setup; checked by `rbt validate`. |

### OSM import

| Variable | Owner | Default | Purpose |
|---|---|---|---|
| `OSM_LOG_FILE` | Bash | `${SHARED_LOG_DIR:-./output/logs}/osm_import.log` | Per-run OSM log. Falls back to `./output/logs/...` when `SHARED_LOG_DIR` is unset (only `./setup/.../logs/osm_import.log` if the script runs without sourcing `rbt.conf` at all). |
| `OSM_DATA_DIR` | Bash | `/mnt/data` | Planet PBF + diffs landing zone. |
| `OSM_CONFIG_FILE` | Shared | `./setup/data-sources/osm/imposm-config.json` | imposm3 config; read by `Settings.osm_config_file` (Python's `rbt osm run` supervisor) and by `import-osm-data.sh` as a fallback default. |
| `OSM_MAPPING_FILE` | Bash | `./setup/data-sources/osm/imposm-mapping.yaml` | imposm3 mapping. |
| `OSM_CACHE_DIR` | Bash | `/mnt/cache` | imposm3 cache directory. |
| `OSM_DIFF_DIR` | Bash | `/mnt/diff` | Downloaded OSC diffs. |
| `OSM_CONNECTION` | Bash | derived from `DATABASE_*` | imposm3 connection string, built from the resolved `DATABASE_USER`/`DATABASE_PASSWORD`/`DATABASE_HOST`/`DATABASE_PORT`/`DATABASE_NAME` so imposm targets the same database as the rest of the CLI. Only falls back to the hardcoded `postgis://postgres:postgres@localhost/rbt?prefix=NONE` if the script runs without sourcing `rbt.conf`. |
| `OSM_SRID` | Bash | `3857` | SRID of imposm3-imported tables. |
| `ARIA2C_MAX_DOWNLOADS` | Bash | `12` | Concurrent aria2c downloads. |
| `ARIA2C_MAX_CONNECTIONS` | Bash | `16` | Connections per aria2c download. |
| `ARIA2C_SPLITS` | Bash | `9` | aria2c `--split`. |
| `WGET_PARALLEL_JOBS` | Bash | `8` | Fallback parallelism when wget is used. |
| `DIFF_START_SEQ` | Bash | `713` | Starting diff sequence for bulk backfill. |
| `DIFF_END_SEQ` | Bash | `730` | Ending diff sequence for bulk backfill. |
| `OSM_CLEANUP_ON_EXIT` | Bash | `true` | Remove temp files on exit. |
| `OSM_VALIDATE_DOWNLOADS` | Bash | `true` | Size-check downloaded files. |
| `OSM_MIN_PBF_SIZE_MB` | Bash | `50000` | Minimum acceptable PBF size in MB for `OSM_VALIDATE_DOWNLOADS`'s sanity check. Planet-sized floor by default so a truncated planet download is caught; lower it (e.g. `10`) when importing a small regional extract. |
| `OSM_HEALTH_CHECK_PORT` | Unused | `8080` | Referenced only in a no-op log message in `import-osm-data.sh` (`start_health_check_server`); not functionally used. `rbt health` (the Docker `HEALTHCHECK`) takes no port argument. |

### Shared script settings

| Variable | Owner | Default | Purpose |
|---|---|---|---|
| `SHARED_LOG_DIR` | Shared | `./output/logs` | Read by `Settings.shared_log_dir` and directly by the bash importers/`scripts/lib/logging.sh`. |
| `SHARED_TEMP_DIR` | Shared | `./output/temp` | Read by `Settings.shared_temp_dir` and directly by the bash importers. |
| `SCRIPT_MAX_PARALLEL_JOBS` | Bash | `4` | Importer job pool size (distinct from Python's `MAX_PARALLEL_JOBS` above). |
| `SCRIPT_RETRY_COUNT` | Bash | `3` | Retries for importer sub-steps. |
| `SCRIPT_RETRY_DELAY` | Bash | `30` | Retry delay seconds (three of the four importers; `import-osm-data.sh` uses bare `RETRY_DELAY` instead — see above). |
| `SCRIPT_CONNECTION_TIMEOUT` | Bash | `300` | psql connection timeout. |
| `SCRIPT_PARALLEL_INGESTION` | Bash | `false` | Toggle full parallel ingestion. |
| `SCRIPT_DEBUG` | Shared | `false` | Also accepted by Python as a fallback for `DEBUG` (`Settings.debug`). |
| `SCRIPT_VERBOSE` | Shared | `false` | Also accepted by Python as a fallback for `VERBOSE` (`Settings.verbose`). |
| `SCRIPT_CLEAN_TEMP_FILES` | Bash | `false` | Keep temp files for postmortem. |

### Resource limits

| Variable | Owner | Default | Purpose |
|---|---|---|---|
| `DISK_SPACE_REQUIRED_GB` | Python | `100` | `rbt validate` pre-flight check minimum. |
| `MEMORY_REQUIRED_GB` | Python | `16` | `rbt validate` pre-flight check minimum. |
| `HEALTH_CHECK_PORT` | Unused | `8080` | Referenced only in a no-op log message in `import-osm-data.sh` (as a fallback for `OSM_HEALTH_CHECK_PORT`); not functionally used. `rbt health` takes no port argument. |
| `HEALTH_CHECK_INTERVAL` | Unused | `30` | Not read anywhere; the Docker `HEALTHCHECK interval` is set in `Dockerfile.production` instead. |

## Layer registry validation

[`config/layers.yml`](https://github.com/MJJ203/rbt-data-generator/blob/main/config/layers.yml) is strictly validated when `load_registry()` parses it
(`src/rbt/layers.py`), not just loosely typed — malformed registries fail
fast with a `LayerRegistryError` instead of surfacing as confusing runtime
errors deep in tile generation. Checks include:

- **Missing required fields** — every layer needs `source_table`; every
  projection needs `epsg`; every `gdal_mvt` source table needs `target`,
  `minzoom`, and `maxzoom`.
- **Unknown projection codes** — a layer's `projections:` list must only
  reference codes declared under the top-level `projections:` section.
- **Dangling category references** — every layer key listed under
  `categories.<type>.<category>` must exist under that layer type.
- **Malformed `gdal_mvt` groups** — each entry under
  `gdal_mvt.datasets.<type>.groups.<category>.<table>` is validated the same
  way as a schema field, so a typo'd `minzoom` fails immediately.

See the schema comment at the top of `config/layers.yml` (`:1-29`) for the
full per-layer field reference. Example error for a layer referencing an
undeclared projection:

```
rbt.layers.LayerRegistryError: layer 'building' (cultural): references
unknown projection(s) ['9999'] — declare them under the 'projections'
section first
```

## Backward compatibility

The legacy `PG_HOST`/`PG_PORT`/`PG_USR`/`PG_PASS`/`PG_DATABASE` variables remain recognized. `scripts/lib/config.sh` resolves them once at script start so that individual scripts only need to source the shared config helper:

```bash
source "${PROJECT_ROOT}/scripts/lib/config.sh"
rbt_config_load   # sets DATABASE_* + exports PG_* for legacy tools
```

## Verifying your configuration

```bash
rbt validate
```

See [troubleshooting.md](troubleshooting.md) if validation fails.
