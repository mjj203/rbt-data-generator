"""Tippecanoe command construction and execution."""

from __future__ import annotations

from pathlib import Path

from ..config import Settings
from ..layers import Layer, LayerRegistry, Projection
from ..logging import get_logger
from ..process import run

log = get_logger(__name__)


def build_tippecanoe_command(
    layer: Layer,
    settings: Settings,
    input_file: Path,
    output_file: Path,
    registry: LayerRegistry,
) -> list[str]:
    cmd: list[str] = [
        "tippecanoe",
        "-t",
        str(settings.tile_temp_dir),
        "-o",
        str(output_file),
        "-P",
        "-s",
        "EPSG:3857",  # tippecanoe expects 3857 source even when target_srs is different
        "-Z",
        str(layer.min_zoom),
        "-z",
        str(layer.max_zoom),
        "-n",
        layer.layer_name,
        "-l",
        layer.layer_name,
    ]

    for default_opt in registry.defaults.get("tippecanoe_options", []) or []:
        if default_opt not in cmd:
            cmd.append(str(default_opt))

    for option in layer.tippecanoe.options:
        cmd.append(option)

    for attr in layer.tippecanoe.int_attrs:
        cmd += ["-T", f"{attr}:int"]
    for attr in layer.tippecanoe.float_attrs:
        cmd += ["-T", f"{attr}:float"]
    for attr in layer.tippecanoe.bool_attrs:
        cmd += ["-T", f"{attr}:bool"]
    for attr in layer.tippecanoe.string_attrs:
        cmd += ["-T", f"{attr}:string"]

    filter_json = registry.filter_for(layer)
    if filter_json:
        cmd += ["-j", filter_json]

    cmd.append(str(input_file))
    return cmd


def run_tippecanoe(
    layer: Layer,
    projection: Projection,
    settings: Settings,
    input_file: Path,
    output_dir: Path,
    registry: LayerRegistry,
    *,
    dry_run: bool = False,
    log_file: Path | None = None,
) -> Path:
    output_dir.mkdir(parents=True, exist_ok=True)
    output_file = output_dir / f"{layer.output_basename(projection.code)}.mbtiles"
    cmd = build_tippecanoe_command(
        layer=layer,
        settings=settings,
        input_file=input_file,
        output_file=output_file,
        registry=registry,
    )
    settings.tile_temp_dir.mkdir(parents=True, exist_ok=True)
    # tippecanoe refuses to overwrite an existing .mbtiles, so remove a stale one
    # first; otherwise `rbt tiles --force` (and any re-run) crashes once a layer's
    # output already exists. The overwrite flag is deliberately kept out of
    # build_tippecanoe_command so its argv stays identical to the legacy bash
    # generator for the parity tests.
    if not dry_run and output_file.exists():
        output_file.unlink()
    run(cmd, log_file=log_file, dry_run=dry_run)
    return output_file


__all__ = ["build_tippecanoe_command", "run_tippecanoe"]
