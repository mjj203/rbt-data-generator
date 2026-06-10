"""Top-level Typer application for ``rbt``.

Usage:

    rbt --help
    rbt tiles --help
    rbt tiles --layer-type physical --projection 3857 --water
    rbt osm run
    rbt setup --all
    rbt validate
"""

from __future__ import annotations

import sys
from dataclasses import asdict
from datetime import datetime
from enum import Enum
from pathlib import Path

import typer
from rich.console import Console
from rich.table import Table

from . import __version__, bash, checks, schema, setup_db
from .config import Settings, load_settings
from .importers import buildings as buildings_importer
from .importers import geonames as geonames_importer
from .importers import osm as osm_importer
from .importers import reference as reference_importer
from .layers import LayerRegistry, load_registry
from .logging import configure_logging, get_logger
from .tiles import TileEngine
from .tiles.engine import TileJob, generate_layer

console = Console()
err_console = Console(stderr=True)

app = typer.Typer(
    name="rbt",
    help="RBT Vector Tiles CLI — tile generation, OSM updates, and database setup.",
    no_args_is_help=True,
    add_completion=False,
)

tiles_app = typer.Typer(help="Generate Mapbox Vector Tiles from the RBT database.")
osm_app = typer.Typer(help="Continuous OSM updates and diff management.")
setup_app = typer.Typer(help="Database initialization helpers.")
importers_app = typer.Typer(help="Run individual data importers (OSM, GeoNames, Overture, etc.).")
layers_app = typer.Typer(help="Inspect the declarative layer registry.")
schema_app = typer.Typer(help="Run database schema SQL (rbt.* views).")

app.add_typer(tiles_app, name="tiles")
app.add_typer(osm_app, name="osm")
app.add_typer(setup_app, name="setup")
app.add_typer(importers_app, name="import")
app.add_typer(layers_app, name="layers")
app.add_typer(schema_app, name="schema")


class LayerType(str, Enum):
    physical = "physical"
    cultural = "cultural"
    all = "all"


class Projection(str, Enum):
    p3857 = "3857"
    p3395 = "3395"
    p4326 = "4326"
    all = "all"


class Mode(str, Enum):
    native = "native"
    bash = "bash"


def _version_callback(value: bool) -> None:
    if value:
        console.print(f"rbt {__version__}")
        raise typer.Exit()


@app.callback()
def _main(
    ctx: typer.Context,
    verbose: bool = typer.Option(False, "--verbose", "-v", help="Verbose logging."),
    debug: bool = typer.Option(False, "--debug", help="Debug-level logging."),
    log_file: Path = typer.Option(
        None,
        "--log-file",
        help="Duplicate logs to this file (defaults to $SHARED_LOG_DIR/rbt_<ts>.log for mutating commands).",
    ),
    no_log_file: bool = typer.Option(
        False,
        "--no-log-file",
        help="Disable file logging entirely (useful for tests and short read-only commands).",
    ),
    version: bool = typer.Option(
        False,
        "--version",
        callback=_version_callback,
        is_eager=True,
        help="Show version and exit.",
    ),
) -> None:
    """Entry-point configuration (logging, settings)."""
    settings = load_settings()
    if debug or settings.debug:
        log_level = "DEBUG"
    elif verbose or settings.verbose:
        log_level = "INFO"
    else:
        log_level = settings.log_level

    resolved_log_file: Path | None
    if no_log_file:
        resolved_log_file = None
    elif log_file is not None:
        resolved_log_file = log_file
    elif _is_read_only_invocation(ctx):
        resolved_log_file = None
    else:
        resolved_log_file = (
            settings.shared_log_dir / f"rbt_{datetime.now():%Y%m%d_%H%M%S}.log"
        )

    configure_logging(level=log_level, log_file=resolved_log_file, console=err_console)
    ctx.ensure_object(dict)
    ctx.obj["settings"] = settings
    ctx.obj["log"] = get_logger("rbt.cli")


_READ_ONLY_COMMANDS = {"layers", "validate", "health", "smoke"}


def _is_read_only_invocation(ctx: typer.Context) -> bool:
    invoked = ctx.invoked_subcommand
    return invoked is None or invoked in _READ_ONLY_COMMANDS


def _settings(ctx: typer.Context) -> Settings:
    settings: Settings = ctx.obj["settings"]
    return settings


def _projections_for(projection: Projection, registry: LayerRegistry) -> list[str]:
    if projection is Projection.all:
        return list(registry.projections.keys())
    return [projection.value]


def _categories_from_flags(
    registry: LayerRegistry,
    layer_type: str,
    flags: dict[str, bool],
) -> list[str]:
    return [cat for cat, enabled in flags.items() if enabled and cat in registry.categories_for(layer_type)]


# ---------------------------------------------------------------------------
# rbt tiles
# ---------------------------------------------------------------------------


@tiles_app.callback(invoke_without_command=True)
def tiles_entry(
    ctx: typer.Context,
    layer_type: LayerType = typer.Option(LayerType.all, "--layer-type"),
    projection: Projection = typer.Option(Projection.all, "--projection"),
    mode: Mode = typer.Option(Mode.native, "--mode", help="native (Python engine) or bash (delegate to legacy scripts)."),
    all_: bool = typer.Option(False, "--all", help="Generate every layer in every projection."),
    tile_join: bool = typer.Option(True, "--tile-join/--no-tile-join"),
    add_btis: bool = typer.Option(True, "--add-btis/--no-btis"),
    dry_run: bool = typer.Option(False, "--dry-run", "-d"),
    force: bool = typer.Option(
        False,
        "--force",
        help="Re-export cached FlatGeoBuf files (use after a database refresh).",
    ),
    # Cultural category flags
    aeroway: bool = typer.Option(False, "--aeroway"),
    boundary: bool = typer.Option(False, "--boundary"),
    building: bool = typer.Option(False, "--building"),
    cemetery: bool = typer.Option(False, "--cemetery"),
    geonames: bool = typer.Option(False, "--geonames"),
    transportation: bool = typer.Option(False, "--transportation"),
    utilities: bool = typer.Option(False, "--utilities"),
    other: bool = typer.Option(False, "--other"),
    # Physical category flags
    builtuparea: bool = typer.Option(False, "--builtuparea"),
    contour: bool = typer.Option(False, "--contour"),
    glacier: bool = typer.Option(False, "--glacier"),
    landcover: bool = typer.Option(False, "--landcover"),
    mountain: bool = typer.Option(False, "--mountain"),
    park: bool = typer.Option(False, "--park"),
    water: bool = typer.Option(False, "--water"),
    water_label: bool = typer.Option(False, "--water-label"),
    waterway: bool = typer.Option(False, "--waterway"),
    inland_water: bool = typer.Option(False, "--inland-water"),
    layer: list[str] = typer.Option(
        [], "--layer", help="Generate a specific layer by registry key (repeatable)."
    ),
) -> None:
    """Generate vector tiles."""
    if ctx.invoked_subcommand is not None:
        return

    settings = _settings(ctx)
    log = ctx.obj["log"]

    if mode is Mode.bash:
        bash_args = _build_bash_args(
            layer_type=layer_type,
            projection=projection,
            all_=all_,
            tile_join=tile_join,
            add_btis=add_btis,
            cultural_flags={
                "aeroway": aeroway,
                "boundary": boundary,
                "building": building,
                "cemetery": cemetery,
                "geonames": geonames,
                "transportation": transportation,
                "utilities": utilities,
                "other": other,
            },
            physical_flags={
                "builtuparea": builtuparea,
                "contour": contour,
                "glacier": glacier,
                "landcover": landcover,
                "mountain": mountain,
                "park": park,
                "water": water,
                "water-label": water_label,
                "waterway": waterway,
                "inland-water": inland_water,
            },
        )
        log.info("delegating to production/generate-tiles.sh %s", " ".join(bash_args))
        bash.generate_tiles_bash(settings, bash_args, dry_run=dry_run)
        return

    registry = load_registry()
    engine = TileEngine(settings=settings, registry=registry, dry_run=dry_run, force=force)

    if all_:
        layer_type = LayerType.all
        projection = Projection.all

    layer_types = (
        ["physical", "cultural"] if layer_type is LayerType.all else [layer_type.value]
    )
    projection_codes = _projections_for(projection, registry)

    cultural_cats = _categories_from_flags(
        registry,
        "cultural",
        {
            "aeroway": aeroway,
            "boundary": boundary,
            "building": building,
            "cemetery": cemetery,
            "geonames": geonames,
            "transportation": transportation,
            "utilities": utilities,
            "other": other,
        },
    )
    physical_cats = _categories_from_flags(
        registry,
        "physical",
        {
            "builtuparea": builtuparea,
            "contour": contour,
            "glacier": glacier,
            "landcover": landcover,
            "mountain": mountain,
            "park": park,
            "water": water,
            "water_label": water_label,
            "waterway": waterway,
            "inland_water": inland_water,
        },
    )

    for lt in layer_types:
        categories = cultural_cats if lt == "cultural" else physical_cats
        selected_layers = engine.resolve_layers(
            lt,
            categories=categories or None,
            layer_keys=layer or None,
        )
        if not selected_layers:
            log.warning("No %s layers selected", lt)
            continue
        for code in projection_codes:
            proj = registry.projections[code]
            output_dir = engine.output_dir_for(lt, proj)
            job = TileJob(
                layer_type=lt,
                projection=proj,
                layers=selected_layers,
                output_dir=output_dir,
                tile_join=tile_join,
                add_btis=add_btis,
                categories=categories or None,
            )
            log.info(
                "generating %d %s layer(s) for EPSG:%s → %s",
                len(selected_layers),
                lt,
                proj.code,
                output_dir,
            )
            engine.generate(job)


@tiles_app.command("layer")
def tiles_layer_cmd(
    ctx: typer.Context,
    layer_key: str = typer.Argument(..., help="Layer key from config/layers.yml"),
    projection: Projection = typer.Option(Projection.p3857, "--projection"),
    dry_run: bool = typer.Option(False, "--dry-run"),
    force: bool = typer.Option(False, "--force", help="Re-export cached FlatGeoBuf files."),
) -> None:
    """Generate a single layer in a single projection."""
    generate_layer(layer_key, projection.value, _settings(ctx), dry_run=dry_run, force=force)


def _build_bash_args(
    *,
    layer_type: LayerType,
    projection: Projection,
    all_: bool,
    tile_join: bool,
    add_btis: bool,
    cultural_flags: dict[str, bool],
    physical_flags: dict[str, bool],
) -> list[str]:
    args: list[str] = []
    if all_:
        args.append("--all")
    else:
        args += ["--layer-type", layer_type.value]
        args += ["--projection", projection.value]
        for name, enabled in {**cultural_flags, **physical_flags}.items():
            if enabled:
                args.append(f"--{name}")
    if not tile_join:
        args.append("--no-tile-join")
    if not add_btis:
        args.append("--no-btis")
    return args


# ---------------------------------------------------------------------------
# rbt osm
# ---------------------------------------------------------------------------


@osm_app.command("run")
def osm_run(
    ctx: typer.Context,
    dry_run: bool = typer.Option(False, "--dry-run"),
) -> None:
    """Start the continuous imposm run loop (blocks until stopped)."""
    osm_importer.run_updates(_settings(ctx), dry_run=dry_run)


@osm_app.command("status")
def osm_status(ctx: typer.Context) -> None:
    """Show whether updates are running and the last applied OSM change."""
    raise typer.Exit(osm_importer.update_status(_settings(ctx)))


@osm_app.command("stop")
def osm_stop(ctx: typer.Context) -> None:
    """Stop a running `rbt osm run` supervisor."""
    raise typer.Exit(osm_importer.stop_updates(_settings(ctx)))


@osm_app.command("import")
def osm_import_cmd(
    ctx: typer.Context,
    extra: list[str] = typer.Argument(None, help="Pass-through arguments to import-osm-data.sh"),
    dry_run: bool = typer.Option(False, "--dry-run"),
) -> None:
    osm_importer.import_osm(_settings(ctx), list(extra or []), dry_run=dry_run)


# ---------------------------------------------------------------------------
# rbt setup
# ---------------------------------------------------------------------------


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
    osm_arg: list[str] = typer.Option(
        None,
        "--osm-arg",
        help="Stage flag passed through to the OSM import script "
        "(repeatable, use the = form: --osm-arg=--import). Defaults to --all.",
    ),
    dry_run: bool = typer.Option(False, "--dry-run"),
) -> None:
    """One-time database initialization (bootstrap, imports, schemas)."""
    if ctx.invoked_subcommand is not None:
        return

    if all_ or not any(
        (
            setup_database,
            import_osm_data,
            import_reference_data,
            import_geonames,
            import_buildings,
            process_schemas,
        )
    ):
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
        _settings(ctx), load_registry(), steps, osm_args=list(osm_arg or []), dry_run=dry_run
    )


# ---------------------------------------------------------------------------
# rbt import ...
# ---------------------------------------------------------------------------


@importers_app.command("osm")
def import_osm_cmd(
    ctx: typer.Context,
    extra: list[str] = typer.Argument(None),
    dry_run: bool = typer.Option(False, "--dry-run"),
) -> None:
    osm_importer.import_osm(_settings(ctx), list(extra or []), dry_run=dry_run)


@importers_app.command("reference")
def import_reference_cmd(
    ctx: typer.Context,
    extra: list[str] = typer.Argument(None),
    dry_run: bool = typer.Option(False, "--dry-run"),
) -> None:
    reference_importer.import_reference(_settings(ctx), list(extra or []), dry_run=dry_run)


@importers_app.command("geonames")
def import_geonames_cmd(
    ctx: typer.Context,
    extra: list[str] = typer.Argument(None),
    dry_run: bool = typer.Option(False, "--dry-run"),
) -> None:
    geonames_importer.import_geonames(_settings(ctx), list(extra or []), dry_run=dry_run)


@importers_app.command("buildings")
def import_buildings_cmd(
    ctx: typer.Context,
    extra: list[str] = typer.Argument(None),
    dry_run: bool = typer.Option(False, "--dry-run"),
) -> None:
    buildings_importer.import_buildings(_settings(ctx), list(extra or []), dry_run=dry_run)


# ---------------------------------------------------------------------------
# rbt layers
# ---------------------------------------------------------------------------


@layers_app.command("list")
def layers_list(
    layer_type: LayerType = typer.Option(LayerType.all, "--layer-type"),
) -> None:
    """List every known layer and its tippecanoe configuration."""
    registry = load_registry()
    table = Table(title="RBT Layer Registry")
    table.add_column("Key", style="cyan")
    table.add_column("Type", style="green")
    table.add_column("Category", style="yellow")
    table.add_column("Source")
    table.add_column("Zoom")
    table.add_column("Projections")
    table.add_column("Filter")

    for layer in registry.layers.values():
        if layer_type is not LayerType.all and layer.layer_type != layer_type.value:
            continue
        table.add_row(
            layer.key,
            layer.layer_type,
            layer.category,
            layer.source_table,
            f"{layer.min_zoom}→{layer.max_zoom}",
            ",".join(layer.projections),
            layer.tippecanoe.filter_ref or "",
        )
    console.print(table)


@layers_app.command("show")
def layers_show(layer_key: str = typer.Argument(...)) -> None:
    """Print a single layer's full definition."""
    registry = load_registry()
    layer = registry.layer(layer_key)

    console.print_json(data=asdict(layer))
    filter_json = registry.filter_for(layer)
    if filter_json:
        console.rule("filter")
        console.print(filter_json)


# ---------------------------------------------------------------------------
# rbt schema
# ---------------------------------------------------------------------------


@schema_app.command("list")
def schema_list() -> None:
    """List the registered schema SQL units."""
    registry = load_registry()
    table = Table(title="RBT Schema Units")
    table.add_column("Key", style="cyan")
    table.add_column("Type", style="green")
    table.add_column("SQL file")
    table.add_column("Description")
    for unit in registry.schemas.values():
        table.add_row(unit.key, unit.layer_type, unit.sql, unit.description)
    console.print(table)


@schema_app.command("run")
def schema_run(
    ctx: typer.Context,
    keys: list[str] = typer.Argument(None, help="Schema keys (see `rbt schema list`)."),
    layer_type: LayerType | None = typer.Option(
        None, "--type", help="Run every schema of this layer type."
    ),
    all_: bool = typer.Option(False, "--all", help="Run every registered schema."),
    dry_run: bool = typer.Option(False, "--dry-run"),
) -> None:
    """Execute schema SQL files via psql (creates/refreshes the rbt.* views)."""
    selected_keys = list(keys or [])
    selected_type = (
        layer_type.value if layer_type is not None and layer_type is not LayerType.all else None
    )
    if all_:
        selected_keys, selected_type = [], None
    schema.run_schemas(
        _settings(ctx),
        load_registry(),
        keys=selected_keys or None,
        layer_type=selected_type,
        dry_run=dry_run,
    )


# ---------------------------------------------------------------------------
# rbt validate / rbt smoke / rbt health
# ---------------------------------------------------------------------------


@app.command("validate")
def validate(ctx: typer.Context) -> None:
    """Pre-flight validation: config, tools, database, disk, and memory."""
    raise typer.Exit(checks.validate(_settings(ctx)))


@app.command("smoke")
def smoke(ctx: typer.Context) -> None:
    """End-to-end sanity check (validate, bootstrap, schemas, tile dry-runs)."""
    raise typer.Exit(checks.smoke(_settings(ctx)))


@app.command("health")
def health(ctx: typer.Context) -> None:
    """Fast liveness probe used by the Docker HEALTHCHECK."""
    raise typer.Exit(checks.health(_settings(ctx)))


# Click object exposed for the docs build (mkdocs-click renders docs/cli.md
# from this at every `mkdocs build`, so the CLI reference can never drift).
click_app = typer.main.get_command(app)


def main() -> None:  # pragma: no cover - CLI entry
    try:
        app()
    except Exception as exc:  # noqa: BLE001
        err_console.print(f"[red]error:[/red] {exc}")
        sys.exit(1)


if __name__ == "__main__":  # pragma: no cover
    main()
