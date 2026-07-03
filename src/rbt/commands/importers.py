"""``rbt import`` — run individual data importers (native Python)."""

from __future__ import annotations

import typer

from ..importers import buildings as buildings_importer
from ..importers import geonames as geonames_importer
from ..importers import osm as osm_importer
from ..importers import reference as reference_importer
from ..importers.osm import OsmStage
from ._common import settings_from_ctx

importers_app = typer.Typer(help="Run individual data importers (OSM, GeoNames, Overture, etc.).")


@importers_app.command("osm")
def import_osm_cmd(
    ctx: typer.Context,
    stage: OsmStage = typer.Option(
        OsmStage.all,
        "--stage",
        help="Pipeline stage to run (default: the full download → import workflow).",
    ),
    start_seq: int | None = typer.Option(
        None, "--start-seq", help="First replication diff sequence (download-diffs)."
    ),
    end_seq: int | None = typer.Option(
        None, "--end-seq", help="Last replication diff sequence (download-diffs)."
    ),
    dry_run: bool = typer.Option(False, "--dry-run"),
) -> None:
    """One-time OSM data import (planet download, diffs, imposm import)."""
    osm_importer.run_import(
        settings_from_ctx(ctx), stage, start_seq=start_seq, end_seq=end_seq, dry_run=dry_run
    )


@importers_app.command("reference")
def import_reference_cmd(
    ctx: typer.Context,
    only: list[str] = typer.Option(
        None, "--only", help="Import only the named dataset(s) (repeatable; see --list)."
    ),
    parallel: bool = typer.Option(
        False,
        "--parallel",
        help="Run every dataset in one pool instead of the fieldmaps-first phases.",
    ),
    list_: bool = typer.Option(False, "--list", help="List dataset names and exit."),
    dry_run: bool = typer.Option(False, "--dry-run"),
) -> None:
    """Import reference datasets (FieldMaps, Natural Earth, OurAirports, OSM water, MIRTA)."""
    if list_:
        for name in reference_importer.dataset_names():
            typer.echo(name)
        return
    reference_importer.import_reference(
        settings_from_ctx(ctx), only=list(only or []) or None, parallel=parallel, dry_run=dry_run
    )


@importers_app.command("geonames")
def import_geonames_cmd(
    ctx: typer.Context,
    only: list[str] = typer.Option(
        None, "--only", help="Import only the named dataset(s) (repeatable; see --list)."
    ),
    list_: bool = typer.Option(False, "--list", help="List dataset names and exit."),
    dry_run: bool = typer.Option(False, "--dry-run"),
) -> None:
    """Import NGA GNS + USGS GNIS geographic names."""
    if list_:
        for name in geonames_importer.dataset_names():
            typer.echo(name)
        return
    geonames_importer.import_geonames(
        settings_from_ctx(ctx), only=list(only or []) or None, dry_run=dry_run
    )


@importers_app.command("buildings")
def import_buildings_cmd(
    ctx: typer.Context,
    skip_parts: bool = typer.Option(
        False, "--skip-parts", help="Skip the optional building_part ingest."
    ),
    release: str | None = typer.Option(
        None, "--release", help="Overture release to sync (default: pinned in Settings)."
    ),
    dry_run: bool = typer.Option(False, "--dry-run"),
) -> None:
    """Import Overture Maps buildings from S3."""
    buildings_importer.import_buildings(
        settings_from_ctx(ctx), skip_parts=skip_parts, release=release, dry_run=dry_run
    )


__all__ = ["importers_app"]
