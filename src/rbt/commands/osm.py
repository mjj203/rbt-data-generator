"""``rbt osm`` — continuous OSM updates and diff management."""

from __future__ import annotations

import typer

from ..importers import osm as osm_importer
from ._common import settings_from_ctx

osm_app = typer.Typer(help="Continuous OSM updates and diff management.")


@osm_app.command("run")
def osm_run(
    ctx: typer.Context,
    dry_run: bool = typer.Option(False, "--dry-run"),
) -> None:
    """Start the continuous imposm run loop (blocks until stopped)."""
    osm_importer.run_updates(settings_from_ctx(ctx), dry_run=dry_run)


@osm_app.command("status")
def osm_status(ctx: typer.Context) -> None:
    """Show whether updates are running and the last applied OSM change."""
    raise typer.Exit(osm_importer.update_status(settings_from_ctx(ctx)))


@osm_app.command("stop")
def osm_stop(ctx: typer.Context) -> None:
    """Stop a running `rbt osm run` supervisor."""
    raise typer.Exit(osm_importer.stop_updates(settings_from_ctx(ctx)))


@osm_app.command("import")
def osm_import_cmd(
    ctx: typer.Context,
    extra: list[str] = typer.Argument(None, help="Pass-through arguments to import-osm-data.sh"),
    dry_run: bool = typer.Option(False, "--dry-run"),
) -> None:
    """Run the OSM data importer.

    Alias for ``rbt import osm``, kept here too since it reads naturally
    alongside ``run``/``status``/``stop``. Both dispatch the same
    :func:`rbt.importers.osm.import_osm`; prefer ``rbt import osm`` in new
    scripts for consistency with the other data sources.
    """
    osm_importer.import_osm(settings_from_ctx(ctx), list(extra or []), dry_run=dry_run)


__all__ = ["osm_app"]
