"""``rbt setup`` — one-time database initialization."""

from __future__ import annotations

import typer

from .. import setup_db
from ..importers.osm import OsmStage
from ..layers import load_registry
from ._common import settings_from_ctx

setup_app = typer.Typer(help="Database initialization helpers.")


@setup_app.callback(invoke_without_command=True)
def setup_entry(
    ctx: typer.Context,
    all_: bool = typer.Option(False, "--all"),
    setup_database: bool = typer.Option(False, "--setup-database"),
    import_osm_data: bool = typer.Option(False, "--import-osm-data"),
    import_reference_data: bool = typer.Option(False, "--import-reference-data"),
    import_geonames: bool = typer.Option(False, "--import-geonames"),
    import_buildings: bool = typer.Option(False, "--import-buildings"),
    process_schemas: bool = typer.Option(False, "--process-schemas"),
    osm_stage: OsmStage = typer.Option(
        OsmStage.all,
        "--osm-stage",
        help="OSM import stage to run within setup (default: the full workflow).",
    ),
    dry_run: bool = typer.Option(False, "--dry-run"),
) -> None:
    """One-time database initialization (bootstrap, imports, schemas)."""
    if ctx.invoked_subcommand is not None:
        return

    step_flags = (
        setup_database,
        import_osm_data,
        import_reference_data,
        import_geonames,
        import_buildings,
        process_schemas,
    )
    if all_ and any(step_flags):
        # --all already runs every step; combining it with individual step flags
        # is contradictory (the step flags were previously silently ignored).
        raise typer.BadParameter(
            "--all runs every step; do not combine it with individual "
            "--setup-database / --import-* / --process-schemas flags."
        )

    if all_ or not any(step_flags):
        steps = setup_db.SetupSteps.all()
    else:
        steps = setup_db.SetupSteps(
            bootstrap=setup_database,
            import_osm=import_osm_data,
            import_reference=import_reference_data,
            import_geonames=import_geonames,
            import_buildings=import_buildings,
            process_schemas=process_schemas,
        )
    setup_db.run_setup(
        settings_from_ctx(ctx),
        load_registry(),
        steps,
        osm_stage=osm_stage,
        dry_run=dry_run,
    )


__all__ = ["setup_app"]
