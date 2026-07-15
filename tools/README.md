# tools/

Ad-hoc utilities that run outside the main setup/production pipelines.

There are currently no scripts here — the former bash utilities have been
ported to the native `rbt` CLI (see below).

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

## Overture buildings DuckDB export

The former `overture_building_processing.sh` wrapper has been retired. The
DuckDB → FlatGeobuf export is now a native command:

```bash
# Requires duckdb on PATH
rbt export buildings
```

Key environment variables: `OVERTURE_EXPORT_DIR` (default `./output/buildings`),
`DUCKDB_MEMORY_LIMIT` (default `200GB`), `DUCKDB_MAX_TEMP_SIZE`
(default `2900GB`). The DuckDB SQL it drives lives at
[setup/data-sources/overture/duckdb-building-export.sql](../setup/data-sources/overture/duckdb-building-export.sql).
See [docs/duckdb-buildings.md](../docs/duckdb-buildings.md) for the full
workflow.
