# Configuration Reference

RBT Vector Tiles uses a centralized configuration file (`config/rbt.conf`) as the single source of truth. Environment variables override values in the file at process start; legacy `PG_*` names are still accepted.

## Resolution order (highest priority first)

1. Environment variables exported at the shell (or passed via `docker-compose`).
2. Values in [`config/rbt.conf`](https://github.com/MJJ203/rbt-data-generator/blob/main/config/rbt.conf).
3. Built-in defaults — the `Settings` dataclass fields in `src/rbt/config.py`.

Since the importer port, the CLI is the only consumer of `rbt.conf`: every variable below is resolved by `load_settings()` in [`src/rbt/config.py`](https://github.com/MJJ203/rbt-data-generator/blob/main/src/rbt/config.py) (or is unused).

## Variable ownership

Every table below has an **Owner** column:

| Owner | Meaning |
|---|---|
| **Python** | Read by `load_settings()` in [`src/rbt/config.py`](https://github.com/MJJ203/rbt-data-generator/blob/main/src/rbt/config.py) and consumed by the CLI. Keys marked *(previously bash-only)* were read only by the retired bash importers before the native port. |
| **Unused** | Declared in `rbt.conf` but not read by anything in this repository today — likely a holdover from a retired script. Kept for backward compatibility with external tooling; safe to ignore. |

### General processing

| Variable | Owner | Default | Purpose |
|---|---|---|---|
| `MAX_PARALLEL_JOBS` | Python | `4` | Worker count for the importers' parallel ingest pools (`rbt.importers._support.run_jobs`); also reported by `rbt validate`. |
| `RETRY_COUNT` | Python | `3` | Retry attempts per external command (`rbt.process.run_with_retry`) and per importer job. |
| `RETRY_DELAY` | Python | `30` | Seconds between retry attempts. |
| `LOG_LEVEL` | Python | `INFO` | `DEBUG`, `INFO`, `WARN`, `ERROR`. |
| `DEBUG` | Python | `false` | Canonical name resolved first by `Settings.debug`; `SCRIPT_DEBUG` (below) is the fallback alias. |
| `VERBOSE` | Python | `false` | Canonical name resolved first by `Settings.verbose`; `SCRIPT_VERBOSE` (below) is the fallback alias. |
| `CLEAN_TEMP_FILES` | Python | `false` (code) / `true` (rbt.conf) | Loaded into `Settings.clean_temp_files`. Reserved for importer temp-file cleanup — the native importers currently keep downloaded artifacts on disk so re-runs can resume. (Previously shadowed by the retired `SCRIPT_CLEAN_TEMP_FILES`.) |
| `PARALLEL_INGESTION` | Unused | `false` | Superseded by the `rbt import reference --parallel` flag; no longer read from the environment. |
| `VALIDATE_DOWNLOADS` | Python | `true` | Fallback alias for `OSM_VALIDATE_DOWNLOADS` (see OSM import section). |

### Tile generation

| Variable | Owner | Default | Purpose |
|---|---|---|---|
| `TILE_CACHE_DIR` | Python | `./output/tiles` | Where MBTiles/PBF tiles are written. Read by the tile engine. |
| `TILE_TEMP_DIR` | Python | `/tmp/tiles` | Scratch space for `tippecanoe -t`. Keep on fast storage. |
| `TILE_MAX_ZOOM` | Python | `13` | Maximum zoom level. |
| `TILE_MIN_ZOOM` | Python | `0` | Minimum zoom level. |
| `SUPPORTED_PROJECTIONS` | Unused | `"3857 3395 4326"` | The CLI derives supported projections from `config/layers.yml` instead. |
| `DEFAULT_PROJECTION` | Unused | `3857` | Loaded into `Settings.default_projection` but not read by `rbt tiles` or `rbt tiles layer` — Typer supplies its own defaults (`--projection all` and `--projection 3857` respectively) regardless of this value. Kept for backwards compatibility with existing rbt.conf files. |
| `LAYER_TYPES` | Unused | `"physical cultural"` | The CLI hardcodes the same two types. |

### Database connection

| Variable | Owner | Legacy | Default | Purpose |
|---|---|---|---|---|
| `DATABASE_HOST` | Python | `PG_HOST` | `localhost` | PostgreSQL host. |
| `DATABASE_PORT` | Python | `PG_PORT` | `5432` | PostgreSQL port. |
| `DATABASE_NAME` | Python | `PG_DATABASE` | `rbt` | Database name. |
| `DATABASE_USER` | Python | `PG_USR` | `postgres` | Database user. |
| `DATABASE_PASSWORD` | Python | `PG_PASS` | *(unset)* | Database password. |

Python bundles these into a `PG*`/`PG_*`/`DATABASE_*` environment for every child process it spawns (`Settings.subprocess_env()`), so psql, ogr2ogr, and imposm all see the same resolved connection. Passwords travel via `PGPASSWORD` (never argv) for libpq consumers; imposm's `postgis://` URL embeds them, and `rbt.process` redacts URL userinfo before logging.

### Database performance tuning

| Variable | Owner | Default | Purpose |
|---|---|---|---|
| `DATABASE_WORK_MEM` | Unused | `32GB` | Session `work_mem` (ok to lower for small boxes). Ops/docs reference only — not read by any code. |
| `DATABASE_MAINTENANCE_WORK_MEM` | Unused | `64GB` | `maintenance_work_mem` during index builds. Ops/docs reference only. |
| `DATABASE_MAX_PARALLEL_WORKERS` | Unused | `8` | Matches `max_parallel_workers_per_gather`. Ops/docs reference only. |
| `DATABASE_EFFECTIVE_CACHE_SIZE` | Unused | `192GB` | Planner hint; set to ~75% of system RAM. Ops/docs reference only. |
| `DATABASE_MAX_CONNECTIONS` | Unused | `100` | Used by docs/ops only; set on the server. |
| `DATABASE_CONNECTION_TIMEOUT` | Unused | `300` | Ops/docs reference only — connection timeouts are fixed in code (psycopg `connect_timeout`). |
| `DATABASE_EXTENSIONS` | Python | `"postgis postgis_raster hstore pg_trgm"` | Created during `rbt setup`; checked by `rbt validate`. |
| `DATABASE_SCHEMAS` | Python | `"fieldmap mirta naturalearth ourairports rbt geonames overture"` | Expected schemas after setup; checked by `rbt validate`. |

### OSM import

All of these are now read by `Settings`; the ones marked *(previously bash-only)* were consumed only by the retired `import-osm-data` bash script before the native port.

| Variable | Owner | Default | Purpose |
|---|---|---|---|
| `OSM_DATA_DIR` | Python *(previously bash-only)* | `/mnt/data` | Planet PBF + diffs landing zone. |
| `OSM_CONFIG_FILE` | Python | `./setup/data-sources/osm/imposm-config.json` | imposm3 config; used by the import stages and the `rbt osm run` supervisor. |
| `OSM_MAPPING_FILE` | Python *(previously bash-only)* | `./setup/data-sources/osm/imposm-mapping.yaml` | imposm3 mapping. |
| `OSM_CACHE_DIR` | Python *(previously bash-only)* | `/mnt/cache` | imposm3 cache directory. |
| `OSM_DIFF_DIR` | Python *(previously bash-only)* | `/mnt/diff` | imposm3 diff state directory. |
| `OSM_CONNECTION` | Python *(previously bash-only)* | derived from `DATABASE_*` | Override for imposm3's `postgis://` connection URL. When unset, `Settings.imposm_connection()` derives it from the resolved `DATABASE_*` values, so imposm targets the same database as the rest of the CLI. |
| `OSM_SRID` | Python *(previously bash-only)* | `4326` | SRID of imposm3-imported tables. 4326 on purpose — the `rbt.*` schema SQL casts imposm geometry to `::geometry(..., 4326)`. |
| `ARIA2C_MAX_DOWNLOADS` | Python *(previously bash-only)* | `12` | Concurrent aria2c downloads. |
| `ARIA2C_MAX_CONNECTIONS` | Python *(previously bash-only)* | `16` | Connections per aria2c download. |
| `ARIA2C_SPLITS` | Python *(previously bash-only)* | `9` | aria2c `--split`. |
| `WGET_PARALLEL_JOBS` | Python *(previously bash-only)* | `8` | Worker count for the generic single-URL download pool (OSM replication diffs, GeoNames zips). The name is kept for compatibility with the retired wget-based importer; downloads now use the Python stdlib. |
| `DIFF_START_SEQ` | Python *(previously bash-only)* | `713` | Default diff start sequence; `rbt import osm --start-seq` overrides per run. |
| `DIFF_END_SEQ` | Python *(previously bash-only)* | `730` | Default diff end sequence; `rbt import osm --end-seq` overrides per run. |
| `OSM_CLEANUP_ON_EXIT` | Python *(previously bash-only)* | `true` | Remove the merged/updated intermediates (`osm.osc.gz`, `planet.osm.pbf`) after a **successful** `--stage all` run. Single-stage runs never delete their outputs. `CLEANUP_ON_EXIT` is accepted as a fallback alias. |
| `OSM_VALIDATE_DOWNLOADS` | Python *(previously bash-only)* | `true` | Size-check downloaded/produced files. `VALIDATE_DOWNLOADS` is accepted as a fallback alias. |
| `OSM_MIN_PBF_SIZE_MB` | Python *(previously bash-only)* | `50000` | Minimum acceptable PBF size in MB for the sanity check. Planet-sized floor by default so a truncated planet download is caught; lower it (e.g. `10`) when importing a small regional extract. |
| `OSM_LOG_FILE` | Unused | `${SHARED_LOG_DIR}/osm_import.log` | The native importer writes per-stage logs (`osm_<stage>_<timestamp>.log`) under `SHARED_LOG_DIR` instead of a single file. |
| `OSM_HEALTH_CHECK_PORT` | Unused | `8080` | Nothing reads it since the bash importer's no-op health-check hook was retired. `rbt health` (the Docker `HEALTHCHECK`) takes no port argument. |

### Overture buildings import

| Variable | Owner | Default | Purpose |
|---|---|---|---|
| `OVERTURE_RELEASE` | Python *(new)* | `2026-06-17.0` | Overture Maps release used by both `rbt import buildings` (PostGIS) and `rbt export buildings` (DuckDB), so a single value pins both paths (override per run with `--release`). Overture retains only a rolling window of releases on the public bucket. |
| `OVERTURE_S3_BUCKET` | Python *(new)* | `s3://overturemaps-us-west-2/` | Public Overture S3 bucket (synced with `aws s3 sync --no-sign-request`). |
| `OVERTURE_EXPORT_DIR` | Python *(new)* | `./output/buildings` | Output directory for the `rbt export buildings` FlatGeobuf files (override per run with `--output-dir`). |
| `DUCKDB_MEMORY_LIMIT` | Python *(new)* | `200GB` | DuckDB memory ceiling for `rbt export buildings`; lower it (e.g. `16GB`) on smaller machines. |
| `DUCKDB_MAX_TEMP_SIZE` | Python *(new)* | `2900GB` | DuckDB max temp-directory size for `rbt export buildings`. |
| `DUCKDB_TEMP_DIRECTORY` | Python *(new)* | `$OVERTURE_EXPORT_DIR` | DuckDB spill directory for `rbt export buildings`. |

### Shared settings

| Variable | Owner | Default | Purpose |
|---|---|---|---|
| `SHARED_LOG_DIR` | Python | `./output/logs` | Per-invocation CLI logs, per-job importer logs, and schema logs. |
| `SHARED_TEMP_DIR` | Python | `./output/temp` | Importer scratch space (downloads, extracted archives) + `imposm-run.pid`. |
| `SCRIPT_DEBUG` | Python | `false` | Accepted as a fallback alias for `DEBUG` (`Settings.debug`). |
| `SCRIPT_VERBOSE` | Python | `false` | Accepted as a fallback alias for `VERBOSE` (`Settings.verbose`). |

### Retired `SCRIPT_*` aliases

The bash importers read a parallel family of `SCRIPT_*`-prefixed variables. Those importers are gone, and with them the aliases — the unprefixed names are now the only spellings. If you carry an old `rbt.conf` or `.env`, migrate as follows:

| Retired alias | Replacement |
|---|---|
| `SCRIPT_MAX_PARALLEL_JOBS` | `MAX_PARALLEL_JOBS` |
| `SCRIPT_RETRY_COUNT` | `RETRY_COUNT` |
| `SCRIPT_RETRY_DELAY` | `RETRY_DELAY` |
| `SCRIPT_CLEAN_TEMP_FILES` | `CLEAN_TEMP_FILES` |
| `SCRIPT_CONNECTION_TIMEOUT` | *(none — connection timeouts are fixed in code)* |
| `SCRIPT_PARALLEL_INGESTION` | *(none — use the `rbt import reference --parallel` flag)* |

`SCRIPT_DEBUG` and `SCRIPT_VERBOSE` are the exception: they remain accepted as fallback aliases of `DEBUG`/`VERBOSE`.

### Resource limits

| Variable | Owner | Default | Purpose |
|---|---|---|---|
| `DISK_SPACE_REQUIRED_GB` | Python | `100` | `rbt validate` pre-flight check minimum. |
| `MEMORY_REQUIRED_GB` | Python | `16` | `rbt validate` pre-flight check minimum. |
| `HEALTH_CHECK_PORT` | Unused | `8080` | Not read anywhere; `rbt health` takes no port argument. |
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

The legacy `PG_HOST`/`PG_PORT`/`PG_USR`/`PG_PASS`/`PG_DATABASE` variables remain recognized: `load_settings()` resolves each `DATABASE_*` key from its legacy `PG_*` alias when the canonical name is unset.

## Verifying your configuration

```bash
rbt validate
```

See [troubleshooting.md](troubleshooting.md) if validation fails.
