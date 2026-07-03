# Getting Started

This tutorial takes you from a fresh clone to rendered vector tiles you can pan around in a browser — using a **small regional OSM extract** (a Geofabrik country file) instead of the full planet, so every step finishes in minutes rather than hours.

By the end you will have:

1. A PostGIS database loaded with OSM and reference data for one country
2. The `rbt.*` SQL views built on top of it
3. Physical-layer tiles in Web Mercator (EPSG:3857)
4. TileServer-GL serving them at <http://localhost:8080>

!!! note "Planet-scale setup"
    This page optimizes for a fast first run. For a full planet deployment — including hardware sizing, unattended setup, and continuous OSM replication — see [Installation](installation.md), the [Operations Guide](operations.md), and [Performance & Sizing](performance.md).

## How the pieces fit

```mermaid
graph TD
    A[OSM extract or planet PBF] -->|rbt import osm| E[(PostGIS<br/>rbt database)]
    B[FieldMaps / Natural Earth /<br/>OurAirports reference data] -->|rbt import reference| E
    C[NGA GNS GeoNames] -->|rbt import geonames| E
    D[Overture Maps buildings] -->|rbt import buildings| E
    E -->|rbt schema run| F[rbt.* SQL views]
    F -->|rbt tiles| G[MBTiles / MVT directories<br/>under output/tiles/]
    G --> H[TileServer-GL :8080]
    I[OSM replication diffs] -->|rbt osm run| E
```

The Python `rbt` CLI orchestrates everything — the pipeline is fully native Python. The four `rbt import` subcommands are implemented in `src/rbt/importers/`; database bootstrap, schema processing, tile generation, and health checks are native too. External geospatial binaries (ogr2ogr, imposm, aria2c, osmium, osmosis, aws) are invoked as subprocesses.

## Prerequisites

- **Docker and Docker Compose** — used for PostGIS and the tile server in this tutorial (and optionally for the CLI itself).
- **If you run the CLI locally**: Python 3.13+, [uv](https://docs.astral.sh/uv/), and the geospatial toolchain — `psql`, GDAL/OGR (`ogr2ogr`), `imposm`, `tippecanoe` + `tile-join`, `aria2c`, `osmium`, `osmosis`, and the `aws` CLI. [Installation](installation.md) covers installing each tool; `rbt validate` (Step 3) verifies them for you.

Hardware expectations depend heavily on the size of your extract; see [Performance & Sizing](performance.md) before attempting anything larger than a country.

## Step 1 — Clone and configure

```bash
git clone https://github.com/MJJ203/rbt-data-generator.git
cd rbt-data-generator
```

Configuration is resolved with the precedence **CLI overrides → environment variables → `config/rbt.conf` → built-in defaults**. The CLI never mutates your environment; it bundles the resolved `PG*` / `PG_*` / `DATABASE_*` variables for every child process, so the importers and `psql` all see the same connection.

For this tutorial, export the settings in your shell (or set the same keys permanently in `config/rbt.conf`):

```bash
# Database connection — matches the docker-compose defaults
export PG_HOST=localhost
export PG_PORT=5432
export PG_DATABASE=rbt
export PG_USR=rbt_user
export PG_PASS=rbt_password

# Where the OSM importer reads and writes (defaults are /mnt/data etc.)
export OSM_DATA_DIR="$PWD/output/osm/data"
export OSM_CACHE_DIR="$PWD/output/osm/cache"
export OSM_DIFF_DIR="$PWD/output/osm/diff"

# imposm3 connects with its own URL — keep it in sync with the credentials above
export OSM_CONNECTION="postgis://rbt_user:rbt_password@localhost/rbt?prefix=NONE"

mkdir -p output/osm/data output/osm/cache output/osm/diff
```

If you plan to use the Docker Compose services, also copy `env.example` to `.env` — but edit `PG_USR`/`PG_PASS` first: `env.example` ships placeholder values (`postgres` / `your_password_here`), while `docker-compose.yml` otherwise defaults both to `rbt_user`/`rbt_password` when unset. Set `.env` to match the credentials you exported above so the containers and the CLI agree. See the [Configuration Reference](configuration.md) for every available key.

## Step 2 — Start PostgreSQL

=== "Docker (recommended)"

    The `postgres` service (PostGIS 18 / 3.6) has no profile, so it starts with a plain `up`:

    ```bash
    docker compose up -d postgres
    ```

    It listens on `127.0.0.1:5432` with the `rbt` database created on first boot.

=== "Existing PostgreSQL"

    Use any PostgreSQL 18 server with PostGIS 3.6 available. Point `PG_HOST` / `PG_PORT` / `PG_USR` / `PG_PASS` at it; the user needs permission to create databases and extensions. `rbt setup --setup-database` (Step 5) creates the database and extensions for you.

## Step 3 — Install the CLI and validate

=== "Local (uv)"

    ```bash
    uv sync
    uv run rbt validate
    ```

    (`pip install -e .` works too if you prefer a plain virtualenv; then drop the `uv run` prefix.)

=== "Docker"

    Build the image once, then run one-off commands through the `rbt-setup` service:

    ```bash
    docker compose build
    docker compose --profile setup run --rm rbt-setup rbt validate
    ```

`rbt validate` checks your configuration, the required external tools (`psql`, `ogr2ogr`, `imposm`, `tippecanoe`, `tile-join`, `aria2c`, `osmium`, `osmosis`, `aws`), the database connection, disk space, memory, and the project structure.

!!! note "Warnings are expected on a fresh database"
    Before setup, `validate` warns that the `rbt` schemas don't exist yet (``Schema 'rbt' not found (run `rbt setup`)``). Errors are what matter at this stage — typically a missing tool or unreachable database.

## Step 4 — Download a regional extract

[Geofabrik](https://download.geofabrik.de/) publishes daily OSM extracts using the URL pattern `https://download.geofabrik.de/<region>/<area>-latest.osm.pbf`. For example, Switzerland:

```bash
curl -Lo "$OSM_DATA_DIR/planet.osm.pbf" \
  https://download.geofabrik.de/europe/switzerland-latest.osm.pbf
```

The importer looks for the file under that exact name — `$OSM_DATA_DIR/planet.osm.pbf` — regardless of whether it is a planet file or an extract.

!!! warning "Minimum size check"
    The import stage sanity-checks `planet.osm.pbf` against a minimum size of `OSM_MIN_PBF_SIZE_MB`, which defaults to `50000` (a planet-sized floor, meant to catch truncated planet downloads) — **any regional extract will fail this check unless you lower it first**. For a country-sized extract, set `OSM_MIN_PBF_SIZE_MB=10` (or smaller for tiny extracts like Liechtenstein, ~3 MB) in `config/rbt.conf` or the environment before importing.

## Step 5 — Create the database

=== "Local (uv)"

    ```bash
    uv run rbt setup --setup-database
    ```

=== "Docker"

    ```bash
    docker compose --profile setup run --rm rbt-setup rbt setup --setup-database
    ```

This bootstraps the database natively (no shell scripts): it creates the `rbt` database if missing and installs the `postgis`, `postgis_raster`, `hstore`, and `pg_trgm` extensions.

## Step 6 — Import data

### OSM extract

`rbt import osm` selects its pipeline stage with the typed `--stage` option. For a pre-downloaded extract you only need the import stage:

=== "Local (uv)"

    ```bash
    uv run rbt import osm --stage import
    ```

=== "Docker"

    The container keeps OSM state under the mounted `./output` directory (compose sets `OSM_DATA_DIR=/app/output/osm/data`), so place the extract at `./output/osm/data/planet.osm.pbf` on the host and run:

    ```bash
    docker compose --profile setup run --rm rbt-setup rbt import osm --stage import
    ```

This runs `imposm import` with the project's mapping (`setup/data-sources/osm/imposm-mapping.yaml`), writing OSM tables in EPSG:4326 (`OSM_SRID`) and recording diff state so replication can pick up later.

The other stages (run `rbt import osm --help` for the full list):

| `--stage` | What it does |
|---|---|
| `all` *(default)* | Download the planet, fetch and apply diffs, then import — the pipeline finishes and returns (continuous replication is `rbt osm run`) |
| `download-planet` | Download the planet PBF from a mirror list |
| `download-diffs` | Fetch daily replication diffs by sequence number (`--start-seq` / `--end-seq`) |
| `merge-diffs` / `apply-changes` | Merge diffs with osmium and apply them to the PBF with osmosis |
| `import` | Import `$OSM_DATA_DIR/planet.osm.pbf` with imposm3 |
| `import-diff` | Apply downloaded `.osc.gz` changesets as a one-time update |

### Reference data

The physical and cultural views join OSM against global reference datasets (FieldMaps administrative boundaries, Natural Earth, OurAirports, OSM water polygons and coastlines), so import them even for a regional run:

```bash
uv run rbt import reference
```

### Optional: GeoNames and Overture buildings

These are only needed for the **cultural** layer family (place labels and the building layer):

```bash
uv run rbt import geonames     # NGA GNS names (geonames.nga.mil)
uv run rbt import buildings    # Overture Maps buildings from S3 (requires the aws CLI; large download)
```

You can skip both for now and still complete this tutorial; come back to them before running cultural layers. See [DuckDB Buildings Export](duckdb-buildings.md) for an alternative buildings workflow.

## Step 7 — Build the `rbt.*` views

The tile layers read from SQL views in the `rbt` schema, defined by eight PL/pgSQL files registered in `config/layers.yml`:

```bash
uv run rbt schema list                  # see the registered units
uv run rbt schema run --type physical   # physical-core, landcover, water, contour
```

Each file runs through `psql -v ON_ERROR_STOP=1`, so a failure stops immediately with a useful error. Once GeoNames and buildings are imported, build everything:

```bash
uv run rbt schema run --all
```

## Step 8 — Generate tiles

Start with a single category to confirm the pipeline end to end:

```bash
uv run rbt tiles --layer-type physical --projection 3857 --water
```

For 3857 (and 3395), each layer is exported from PostGIS to FlatGeoBuf with `ogr2ogr`, then rendered to MBTiles with `tippecanoe`. The water layer lands at `output/tiles/physical/3857/water_3857.mbtiles`.

Then generate the full physical set — multiple layers are merged with `tile-join` into one file and stamped with BTIS metadata:

```bash
uv run rbt tiles --layer-type physical --projection 3857
# → output/tiles/physical/3857/physical_3857.mbtiles
```

Useful variations:

```bash
uv run rbt tiles --layer-type physical --projection 3857 --dry-run   # print commands without running
uv run rbt tiles layer water --projection 3857                       # one layer, one projection
uv run rbt tiles --layer-type physical --projection 3857 --force     # re-export cached FlatGeoBuf after a DB refresh
uv run rbt layers list                                               # inspect the layer registry
```

!!! note "EPSG:4326 uses a different backend"
    Geographic tiles are produced by GDAL's native MVT driver in a single multi-table `ogr2ogr` call — no tippecanoe involved — and are written as a tile *directory* plus `metadata.json` rather than an `.mbtiles` file.

In Docker, run the same commands through the tiles service:

```bash
docker compose --profile production run --rm rbt-tiles \
  rbt tiles --layer-type physical --projection 3857
```

## Step 9 — Serve and view

The `serve` profile runs TileServer-GL against `./output/tiles`:

```bash
docker compose --profile serve up -d --no-deps tile-server
```

Open <http://localhost:8080> and you should see your data sources listed, with an inspector for browsing the tiles. (`--no-deps` skips the `rbt-tiles` container, whose default command would kick off a full `rbt tiles --all` run.)

!!! note "Tile server configuration"
    `config/tile-server.json` expects both `physical/3857/physical_3857.mbtiles` and `cultural/3857/cultural_3857.mbtiles`. If you only generated the physical set, remove the `cultural-3857` entry from the `data` block (or generate the cultural set after importing GeoNames and buildings).

## Next steps

- **Verify your environment end to end** — `uv run rbt smoke` runs validate → bootstrap → schemas → tile dry-runs as one sanity check.
- **[Operations Guide](operations.md)** — continuous OSM replication with `rbt osm run` / `status` / `stop`, scheduled tile generation, and monitoring.
- **[rbt CLI Reference](cli.md)** — every command and flag.
- **[Architecture](architecture.md)** — how the orchestrator, importers, and tile engine fit together.
- **[Troubleshooting](troubleshooting.md)** — common failures and fixes.
