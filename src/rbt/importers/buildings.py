"""Overture Maps buildings importer (native port of import-buildings.sh).

Flow: skip if ``overture.building`` already exists → ``aws s3 sync`` the
pinned release's buildings theme (public bucket, unsigned) → ogr2ogr the
``type=building`` directory into PostGIS → optionally ``type=building_part``
(warn-don't-fail, exactly like the retired bash script) → ``ANALYZE``.
"""

from __future__ import annotations

from pathlib import Path

from .. import process
from ..config import Settings
from ..logging import get_logger
from ._support import (
    OgrDataset,
    build_ogr2ogr_cmd,
    ensure_schemas,
    execute_sql,
    job_log_file,
    table_exists,
)

log = get_logger(__name__)

SCHEMA = "overture"


def _theme_prefix(settings: Settings, release: str) -> str:
    bucket = settings.overture_s3_bucket.rstrip("/")
    return f"{bucket}/release/{release}/theme=buildings/"


def _sync_cmd(settings: Settings, release: str, dest: Path) -> list[str]:
    return [
        "aws",
        "s3",
        "sync",
        "--no-sign-request",
        _theme_prefix(settings, release),
        str(dest),
        "--only-show-errors",
        "--cli-read-timeout",
        "0",
        "--cli-connect-timeout",
        "0",
    ]


def _type_dir(root: Path, type_name: str) -> Path | None:
    """Locate the per-type data directory (hive layout or plain)."""
    for candidate in (root / f"type={type_name}", root / type_name):
        if candidate.is_dir():
            return candidate
    return None


def _dataset(table: str) -> OgrDataset:
    return OgrDataset(
        name=f"overture_{table}",
        schema=SCHEMA,
        table=table,
        source="",  # resolved to the synced local directory at run time
    )


def import_buildings(
    settings: Settings,
    *,
    skip_parts: bool = False,
    release: str | None = None,
    dry_run: bool = False,
) -> None:
    release = release or settings.overture_release
    if not dry_run and table_exists(settings, SCHEMA, "building"):
        log.info("overture.building already exists — skipping import")
        return

    ensure_schemas(settings, [SCHEMA], dry_run=dry_run)

    dest = settings.shared_temp_dir / "overture-buildings" / release
    process.run_with_retry(
        _sync_cmd(settings, release, dest),
        retries=settings.retry_count,
        delay=settings.retry_delay,
        log_file=job_log_file(settings, "buildings", "s3_sync"),
        dry_run=dry_run,
    )

    building_dir = _type_dir(dest, "building")
    if building_dir is None:
        if dry_run:
            building_dir = dest / "type=building"
        else:
            raise FileNotFoundError(
                f"no building data directory under {dest} (expected 'type=building' or 'building')"
            )
    process.run_with_retry(
        build_ogr2ogr_cmd(_dataset("building"), settings, str(building_dir)),
        retries=settings.retry_count,
        delay=settings.retry_delay,
        env=settings.libpq_env(),
        log_file=job_log_file(settings, "buildings", "ingest_building"),
        dry_run=dry_run,
    )
    execute_sql(settings, "ANALYZE overture.building", "ANALYZE overture.building", dry_run=dry_run)

    if skip_parts:
        log.info("skipping building_part ingest (--skip-parts)")
        return
    parts_dir = _type_dir(dest, "building_part")
    if parts_dir is None and not dry_run:
        log.info("no building_part data in release %s — skipping", release)
        return
    try:
        parts_source = str(parts_dir or dest / "type=building_part")
        process.run_with_retry(
            build_ogr2ogr_cmd(_dataset("buildingpart"), settings, parts_source),
            retries=settings.retry_count,
            delay=settings.retry_delay,
            env=settings.libpq_env(),
            log_file=job_log_file(settings, "buildings", "ingest_buildingpart"),
            dry_run=dry_run,
        )
        execute_sql(
            settings,
            "ANALYZE overture.buildingpart",
            "ANALYZE overture.buildingpart",
            dry_run=dry_run,
        )
    except process.CommandFailed as exc:
        # Parity with the bash importer: building parts are optional.
        log.warning("building_part ingest failed (non-fatal): %s", exc)


__all__ = ["import_buildings"]
