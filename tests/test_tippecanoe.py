"""Tests for tippecanoe command construction."""

from __future__ import annotations

from pathlib import Path

import rbt.tiles.tippecanoe as tippecanoe_mod
from rbt.config import load_settings
from rbt.layers import load_registry
from rbt.tiles.tippecanoe import build_tippecanoe_command, run_tippecanoe


def test_tippecanoe_command_has_required_flags(tmp_path: Path) -> None:
    settings = load_settings()
    registry = load_registry()
    layer = registry.layer("building")

    cmd = build_tippecanoe_command(
        layer=layer,
        settings=settings,
        input_file=tmp_path / "building.fgb",
        output_file=tmp_path / "building.mbtiles",
        registry=registry,
    )

    assert cmd[0] == "tippecanoe"
    assert "-t" in cmd
    assert "-o" in cmd
    assert "-Z" in cmd and str(layer.min_zoom) in cmd
    assert "-z" in cmd and str(layer.max_zoom) in cmd
    assert "-l" in cmd and layer.layer_name in cmd
    # The building layer references the building filter.
    assert "-j" in cmd
    assert str(tmp_path / "building.fgb") in cmd


def test_run_tippecanoe_removes_stale_output_before_invoking(tmp_path: Path, monkeypatch) -> None:
    settings = load_settings(overrides={"TILE_TEMP_DIR": str(tmp_path / "tmp")})
    registry = load_registry()
    layer = registry.layer("building")
    projection = registry.projections["3857"]
    output_dir = tmp_path / "out"
    output_dir.mkdir()
    stale = output_dir / f"{layer.output_basename(projection.code)}.mbtiles"
    stale.write_text("stale mbtiles")

    saw_existing: list[bool] = []

    def fake_run(cmd, **kwargs):
        # tippecanoe would refuse to run if the output still existed here.
        saw_existing.append(stale.exists())

    monkeypatch.setattr(tippecanoe_mod, "run", fake_run)

    run_tippecanoe(
        layer,
        projection,
        settings,
        input_file=output_dir / "building.fgb",
        output_dir=output_dir,
        registry=registry,
    )

    assert saw_existing == [False]


def test_int_attr_typings() -> None:
    settings = load_settings()
    registry = load_registry()
    layer = registry.layer("airports")

    cmd = build_tippecanoe_command(
        layer=layer,
        settings=settings,
        input_file=Path("in.fgb"),
        output_file=Path("out.mbtiles"),
        registry=registry,
    )
    assert "airport_id:int" in cmd
    assert "-T" in cmd
