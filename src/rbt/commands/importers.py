"""``rbt import`` — run individual data importers."""

from __future__ import annotations

import typer

from ..importers import buildings as buildings_importer
from ..importers import geonames as geonames_importer
from ..importers import osm as osm_importer
from ..importers import reference as reference_importer
from ._common import settings_from_ctx

importers_app = typer.Typer(help="Run individual data importers (OSM, GeoNames, Overture, etc.).")


@importers_app.command("osm")
def import_osm_cmd(
    ctx: typer.Context,
    extra: list[str] = typer.Argument(None),
    dry_run: bool = typer.Option(False, "--dry-run"),
) -> None:
    osm_importer.import_osm(settings_from_ctx(ctx), list(extra or []), dry_run=dry_run)


@importers_app.command("reference")
def import_reference_cmd(
    ctx: typer.Context,
    extra: list[str] = typer.Argument(None),
    dry_run: bool = typer.Option(False, "--dry-run"),
) -> None:
    reference_importer.import_reference(settings_from_ctx(ctx), list(extra or []), dry_run=dry_run)


@importers_app.command("geonames")
def import_geonames_cmd(
    ctx: typer.Context,
    extra: list[str] = typer.Argument(None),
    dry_run: bool = typer.Option(False, "--dry-run"),
) -> None:
    geonames_importer.import_geonames(settings_from_ctx(ctx), list(extra or []), dry_run=dry_run)


@importers_app.command("buildings")
def import_buildings_cmd(
    ctx: typer.Context,
    extra: list[str] = typer.Argument(None),
    dry_run: bool = typer.Option(False, "--dry-run"),
) -> None:
    buildings_importer.import_buildings(settings_from_ctx(ctx), list(extra or []), dry_run=dry_run)


__all__ = ["importers_app"]
