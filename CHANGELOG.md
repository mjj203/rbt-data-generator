# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Nightly integration workflow (`.github/workflows/nightly.yml`): imports a
  committed Liechtenstein OSM extract (`tests/fixtures/liechtenstein-*.osm.pbf`,
  ODbL — see `tests/fixtures/README.md`) with imposm, runs the
  `water`/`landcover`/`highway`/`railway` schema units over empty
  reference-table stubs (`tests/fixtures/seed_reference_stubs.sql`), and
  generates + verifies tiles in all three projections, including the first CI
  coverage of tile-join + BTIS consolidation. A separate advisory
  `upstream-probe` job checks small live data sources (OurAirports, NGA GNS)
  for schema drift, and a temporary `parity-bridge` job executes the parity
  runbook's bash-vs-native output comparison on the fixture database ahead of
  the bash generators' removal.

## [0.1.0] - 2026-07-02

Initial public release: the `rbt` CLI becomes the single orchestrator over a
hybrid Python/bash pipeline, with a native EPSG:4326 backend, an expanded test
suite, a full documentation site, and open-source hygiene files.

### Added
- Native EPSG:4326 tile backend (`src/rbt/tiles/gdal_mvt.py`) driving GDAL's
  MVT driver from a new `gdal_mvt:` section in `config/layers.yml` — the 4326
  pipeline never used tippecanoe, and the Python engine previously produced
  wrong output for it.
- `rbt schema` command dispatching the eight PL/pgSQL schema files via psql
  (`ON_ERROR_STOP=1`), replacing both `process-*-schemas.sh` dispatchers.
- Native `rbt setup` (database bootstrap via psycopg + import/schema
  sequencing), `rbt osm run|status|stop` (supervised imposm with proper signal
  handling and a pidfile), and `rbt health|validate|smoke` (`src/rbt/checks.py`).
- `--force` flag on `rbt tiles` to re-export cached FlatGeoBuf files after a
  database refresh.
- Auto-generated CLI reference (`docs/cli.md` via mkdocs-click) and new
  documentation: project tour, installation, operations guide, database schema
  reference with lineage diagrams, data-source licensing, and a tile-output
  parity runbook.
- `ATTRIBUTION.md`, `CODE_OF_CONDUCT.md`, issue templates, and a PR template.
- Test suite covering process execution, config resolution, exporters, the
  tippecanoe and GDAL-MVT backends, the engine, schema/setup/OSM/check
  commands, plus a command-parity test against the deprecated bash generators
  and a CI integration job that generates real tiles against PostGIS.

### Changed
- Settings loading no longer mutates `os.environ`; child processes receive an
  explicit environment (`Settings.subprocess_env()`).
- Docker `HEALTHCHECK` now uses `rbt health` exclusively.
- The four bash tile generators and `production/generate-tiles.sh` are
  deprecated behind `rbt tiles --mode bash` pending the parity runbook.
- Internal infrastructure references (logo, hostnames, IPs) scrubbed for
  public release.
- Upgraded the pinned toolchain: PostgreSQL 17 → 18 (PostGIS 3.5 → 3.6,
  `postgis/postgis:18-3.6`), GDAL → 3.13.1, imposm3 0.11.1 → 0.14.2,
  tippecanoe 2.78.0 → 2.79.0, and Python 3.11+ → 3.13+.
- `Dockerfile.production` now installs Python and GDAL via
  [micromamba](https://mamba.readthedocs.io/)/conda-forge instead of apt
  (`gdal-bin`/`python3-gdal`/`python3`), since Ubuntu 24.04's repos only ship
  GDAL 3.8.x and Python 3.12.
- `docker-compose.yml`'s `postgres_data` volume now mounts at
  `/var/lib/postgresql` instead of `/var/lib/postgresql/data`, matching the
  PostgreSQL 18+ image's changed default data directory.

### Removed
- `setup/init-database.sh`, `production/update-osm.sh`,
  `tools/{validate-environment,health-check,smoke-test}.sh`, and both
  `process-*-schemas.sh` dispatchers — all replaced by `rbt` commands.

### Pre-release groundwork

#### Added
- Shared Bash helper `scripts/lib/config.sh` resolving `DATABASE_*` / legacy `PG_*` variables exactly once.
- Declarative layer registry at `config/layers.yml` consumed by both the Bash and Python generators.
- Python CLI package `rbt` under `src/rbt/` (typer-based) exposing `rbt tiles`, `rbt osm`, `rbt setup`, and `rbt generate` commands.
- GitHub Actions CI running `shellcheck`, `hadolint`, `sqlfluff`, and the smoke test against a PostGIS service container.
- MkDocs build workflow that publishes documentation to GitHub Pages.
- Standard project files: `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, `.dockerignore`.
- Configuration templates shipped under `config/`: `postgresql.conf`, `tile-server.json`, `prometheus.yml`.
- Documentation split: `docs/configuration.md`, `docs/troubleshooting.md`, `docs/performance.md`.

#### Changed
- Pinned PostgreSQL 17 + PostGIS 3.5 across `docker-compose.yml` and both Dockerfiles (previously 15/14/17 mix).
- Rewrote `Dockerfile.production` as multi-stage (shared tippecanoe + imposm builder stages) and removed `Dockerfile.setup` in favor of a single image with a configurable entrypoint.
- `tippecanoe` now built from `felt/tippecanoe` (maintained fork) pinned to a release tag with checksum verification.
- `imposm3` download verified via `sha256sum`.
- Collapsed `process-cultural-schemas.sh` and `process-physical-schemas.sh` into a single data-driven dispatcher.
- `add_btis_metadata` now issues one `sqlite3` transaction instead of seven.
- Health check (`tools/health-check.sh`) honors `DATABASE_HOST`/`DATABASE_PORT` and no longer hardcodes port 5432.
- `TILE_TEMP_DIR` default reconciled across `config/rbt.conf` and scripts (`/tmp/tiles`).
- Logging unified: all shell scripts now source `scripts/lib/logging.sh` instead of reimplementing ANSI color codes.

#### Removed
- Deprecated `version: '3.8'` line from `docker-compose.yml`.
- Duplicated per-script logging/config prelude blocks (~400 LOC of bash).
- `Dockerfile.setup` (merged into a single multi-stage Dockerfile).

#### Fixed
- `docker-compose.yml` no longer mounts nonexistent files — templates are shipped under `config/`.
- README and compose now agree on PostgreSQL version.

[Unreleased]: https://github.com/MJJ203/rbt-data-generator/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/MJJ203/rbt-data-generator/releases/tag/v0.1.0
