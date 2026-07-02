"""ogr2ogr export helpers."""

from __future__ import annotations

from pathlib import Path

from ..config import Settings
from ..layers import Layer, Projection
from ..logging import get_logger
from ..process import CommandFailed, run_with_retry

log = get_logger(__name__)


def export_layer_to_fgb(
    layer: Layer,
    projection: Projection,
    settings: Settings,
    output_dir: Path,
    *,
    force: bool = False,
    dry_run: bool = False,
    log_file: Path | None = None,
) -> Path:
    """Export a Postgres table/view to FlatGeoBuf in the target projection.

    An existing ``.fgb`` is reused unless *force* is set — note that a stale
    export silently produces stale tiles after a schema refresh, so the skip
    is logged as a warning.
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    fgb = output_dir / f"{layer.output_basename(projection.code)}.fgb"

    if fgb.is_file():
        if force:
            if dry_run:
                log.info(
                    "[dry-run] --force: would re-export %s (cached %s kept)", layer.key, fgb.name
                )
                return fgb
            log.info("--force: re-exporting %s (removing cached %s)", layer.key, fgb.name)
            fgb.unlink()
        else:
            log.warning(
                "REUSING cached export %s — pass --force to re-export after a "
                "database/schema refresh",
                fgb.name,
            )
            return fgb

    # Export to a temp path and atomically rename on success, so a failed or
    # interrupted retry can never leave a partial .fgb that a later run (without
    # --force) would silently reuse as a cache hit. The temp name keeps the .fgb
    # suffix so ogr2ogr still auto-selects the FlatGeoBuf driver.
    tmp = fgb.with_name(f"{fgb.stem}.partial{fgb.suffix}")
    if not dry_run and tmp.exists():
        tmp.unlink()

    cmd = ["ogr2ogr"]
    if not layer.ogr.spatial_index:
        cmd += ["-lco", "SPATIAL_INDEX=NO"]
    cmd += ["-t_srs", projection.epsg, str(tmp), settings.ogr_pg_connection(), layer.source_table]
    if layer.ogr.skipfailures:
        cmd.append("-skipfailures")

    try:
        run_with_retry(
            cmd,
            retries=settings.retry_count,
            delay=settings.retry_delay,
            env=settings.libpq_env(),
            log_file=log_file,
            dry_run=dry_run,
        )
    except CommandFailed:
        if tmp.exists():
            tmp.unlink()
        raise

    if not dry_run and tmp.exists():
        tmp.replace(fgb)
    return fgb
