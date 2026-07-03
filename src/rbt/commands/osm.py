"""``rbt osm`` — continuous OSM updates and diff management."""

from __future__ import annotations

import typer

from ..importers import osm as osm_importer
from ..importers.osm import OsmStage
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
    """Run the one-time OSM data importer.

    Alias for ``rbt import osm``, kept here too since it reads naturally
    alongside ``run``/``status``/``stop``; prefer ``rbt import osm`` in new
    scripts for consistency with the other data sources.
    """
    osm_importer.run_import(
        settings_from_ctx(ctx), stage, start_seq=start_seq, end_seq=end_seq, dry_run=dry_run
    )


__all__ = ["osm_app"]
