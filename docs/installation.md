# Installation

This page covers the system prerequisites, three supported install paths, and
how to pick hardware. For a guided end-to-end run after installing, continue
with [Getting Started](getting-started.md).

## Prerequisites

| Requirement | Version | Used for |
|---|---|---|
| PostgreSQL + PostGIS | 18 + 3.6 | The spatial database all imports land in. |
| GDAL/OGR (`ogr2ogr`) | 3.13+ with MVT and FlatGeoBuf drivers | FlatGeoBuf exports (3857/3395) and the EPSG:4326 MVT backend. |
| imposm3 | 0.14.2 | OSM planet import and continuous diff updates (Linux x86-64 only). |
| tippecanoe (felt fork) | 2.79.0 | MBTiles generation for 3857/3395, plus `tile-join` and `tippecanoe-decode`. |
| Python | 3.13+ ([uv](https://docs.astral.sh/uv/) recommended) | The `rbt` CLI. |
| aria2c, wget, AWS CLI | any recent | Importer downloads (planet PBF, GeoNames, Overture from S3). |
| Optional: `7z`, `sqlite3`, osmium-tool/osmosis/osmctools, docker | — | Archive extraction, MBTiles inspection, OSM diff tooling. |

`rbt validate` checks for `psql`, `ogr2ogr`, `imposm`, `tippecanoe`,
`tile-join`, `wget`, and `aws` on PATH (and warns about the optional tools),
so run it after any install path below.

## Install paths

=== "Docker Compose (recommended)"

    The compose file provisions PostgreSQL (`postgis/postgis:18-3.6` with the
    tuned [`config/postgresql.conf`](https://github.com/MJJ203/rbt-data-generator/blob/main/config/postgresql.conf) mounted) and
    builds a single multi-stage image
    ([`Dockerfile.production`](https://github.com/MJJ203/rbt-data-generator/blob/main/Dockerfile.production): Ubuntu 24.04, PGDG
    client 18, Python 3.13 + GDAL 3.13.1 via micromamba/conda-forge, tippecanoe
    2.79.0 built from source, imposm3 0.14.2, and the `rbt` CLI). Behavior is
    selected per service via `command:`, not separate images.

    ```bash
    git clone https://github.com/MJJ203/rbt-data-generator.git
    cd rbt-data-generator

    cp env.example .env          # set PG_USR / PG_PASS / PG_DATABASE
    docker compose build

    # One-time database initialization (runs `rbt setup --all`)
    docker compose --profile setup up rbt-setup

    # Continuous OSM updates (`rbt osm run`) + tile generation container
    docker compose --profile production up -d

    # Optional: TileServer-GL in front of ./output/tiles on 127.0.0.1:8080
    docker compose --profile production --profile serve up -d

    # Fast end-to-end sanity check (runs `rbt smoke`)
    docker compose --profile smoke up rbt-smoke

    # Generate tiles on demand
    docker compose run --rm rbt-tiles rbt tiles --all
    ```

    Generated tiles and logs land in `./output/` on the host. Postgres and the
    tile server bind to `127.0.0.1` only. A `monitoring` profile adds a
    Prometheus instance using [`config/prometheus.yml`](https://github.com/MJJ203/rbt-data-generator/blob/main/config/prometheus.yml).

    !!! note "Pinning the imposm3 download"
        The image downloads the imposm3 release tarball at build time. Pass
        the release checksum to enforce verification:
        `docker build -f Dockerfile.production --build-arg IMPOSM_SHA256=<sha256> .`
        (the default `SKIP` bypasses the check for local development).

=== "Ubuntu 24.04"

    These steps mirror what `Dockerfile.production` installs. Ubuntu 24.04's
    apt repo only ships GDAL 3.8.x and Python 3.12, so both come from
    [micromamba](https://mamba.readthedocs.io/en/latest/installation/micromamba-installation.html)/conda-forge instead, to track current upstream releases.

    ```bash
    # PGDG repository for PostgreSQL 18
    sudo apt-get update && sudo apt-get install -y curl ca-certificates gnupg lsb-release
    sudo install -d /usr/share/postgresql-common/pgdg
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      | sudo gpg --dearmor -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
      | sudo tee /etc/apt/sources.list.d/pgdg.list
    sudo apt-get update

    # Client tools + importer dependencies (same set as the Docker image)
    sudo apt-get install -y postgresql-client-18 \
        sqlite3 aria2 p7zip-full awscli osmctools osmium-tool osmosis

    # If the database runs on this host too:
    sudo apt-get install -y postgresql-18 postgresql-18-postgis-3

    # Python 3.13 + GDAL 3.13.1 via micromamba/conda-forge
    curl -fsSL "https://github.com/mamba-org/micromamba-releases/releases/download/2.8.1-0/micromamba-linux-64" \
      -o /usr/local/bin/micromamba
    sudo chmod +x /usr/local/bin/micromamba
    micromamba create -y -n geo -c conda-forge python=3.13 gdal=3.13.1 pip
    export PATH="$HOME/micromamba/envs/geo/bin:$PATH"   # add to your shell profile

    # tippecanoe 2.79.0 (felt fork, built from source)
    sudo apt-get install -y build-essential libsqlite3-dev zlib1g-dev git
    git clone --depth=1 --branch 2.79.0 https://github.com/felt/tippecanoe.git
    (cd tippecanoe && make -j"$(nproc)" && sudo make install)

    # imposm3 0.14.2
    wget https://github.com/omniscale/imposm3/releases/download/v0.14.2/imposm-0.14.2-linux-x86-64.tar.gz
    tar xzf imposm-0.14.2-linux-x86-64.tar.gz
    sudo mv imposm-0.14.2-linux-x86-64/imposm /usr/local/bin/

    # The rbt CLI
    git clone https://github.com/MJJ203/rbt-data-generator.git
    cd rbt-data-generator
    curl -LsSf https://astral.sh/uv/install.sh | sh
    uv sync                      # or: pip install -e .
    uv run rbt --help
    ```

    Consider applying [`config/postgresql.conf`](https://github.com/MJJ203/rbt-data-generator/blob/main/config/postgresql.conf) to
    the local server — it ships PostGIS-friendly planner and autovacuum
    settings sized for a 32–64 GB node.

=== "macOS (Homebrew)"

    macOS works well for development, tests, and tile generation against a
    remote database — but **imposm3 publishes Linux x86-64 binaries only**, so
    anything touching OSM import/updates must run via the Docker Compose path.
    Docker Compose is the recommended setup on macOS.

    ```bash
    brew install postgresql@18 postgis gdal tippecanoe aria2 awscli p7zip
    # No imposm3 formula or macOS release exists — use Docker for `rbt setup`
    # --import-osm-data and `rbt osm run`.

    git clone https://github.com/MJJ203/rbt-data-generator.git
    cd rbt-data-generator
    brew install uv
    uv sync
    uv run rbt --help
    uv run --extra dev pytest    # the test suite needs no database
    ```

## Verify the installation

```bash
uv run rbt --version
uv run rbt validate     # tools, database connectivity, disk, memory, project structure
```

`rbt validate` exits non-zero on missing required tools or an unreachable
database; warnings (missing optional tools, schemas not yet created) are fine
before the first `rbt setup`.

## Hardware sizing

Two very different workloads share this codebase — pick your column. Numbers
are reconciled with (and explained in) [Performance & Sizing](performance.md).

| | Regional extract (try it out) | Full planet (production) |
|---|---|---|
| CPU | 4+ cores | 8+ cores minimum; published timings assume 64 |
| RAM | 16 GB | 32 GB minimum; 512 GB for the published timings |
| Disk | 100 GB SSD | 1 TB+ NVMe for PostgreSQL alone; ~2.5–4 TB total across PBF, imposm cache, database, and tile output |
| Setup duration | minutes to a few hours | 36–72 h on recommended hardware; longer on the minimum |

A country-sized OSM extract is the right way to evaluate the pipeline on a
laptop — see [Getting Started](getting-started.md) for the walkthrough. Plan a
dedicated server before attempting a planet import: the stock importer
(`rbt import osm`) downloads and validates a full planet file.
