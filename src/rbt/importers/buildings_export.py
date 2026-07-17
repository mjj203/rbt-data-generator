"""Overture buildings DuckDB → FlatGeobuf export (native port of
``tools/overture_building_processing.sh``).

Unlike :mod:`rbt.importers.buildings` (which ingests Overture buildings into
PostGIS), this path reads Overture GeoParquet directly from S3 with DuckDB and
writes six standalone ``building_*.fgb`` files — three full-extent projections
plus three area-filtered, zoom-oriented EPSG:4326 variants. Pick one path per
pipeline; they are not meant to be combined.

Flow: resolve the output dir/release → build the ``duckdb`` command
(``duckdb <db> -f <sql>``, the no-shell equivalent of the retired bash
``duckdb "$DB" < "$SQL"``) → remove any prior outputs → run → validate that all
six outputs exist and are non-empty → drop the scratch DuckDB database (unless
``--keep-db``, or the run failed, in which case it is left for debugging). The
export always regenerates; there is no "skip if present" short-circuit.
"""

from __future__ import annotations

import shutil
from pathlib import Path

from .. import process
from ..config import Settings
from ..logging import get_logger
from ._support import job_log_file

log = get_logger(__name__)

# The exact set the SQL's COPY statements write; also what we validate afterward.
OUTPUT_FILES = (
    "building_3395.fgb",
    "building_3857.fgb",
    "building_4326.fgb",
    "building_z10_4326.fgb",
    "building_z11_4326.fgb",
    "building_z12_4326.fgb",
)


def export_buildings(
    settings: Settings,
    *,
    output_dir: Path | None = None,
    temp_dir: Path | None = None,
    release: str | None = None,
    keep_db: bool = False,
    dry_run: bool = False,
) -> None:
    release = release or settings.overture_release
    out = Path(output_dir) if output_dir is not None else settings.overture_export_dir
    # DuckDB's spill directory follows --output-dir by default (matching the
    # retired bash script, which defaulted DUCKDB_TEMP_DIRECTORY to the
    # effective OUTPUT_DIR) — both can reach hundreds of GB, and defaulting to
    # settings.duckdb_temp_dir here would silently spill onto the wrong disk
    # whenever --output-dir points somewhere else. --temp-dir splits them
    # explicitly when that's actually wanted.
    if temp_dir is not None:
        temp_dir = Path(temp_dir)
    elif output_dir is not None:
        temp_dir = out
    else:
        temp_dir = settings.duckdb_temp_dir
    db_path = out / "overture_buildings.db"
    sql_path = settings.overture_export_sql

    # DuckDB reads these via getenv()/getvariable() in the SQL script; passing
    # OVERTURE_RELEASE/OVERTURE_S3_BUCKET keeps the export pinned to the same
    # release as the PostGIS importer.
    env = {
        "OUTPUT_DIR": str(out),
        "OVERTURE_RELEASE": release,
        "OVERTURE_S3_BUCKET": settings.overture_s3_bucket,
        "DUCKDB_MEMORY_LIMIT": settings.duckdb_memory_limit,
        "DUCKDB_MAX_TEMP_SIZE": settings.duckdb_max_temp_size,
        "DUCKDB_TEMP_DIRECTORY": str(temp_dir),
    }
    cmd = ["duckdb", str(db_path), "-f", str(sql_path)]
    log_file = job_log_file(settings, "buildings_export", "duckdb")

    log.info("exporting Overture buildings (release %s) to %s", release, out)

    # retries=1 on purpose: this is a multi-hour DuckDB job that re-reads the
    # whole release from S3; retrying it on failure wastes hours rather than
    # recovering from a transient blip.
    if dry_run:
        process.run_with_retry(
            cmd, retries=1, delay=settings.retry_delay, env=env, log_file=log_file, dry_run=True
        )
        return

    # Verify the tool and script are actually usable *before* touching any
    # existing artifacts — a container missing the duckdb CLI (or a bad
    # OVERTURE_EXPORT_SQL override) must not delete a prior successful run's
    # outputs on its way to failing.
    if shutil.which("duckdb") is None:
        raise FileNotFoundError(
            "duckdb CLI not found on PATH — install DuckDB "
            "(see docs/duckdb-buildings.md) before running this export"
        )
    if not sql_path.is_file():
        raise FileNotFoundError(f"DuckDB export SQL script not found: {sql_path}")

    out.mkdir(parents=True, exist_ok=True)
    temp_dir.mkdir(parents=True, exist_ok=True)
    for name in OUTPUT_FILES:
        (out / name).unlink(missing_ok=True)
    db_path.unlink(missing_ok=True)

    process.run_with_retry(cmd, retries=1, delay=settings.retry_delay, env=env, log_file=log_file)

    missing = [n for n in OUTPUT_FILES if not (out / n).is_file() or (out / n).stat().st_size == 0]
    if missing:
        # Leave db_path in place (no cleanup) so the failed run can be inspected,
        # matching the retired bash script's "exit before cleanup on failure".
        raise RuntimeError(
            f"DuckDB export produced {len(OUTPUT_FILES) - len(missing)}/{len(OUTPUT_FILES)} "
            f"expected files; missing or empty: {', '.join(missing)}"
        )

    log.info("all %d building exports written to %s", len(OUTPUT_FILES), out)
    if keep_db:
        log.info("keeping scratch DuckDB database: %s", db_path)
    else:
        db_path.unlink(missing_ok=True)


__all__ = ["export_buildings"]
