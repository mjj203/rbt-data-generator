# RBT Vector Tiles

[![CI](https://github.com/MJJ203/rbt-data-generator/actions/workflows/ci.yml/badge.svg)](https://github.com/MJJ203/rbt-data-generator/actions/workflows/ci.yml)
[![Docs](https://github.com/MJJ203/rbt-data-generator/actions/workflows/docs.yml/badge.svg)](https://mjj203.github.io/rbt-data-generator/)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Python 3.13+](https://img.shields.io/badge/python-3.13%2B-blue.svg)](pyproject.toml)

An open-source system for generating multi-projection Mapbox Vector Tiles from
authoritative geospatial data sources (OpenStreetMap, Natural Earth, NGA GNS,
Overture Maps, FieldMaps, OurAirports).

**Documentation: <https://mjj203.github.io/rbt-data-generator/>**

## Highlights

- **Multi-projection**: Web Mercator (3857), World Mercator (3395), Geographic (4326)
- **Two-phase pipeline**: one-time database initialization, then continuous OSM
  updates and on-demand tile generation
- **One CLI**: every operation runs through `rbt` — setup, imports, schema
  processing, tile generation, the OSM update daemon, and health checks
- **Declarative layers**: all ~55 tile layers, their tippecanoe options,
  filters, and zoom blends live in [`config/layers.yml`](config/layers.yml)
- **Container-native**: PostGIS + imposm3 + tippecanoe + GDAL orchestrated via
  Docker Compose profiles
- **Tested and linted**: pytest, ruff, mypy, shellcheck, sqlfluff, and hadolint
  gate every change in CI

> **Status:** alpha — the CLI surface is stabilizing ahead of a 0.1.0 release.

## Quick start

```bash
git clone https://github.com/MJJ203/rbt-data-generator.git
cd rbt-data-generator

# 1. Configure
cp env.example .env        # edit database credentials
vi config/rbt.conf         # or edit the centralized config directly

# 2. Build the rbt image (GDAL + tippecanoe + imposm3 + the CLI)
docker compose build

# 3. One-time setup (downloads + imports data; several hours for a planet)
docker compose --profile setup up rbt-setup

# 4. Continuous OSM updates + tile generation
docker compose --profile production up -d

# 5. Optional tile server at http://localhost:8080
docker compose --profile production --profile serve up -d
```

Or run the CLI directly:

```bash
uv sync                    # or: pip install -e .
rbt validate               # pre-flight checks
rbt setup --all            # bootstrap + imports + schemas
rbt tiles --layer-type physical --projection 3857 --water
```

See the [Getting Started tutorial](https://mjj203.github.io/rbt-data-generator/getting-started/)
for a guided walkthrough using a small regional extract.

## Prerequisites

- PostgreSQL 18 with PostGIS 3.6
- GDAL/OGR 3.13+ with MVT and FlatGeoBuf drivers
- imposm3 0.14.2+
- tippecanoe (felt/tippecanoe fork)
- Python 3.13+
- Hardware: see [Performance & Sizing](https://mjj203.github.io/rbt-data-generator/performance/)
  — a small regional extract runs on a 16 GB laptop; a full planet needs
  server-class hardware.

## Project layout

```
rbt-data-generator/
├── config/                        # rbt.conf + layers.yml (declarative layer registry)
├── src/rbt/                       # The rbt CLI — all orchestration (Python/Typer)
│   ├── tiles/                     #   tippecanoe (3857/3395) + GDAL-MVT (4326) backends
│   ├── importers/                 #   thin wrappers over the bash leaf importers
│   ├── schema.py / setup_db.py    #   schema dispatch + database bootstrap
│   └── checks.py                  #   rbt validate / smoke / health
├── setup/data-sources/            # Bash leaf importers + imposm mapping + schema SQL
├── production/                    # DEPRECATED bash tile generators (--mode bash)
├── scripts/lib/                   # Shared bash helpers for the leaf scripts
├── tools/                         # Standalone utilities (DuckDB buildings export)
├── tests/                         # pytest suite
├── docs/                          # MkDocs documentation site
└── output/                        # Generated tiles and logs (gitignored)
```

A new engineer should start with the
[Project Tour](https://mjj203.github.io/rbt-data-generator/project-structure/).

## Data attribution

Generated tiles are derived from third-party open data. The code is GPL-3.0,
but **the data keeps its own licenses** — notably OpenStreetMap and Overture
buildings are ODbL (share-alike, attribution required: "© OpenStreetMap
contributors"). See [ATTRIBUTION.md](ATTRIBUTION.md) for every source and its
terms before distributing tiles.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports and security disclosures
follow [SECURITY.md](SECURITY.md). Release notes live in
[CHANGELOG.md](CHANGELOG.md).

## License

GPL-3.0 — see [LICENSE](LICENSE). Data licenses are documented in
[ATTRIBUTION.md](ATTRIBUTION.md).
