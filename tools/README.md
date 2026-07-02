# tools/

Ad-hoc utilities that run outside the main setup/production pipelines.

| Script | Purpose |
|---|---|
| [overture_building_processing.sh](overture_building_processing.sh) | Processes Overture building data with DuckDB and exports area-filtered building tables to FlatGeoBuf in multiple projections and zoom levels. |
| [duckdb-building-export.sql](duckdb-building-export.sql) | The DuckDB SQL driven by the script above — an alternative Overture building export path that avoids ogr2ogr for the first pass. |

## Where did the check scripts go?

The former `validate-environment.sh`, `health-check.sh`, and `smoke-test.sh`
were replaced by native Python commands in the `rbt` CLI
(`src/rbt/checks.py`):

| Old script | Replacement |
|---|---|
| `validate-environment.sh` | `rbt validate` — pre-flight check of config, CLI tools, DB connectivity, disk, memory, and project layout. |
| `smoke-test.sh` | `rbt smoke` — end-to-end sanity check: validate → bootstrap → schema run → tile dry-runs → DB round-trip. |
| `health-check.sh` | `rbt health` — fast liveness probe; the `HEALTHCHECK` in `Dockerfile.production` runs `rbt health`. |

```bash
rbt validate
rbt smoke
rbt health

# Inside a running container
docker compose exec rbt-tiles rbt health
```

## Running the Overture utilities

```bash
# Requires duckdb on PATH; see the script header for tunables
OUTPUT_DIR=/data ./tools/overture_building_processing.sh
```

Key environment variables: `OUTPUT_DIR` (default `/data`),
`DUCKDB_MEMORY_LIMIT` (default `200GB`), `DUCKDB_MAX_TEMP_SIZE`
(default `2900GB`), `CLEANUP_TEMP_FILES` (default `true`). See
[docs/duckdb-buildings.md](../docs/duckdb-buildings.md) for the full
workflow.
