# RBT Vector Tiles

RBT Vector Tiles is an open-source pipeline that turns authoritative geospatial sources — OpenStreetMap, Natural Earth, FieldMaps, NGA GeoNames, OurAirports, and Overture Maps buildings — into multi-projection Mapbox Vector Tiles. Data is imported into PostGIS, shaped into a curated set of `rbt.*` SQL views, and rendered to MBTiles (EPSG:3857 and 3395 via tippecanoe) or MVT tile directories (EPSG:4326 via GDAL's MVT driver), ready to serve with TileServer-GL. A single Python CLI, `rbt`, orchestrates the whole pipeline.

[Start the tutorial](getting-started.md){ .md-button .md-button--primary }
[Read the architecture](architecture.md){ .md-button }

## Choose your path

<div class="grid cards" markdown>

- **New engineer**

    ---

    Get oriented in the repository, then see how the orchestrator, importers, and tile engine fit together.

    [Project Tour](project-structure.md) · [Architecture](architecture.md)

- **Operator**

    ---

    Install the toolchain, deploy with Docker Compose, and keep the pipeline healthy in production.

    [Installation](installation.md) · [Operations Guide](operations.md)

- **Data engineer**

    ---

    The schemas behind the tiles, the layer definitions, and where every dataset comes from.

    [Database Schema](database-schema.md) · [Data Sources & Licensing](data-sources.md) · [Physical Layers](physical-layers.md) · [Cultural Layers](cultural-layers.md)

- **Contributor**

    ---

    Coding standards, the test workflow, and how changes land.

    [Contributing](contributing.md) · [rbt CLI Reference](cli.md)

</div>

## Highlights

- **Multi-projection output** — Web Mercator (3857) and World Mercator (3395) rendered with tippecanoe and merged with `tile-join`; geographic (4326) rendered natively by GDAL's MVT driver in a single multi-table pass.
- **Declarative layer registry** — every layer, zoom window, projection set, and tippecanoe filter lives in `config/layers.yml`; inspect it with `rbt layers list` and `rbt layers show KEY`.
- **One orchestrator** — the `rbt` CLI dispatches every step. Four data importers remain bash leaf scripts with documented contracts; nothing else shells between scripts.
- **Container-native** — PostGIS, one-shot setup, continuous OSM updates, tile serving, smoke tests, and monitoring are Docker Compose profiles (`setup`, `production`, `serve`, `smoke`, `monitoring`).
- **Built-in checks** — `rbt validate`, `rbt health`, and `rbt smoke` run natively in Python; `health` doubles as the container HEALTHCHECK.
- **Continuous OSM updates** — `rbt osm run` supervises `imposm run` replication with clean signal handling, plus `status` and `stop` commands.

## Project status

!!! warning "Pre-1.0 software"
    RBT Vector Tiles is alpha software (0.1.0 released) after a large refactor from bash orchestration to the Python `rbt` CLI. The CLI is the only entry point: the legacy bash tile generators were removed after output parity was verified (see the [parity runbook](parity-runbook.md) completion note). Expect command flags and configuration keys to change before 1.0. Bug reports and pull requests are welcome — see [Contributing](contributing.md) and [Security](security.md).

## Requirements at a glance

The pipeline shells out to PostgreSQL/PostGIS, GDAL/OGR, imposm3, and tippecanoe; `rbt validate` checks for all of them. Tool installation is covered in [Installation](installation.md), and hardware sizing — from a laptop for a country extract to server-class hardware for the planet — in [Performance & Sizing](performance.md).

## License and attribution

The code is GPL-3.0, but generated tiles are derived from third-party open data that keeps its own licenses — notably OpenStreetMap and Overture buildings under ODbL (share-alike, attribution required). See [Data Sources & Licensing](data-sources.md) before distributing tiles.
