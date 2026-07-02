"""``rbt tiles`` — vector tile generation.

The category flags (``--water``, ``--building``, ...) are declared once as
Typer options (required, since Typer introspects the function signature to
build the CLI), then immediately normalized into a single :class:`TileRequest`
by :func:`_build_tile_request` — a pure function keyed on the same
underscore-form category names the layer registry uses. Both the native
engine (:func:`_dispatch_native`) and the deprecated bash escape hatch
(:func:`_dispatch_bash`) consume that one request object, so the two dispatch
paths can never drift on flag spelling (bash argument names are derived from
the request's own keys, not hand-duplicated).
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from enum import Enum
from typing import Any

import typer

from ..bash import generate_tiles_bash
from ..config import Settings
from ..layers import LayerRegistry, load_registry
from ..tiles import TileEngine
from ..tiles.engine import TileJob, generate_layer
from ._common import LayerType, settings_from_ctx

tiles_app = typer.Typer(help="Generate Mapbox Vector Tiles from the RBT database.")


class ProjectionChoice(str, Enum):
    """CLI projection selector.

    Named ``ProjectionChoice`` (not ``Projection``) to avoid shadowing
    :class:`rbt.layers.Projection`, the registry's richer projection record.
    """

    p3857 = "3857"
    p3395 = "3395"
    p4326 = "4326"
    all = "all"


class Mode(str, Enum):
    native = "native"
    bash = "bash"


# Canonical, underscore-form category names — the single source of truth for
# both the Typer parameter names below and the registry category lookups.
# Bash argument spelling is derived from these via ``str.replace("_", "-")``,
# so the two can never diverge (see module docstring).
CULTURAL_CATEGORY_FLAGS: tuple[str, ...] = (
    "aeroway",
    "boundary",
    "building",
    "cemetery",
    "geonames",
    "transportation",
    "utilities",
    "other",
)
PHYSICAL_CATEGORY_FLAGS: tuple[str, ...] = (
    "builtuparea",
    "contour",
    "glacier",
    "landcover",
    "mountain",
    "park",
    "water",
    "water_label",
    "waterway",
    "inland_water",
)


@dataclass(frozen=True, slots=True)
class TileRequest:
    """Normalized ``rbt tiles`` invocation, independent of Typer.

    Built once by :func:`_build_tile_request` from the raw CLI options; both
    :func:`_dispatch_native` and :func:`_dispatch_bash` read only from this
    object, never from the original Typer parameters.
    """

    layer_type: LayerType
    projection: ProjectionChoice
    mode: Mode
    tile_join: bool
    add_btis: bool
    dry_run: bool
    force: bool
    all_: bool
    cultural_flags: dict[str, bool]
    physical_flags: dict[str, bool]
    layer_keys: tuple[str, ...]


def _build_tile_request(local_flags: dict[str, Any]) -> TileRequest:
    """Pure normalization step: raw Typer parameters -> :class:`TileRequest`."""
    cultural_flags = {cat: local_flags[cat] for cat in CULTURAL_CATEGORY_FLAGS}
    physical_flags = {cat: local_flags[cat] for cat in PHYSICAL_CATEGORY_FLAGS}

    layer_type: LayerType = local_flags["layer_type"]
    projection: ProjectionChoice = local_flags["projection"]
    all_: bool = local_flags["all_"]
    if all_:
        layer_type = LayerType.all
        projection = ProjectionChoice.all

    return TileRequest(
        layer_type=layer_type,
        projection=projection,
        mode=local_flags["mode"],
        tile_join=local_flags["tile_join"],
        add_btis=local_flags["add_btis"],
        dry_run=local_flags["dry_run"],
        force=local_flags["force"],
        all_=all_,
        cultural_flags=cultural_flags,
        physical_flags=physical_flags,
        layer_keys=tuple(local_flags["layer"] or ()),
    )


def _bash_flag_name(category: str) -> str:
    return category.replace("_", "-")


def _selected_categories(request: TileRequest) -> list[str]:
    """Category flag names the user explicitly enabled (both layer types)."""
    return [
        cat
        for cat, enabled in {**request.cultural_flags, **request.physical_flags}.items()
        if enabled
    ]


def _validate_request(request: TileRequest) -> None:
    """Reject contradictory / silently-dropped flag combinations up front."""
    selected = _selected_categories(request)

    # --all means "every layer in every projection"; combining it with a
    # narrowing flag is contradictory and previously generated everything anyway.
    if request.all_ and (selected or request.layer_keys):
        raise typer.BadParameter(
            "--all cannot be combined with category flags (e.g. --water) or "
            "--layer; use one or the other."
        )

    # The deprecated bash generator has no --force/--layer equivalent, so
    # forwarding is impossible; fail loudly instead of silently ignoring them.
    if request.mode is Mode.bash:
        dropped = [
            name
            for name, used in (("--force", request.force), ("--layer", bool(request.layer_keys)))
            if used
        ]
        if dropped:
            raise typer.BadParameter(
                f"{', '.join(dropped)} not supported with --mode bash "
                "(the legacy generator has no equivalent); use the native engine."
            )


def _projections_for(projection: ProjectionChoice, registry: LayerRegistry) -> list[str]:
    if projection is ProjectionChoice.all:
        return list(registry.projections.keys())
    return [projection.value]


def _enabled_categories(
    registry: LayerRegistry, layer_type: str, flags: dict[str, bool]
) -> list[str]:
    return [
        cat
        for cat, enabled in flags.items()
        if enabled and cat in registry.categories_for(layer_type)
    ]


def _dispatch_bash(request: TileRequest, settings: Settings, log: logging.Logger) -> None:
    args: list[str] = []
    if request.all_:
        args.append("--all")
    else:
        args += ["--layer-type", request.layer_type.value]
        args += ["--projection", request.projection.value]
        for category, enabled in {**request.cultural_flags, **request.physical_flags}.items():
            if enabled:
                args.append(f"--{_bash_flag_name(category)}")
    if not request.tile_join:
        args.append("--no-tile-join")
    if not request.add_btis:
        args.append("--no-btis")

    log.info("delegating to production/generate-tiles.sh %s", " ".join(args))
    generate_tiles_bash(settings, args, dry_run=request.dry_run)


def _dispatch_native(request: TileRequest, settings: Settings, log: logging.Logger) -> None:
    registry = load_registry()
    engine = TileEngine(
        settings=settings, registry=registry, dry_run=request.dry_run, force=request.force
    )

    layer_types = (
        ["physical", "cultural"]
        if request.layer_type is LayerType.all
        else [request.layer_type.value]
    )
    projection_codes = _projections_for(request.projection, registry)

    cultural_cats = _enabled_categories(registry, "cultural", request.cultural_flags)
    physical_cats = _enabled_categories(registry, "physical", request.physical_flags)

    for lt in layer_types:
        categories = cultural_cats if lt == "cultural" else physical_cats
        selected_layers = engine.resolve_layers(
            lt,
            categories=categories or None,
            layer_keys=list(request.layer_keys) or None,
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
                tile_join=request.tile_join,
                add_btis=request.add_btis,
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


@tiles_app.callback(invoke_without_command=True)
def tiles_entry(
    ctx: typer.Context,
    layer_type: LayerType = typer.Option(LayerType.all, "--layer-type"),
    projection: ProjectionChoice = typer.Option(ProjectionChoice.all, "--projection"),
    mode: Mode = typer.Option(
        Mode.native, "--mode", help="native (Python engine) or bash (delegate to legacy scripts)."
    ),
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

    request = _build_tile_request(
        {
            "layer_type": layer_type,
            "projection": projection,
            "mode": mode,
            "all_": all_,
            "tile_join": tile_join,
            "add_btis": add_btis,
            "dry_run": dry_run,
            "force": force,
            "layer": layer,
            "aeroway": aeroway,
            "boundary": boundary,
            "building": building,
            "cemetery": cemetery,
            "geonames": geonames,
            "transportation": transportation,
            "utilities": utilities,
            "other": other,
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
        }
    )
    _validate_request(request)
    settings = settings_from_ctx(ctx)
    log: logging.Logger = ctx.obj["log"]

    if request.mode is Mode.bash:
        _dispatch_bash(request, settings, log)
    else:
        _dispatch_native(request, settings, log)


@tiles_app.command("layer")
def tiles_layer_cmd(
    ctx: typer.Context,
    layer_key: str = typer.Argument(..., help="Layer key from config/layers.yml"),
    projection: ProjectionChoice = typer.Option(ProjectionChoice.p3857, "--projection"),
    dry_run: bool = typer.Option(False, "--dry-run"),
    force: bool = typer.Option(False, "--force", help="Re-export cached FlatGeoBuf files."),
) -> None:
    """Generate a single layer in a single projection."""
    generate_layer(
        layer_key, projection.value, settings_from_ctx(ctx), dry_run=dry_run, force=force
    )


__all__ = ["Mode", "ProjectionChoice", "TileRequest", "tiles_app"]
