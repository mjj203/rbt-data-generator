# Performance & Sizing

This page is the single source of truth for hardware sizing, import duration
expectations, and the tuning knobs that matter. Where other pages quote
numbers, they should agree with the tables here.

!!! note "Most numbers on this page are estimates"
    The planet-scale durations were measured on the *recommended* tier below
    with `PARALLEL_INGESTION=true`; everything else scales with disk speed,
    network bandwidth, and how busy PostgreSQL is. Treat ranges as honest
    expectations, not guarantees.

## Hardware tiers

| Tier | CPU | RAM | Disk | Intended use |
|---|---|---|---|---|
| **Regional extract (try it out)** | 4+ cores | 16 GB | 100 GB SSD | Tutorial, development, evaluating the pipeline on a country-sized OSM extract. |
| **Planet (minimum)** | 8+ cores | 32 GB+ | 1 TB+ NVMe for PostgreSQL alone; ~2.5–4 TB total (see [disk budget](#disk-budget-full-planet)) | A full planet import you are willing to wait days for. |
| **Planet (recommended)** | 64 cores | 512 GB | 4× 4 TB NVMe | Production. The processing times below were measured on this class. |

Assumptions behind the table:

- The **regional** tier matches the CLI's pre-flight defaults
  (`DISK_SPACE_REQUIRED_GB=100`, `MEMORY_REQUIRED_GB=16` in
  [`config/rbt.conf`](https://github.com/MJJ203/rbt-data-generator/blob/main/config/rbt.conf)) — `rbt validate` warns below them.
- The shipped [`config/postgresql.conf`](https://github.com/MJJ203/rbt-data-generator/blob/main/config/postgresql.conf) targets a
  **32–64 GB / 8–16 core** single node, i.e. between the first two tiers.
  Raise `shared_buffers` / `effective_cache_size` proportionally on bigger
  machines.
- The recommended tier assumes a **dedicated** PostgreSQL server: the OSM
  import, schema processing, and tile export all compete for the same disk
  and memory when co-located.

## Import duration expectations

### Full planet (one-time initialization)

Measured on the recommended tier with `PARALLEL_INGESTION=true`:

| Step | Duration |
|---|---|
| OSM import (download + diffs + imposm3) | 24 – 48 h |
| Reference data (FieldMaps / Natural Earth / OurAirports / MIRTA) | 2 – 4 h |
| GeoNames (NGA GNS) | 1 – 2 h |
| Overture buildings (S3 + ogr2ogr) | 4 – 6 h |
| Schema processing (`rbt schema run --all`) | 6 – 12 min |
| **Total** | **36 – 72 h** |

On the *minimum* planet tier expect the OSM step alone to stretch to
**several days** — the import is dominated by disk throughput (imposm3 cache
writes, then index builds), and a single SATA SSD roughly doubles to triples
the wall time compared to NVMe. Download time for the planet PBF adds 1–3 h
on a fast connection.

### Regional extract

A country-sized extract imports in **minutes to a few hours** end to end,
including reference data and schema processing. Schema processing time is
mostly independent of extract size at the small end (the reference datasets
are global either way).

### Tile generation

| Scope | Duration (recommended tier) |
|---|---|
| All layers, all projections | 6 – 12 h |
| Single projection | 2 – 4 h |
| Specific layers only | 30 min – 2 h |
| OSM continuous updates (`rbt osm run`) | applies diffs continuously |

Re-runs are cheaper than first runs: the 3857/3395 backend reuses cached
FlatGeoBuf exports unless `--force` is passed (pass it after any database
refresh, or you will rebuild tiles from stale exports).

## Disk budget (full planet)

All figures are estimates; sizes grow slowly over time as the source datasets
grow.

| Component | Location (config) | Size |
|---|---|---|
| OSM planet PBF | `OSM_DATA_DIR` (default `/mnt/data`) | ~80 GB and growing |
| imposm3 cache | `OSM_CACHE_DIR` (default `/mnt/cache`) | ~100 – 200 GB |
| OSM diffs | `OSM_DIFF_DIR` (default `/mnt/diff`) | small; grows with the update window |
| PostgreSQL cluster | server data directory | ~1 – 2 TB after all imports, indexes, and materialized views |
| FlatGeoBuf exports + MBTiles + 4326 tile dirs | `TILE_CACHE_DIR` (default `./output/tiles`) | ~200 – 500 GB |
| tippecanoe scratch | `TILE_TEMP_DIR` (default `/tmp/tiles`) | tens of GB, transient |
| **Total** | | **~2.5 – 4 TB** |

The intermediate FlatGeoBuf files are kept deliberately (resume semantics);
delete them or the per-layer `.mbtiles` after a successful `tile-join` if
space is tight.

## PostgreSQL tuning

[`config/postgresql.conf`](https://github.com/MJJ203/rbt-data-generator/blob/main/config/postgresql.conf) is mounted into the
compose `postgres` service and is the starting point for bare-metal installs
too. The knobs that matter most:

| Setting | Shipped value | Guidance |
|---|---|---|
| `shared_buffers` | 4 GB | ~25 % of RAM on a dedicated server. |
| `work_mem` | 64 MB | Per-sort/hash budget. The schema SQL raises it per-transaction (`SET LOCAL work_mem`) for the heavy materialized-view builds, so the global value can stay modest. |
| `maintenance_work_mem` | 512 MB | Used by `CREATE INDEX`; raise into the tens of GB on the recommended tier to speed post-import index builds. |
| `effective_cache_size` | 12 GB | Planner hint; set to ~75 % of RAM. |
| `max_parallel_workers` / `..._per_gather` | 8 / 4 | Scale with core count. |
| `random_page_cost` / `effective_io_concurrency` | 1.1 / 200 | Already SSD-friendly; leave as-is on NVMe. |
| `autovacuum_naptime` | 15 s | Deliberately aggressive — the imposm `import.*` tables churn heavily during continuous OSM updates. |

The related `DATABASE_WORK_MEM` / `DATABASE_MAINTENANCE_WORK_MEM` /
`DATABASE_EFFECTIVE_CACHE_SIZE` values in `config/rbt.conf` default to
recommended-tier sizes (32 GB / 64 GB / 192 GB) — they describe the *server*
you point the pipeline at and are safe to lower for small boxes; see the
[Configuration Reference](configuration.md).

## Tippecanoe parallelism and scratch placement

The native engine always invokes tippecanoe with `-P` (parallel reading of
the FlatGeoBuf input) and `-t $TILE_TEMP_DIR`. Tippecanoe is extremely
I/O-bound while materializing zoom levels, so:

- Point `TILE_TEMP_DIR` (default `/tmp/tiles`) at NVMe, or at `/dev/shm` if
  you have RAM to spare.
- Keep `TILE_TEMP_DIR` and `TILE_CACHE_DIR` on different devices than the
  PostgreSQL data directory when generating tiles on the database host.

The EPSG:4326 backend (GDAL MVT driver) does not use tippecanoe; its
bottleneck is the database read and the single `ogr2ogr` process writing the
tile directory.

## Parallelism knobs

| Variable | Default | Effect |
|---|---|---|
| `MAX_PARALLEL_JOBS` | 4 | General parallelism setting surfaced through `Settings` (reported by `rbt validate`). Conservative by default; raise toward core count minus 2 on a dedicated host. |
| `SCRIPT_MAX_PARALLEL_JOBS` | 4 | Job-pool size inside the bash importers (parallel downloads/ingests in `import-reference-data.sh` and `import-geonames.sh`). |
| `SCRIPT_PARALLEL_INGESTION` | `false` | Full fan-out ingestion in the reference importer: roughly halves wall time, roughly doubles peak memory and DB connection pressure. |
| `ARIA2C_MAX_DOWNLOADS` / `ARIA2C_MAX_CONNECTIONS` / `ARIA2C_SPLITS` | 12 / 16 / 9 | Planet download parallelism — usually network-limited, rarely worth raising. |

## Built-in performance features

- **Materialized views** for the expensive spatial aggregations behind the
  `rbt.*` layer views.
- **Transaction-scoped tuning** (`SET LOCAL work_mem`,
  `min_parallel_index_scan_size`) inside the schema SQL, so heavy builds get
  big budgets without permanent server changes.
- **Spatial GiST + GIN trigram indexes** created (and clustered) at schema
  processing time.
- **Resume semantics** — cached FlatGeoBuf exports are reused unless
  `--force` is passed, so interrupted tile runs restart cheaply.
