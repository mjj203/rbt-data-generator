"""Tests for the high-level tile engine."""

from __future__ import annotations

import logging
from dataclasses import replace
from pathlib import Path

import rbt.tiles.engine as engine_mod
import rbt.tiles.tippecanoe
from rbt.config import load_settings
from rbt.layers import Projection, load_registry
from rbt.tiles.engine import TileEngine, TileJob, TileResult


def make_engine(fake_repo: Path, **kwargs: object) -> TileEngine:
    settings = load_settings(overrides={"TILE_TEMP_DIR": str(fake_repo / "output" / "tile-temp")})
    return TileEngine(settings=settings, registry=load_registry(), **kwargs)  # type: ignore[arg-type]


def patch_tippecanoe_to_touch_output(recorded_run, monkeypatch) -> None:
    """Record tippecanoe calls and create the ``-o`` file like the real binary,
    so the downstream tile-join existence filter sees the per-layer MBTiles."""

    def run_and_touch(cmd, **kwargs):
        result = recorded_run(cmd, **kwargs)
        if cmd[0] == "tippecanoe":
            Path(cmd[cmd.index("-o") + 1]).touch()
        return result

    monkeypatch.setattr(rbt.tiles.tippecanoe, "run", run_and_touch)


def patch_btis_recorder(monkeypatch) -> list[tuple[object, ...]]:
    calls: list[tuple[object, ...]] = []
    monkeypatch.setattr(
        engine_mod, "apply_btis_metadata", lambda *args, **kwargs: calls.append(args)
    )
    return calls


# ---------------------------------------------------------------- resolve_layers


def test_resolve_layers_by_type_returns_all(fake_repo: Path) -> None:
    engine = make_engine(fake_repo)

    keys = [layer.key for layer in engine.resolve_layers("physical")]

    assert keys == ["water", "waterway"]


def test_resolve_layers_by_category_subset(fake_repo: Path) -> None:
    engine = make_engine(fake_repo)

    keys = [layer.key for layer in engine.resolve_layers("physical", categories=["water"])]

    assert keys == ["water"]


def test_resolve_layers_by_layer_key(fake_repo: Path) -> None:
    engine = make_engine(fake_repo)

    keys = [layer.key for layer in engine.resolve_layers("physical", layer_keys=["waterway"])]

    assert keys == ["waterway"]


def test_resolve_layers_wrong_type_key_warns_and_skips(fake_repo: Path, caplog) -> None:
    engine = make_engine(fake_repo)

    with caplog.at_level(logging.WARNING, logger="rbt.tiles.engine"):
        layers = engine.resolve_layers("physical", layer_keys=["building"])

    assert layers == []
    assert any(
        "building" in record.getMessage() and "skipping" in record.getMessage()
        for record in caplog.records
    )


# ---------------------------------------------------------------- generate (3857/3395)


def test_generate_3857_orders_export_tippecanoe_then_join(
    fake_repo: Path, recorded_run, monkeypatch
) -> None:
    patch_tippecanoe_to_touch_output(recorded_run, monkeypatch)
    btis_calls = patch_btis_recorder(monkeypatch)

    engine = make_engine(fake_repo)
    projection = engine.registry.projections["3857"]
    output_dir = engine.output_dir_for("physical", projection)
    job = TileJob(
        layer_type="physical",
        projection=projection,
        layers=engine.registry.layers_for_type("physical"),
        output_dir=output_dir,
    )

    results = engine.generate(job)

    assert [r.layer.key for r in results if r.layer] == ["water", "waterway"]
    programs = [cmd[0] for cmd in recorded_run.commands]
    assert programs == ["ogr2ogr", "tippecanoe", "ogr2ogr", "tippecanoe", "tile-join"]
    # Per-layer ordering: each export immediately precedes its tippecanoe run.
    assert "rbt.water" in recorded_run.commands[0]
    assert recorded_run.commands[1][recorded_run.commands[1].index("-l") + 1] == "water"
    assert "rbt.waterway" in recorded_run.commands[2]
    assert recorded_run.commands[3][recorded_run.commands[3].index("-l") + 1] == "waterway"

    merged = output_dir / "physical_3857.mbtiles"
    join_cmd = recorded_run.commands[4]
    assert join_cmd[:5] == ["tile-join", "-f", "-pk", "-o", str(merged)]
    assert join_cmd[5:] == [str(r.output) for r in results]
    # BTIS metadata lands on the merged file only.
    assert btis_calls == [(merged, projection, "9.9.9")]


def test_generate_single_result_skips_tile_join(fake_repo: Path, recorded_run, monkeypatch) -> None:
    patch_tippecanoe_to_touch_output(recorded_run, monkeypatch)
    btis_calls = patch_btis_recorder(monkeypatch)

    engine = make_engine(fake_repo)
    projection = engine.registry.projections["3857"]
    output_dir = engine.output_dir_for("physical", projection)
    job = TileJob(
        layer_type="physical",
        projection=projection,
        layers=[engine.registry.layer("water")],
        output_dir=output_dir,
    )

    results = engine.generate(job)

    assert len(results) == 1
    assert [cmd[0] for cmd in recorded_run.commands] == ["ogr2ogr", "tippecanoe"]
    # BTIS still applies, but to the single per-layer output.
    assert btis_calls == [(results[0].output, projection, "9.9.9")]


def test_generate_no_tile_join_multi_layer_applies_btis_per_layer(
    fake_repo: Path, recorded_run, monkeypatch
) -> None:
    patch_tippecanoe_to_touch_output(recorded_run, monkeypatch)
    btis_calls = patch_btis_recorder(monkeypatch)

    engine = make_engine(fake_repo)
    projection = engine.registry.projections["3857"]
    output_dir = engine.output_dir_for("physical", projection)
    job = TileJob(
        layer_type="physical",
        projection=projection,
        layers=engine.registry.layers_for_type("physical"),
        output_dir=output_dir,
        tile_join=False,
    )

    results = engine.generate(job)

    assert len(results) == 2
    # No merge happened, so BTIS must land on each per-layer output, not be skipped.
    assert [call[0] for call in btis_calls] == [r.output for r in results]
    assert "tile-join" not in [cmd[0] for cmd in recorded_run.commands]


def test_generate_skips_layer_not_configured_for_projection(
    fake_repo: Path, recorded_run, monkeypatch
) -> None:
    patch_tippecanoe_to_touch_output(recorded_run, monkeypatch)
    patch_btis_recorder(monkeypatch)

    engine = make_engine(fake_repo)
    registry = engine.registry
    projection = registry.projections["3395"]
    water = registry.layer("water")
    mercator_only = replace(
        water, key="water_3857_only", mbtiles_name="water_3857_only", projections=("3857",)
    )
    output_dir = engine.output_dir_for("physical", projection)
    job = TileJob(
        layer_type="physical",
        projection=projection,
        layers=[water, mercator_only],
        output_dir=output_dir,
    )

    results = engine.generate(job)

    assert [r.layer.key for r in results if r.layer] == ["water"]
    assert all("water_3857_only" not in " ".join(cmd) for cmd in recorded_run.commands)
    # One layer survived, so no tile-join either.
    assert [cmd[0] for cmd in recorded_run.commands] == ["ogr2ogr", "tippecanoe"]


def test_dry_run_never_applies_btis(fake_repo: Path, recorded_run, monkeypatch) -> None:
    def boom(*args: object, **kwargs: object) -> None:
        raise AssertionError("apply_btis_metadata must not run under --dry-run")

    monkeypatch.setattr(engine_mod, "apply_btis_metadata", boom)

    engine = make_engine(fake_repo, dry_run=True)
    projection = engine.registry.projections["3857"]
    output_dir = engine.output_dir_for("physical", projection)
    job = TileJob(
        layer_type="physical",
        projection=projection,
        layers=[engine.registry.layer("water")],
        output_dir=output_dir,
        add_btis=True,
    )

    results = engine.generate(job)

    assert len(results) == 1
    assert recorded_run.calls  # commands were still rendered...
    assert all(call["dry_run"] is True for call in recorded_run.calls)  # ...as dry runs


# ---------------------------------------------------------------- generate (4326)


def test_generate_4326_dispatches_to_gdal_mvt(fake_repo: Path, recorded_run, monkeypatch) -> None:
    seen: dict[str, object] = {}

    def fake_generate_mvt_dataset(
        layer_type,
        settings,
        registry,
        output_root,
        *,
        categories=None,
        dry_run=False,
        log_file=None,
    ):
        seen.update(
            layer_type=layer_type,
            categories=categories,
            dry_run=dry_run,
            output_root=output_root,
        )
        return output_root / "physical_tiles"

    monkeypatch.setattr(engine_mod, "generate_mvt_dataset", fake_generate_mvt_dataset)

    engine = make_engine(fake_repo)
    projection = engine.registry.projections["4326"]
    output_dir = engine.output_dir_for("physical", projection)
    job = TileJob(
        layer_type="physical",
        projection=projection,
        layers=engine.registry.layers_for_type("physical"),
        output_dir=output_dir,
    )

    results = engine.generate(job)

    (result,) = results
    assert result.kind == "directory"
    assert result.layer is None
    assert result.projection is projection
    assert result.output == output_dir / "physical_tiles"
    assert seen["layer_type"] == "physical"
    # Full layer selection means no category narrowing.
    assert seen["categories"] is None
    assert seen["output_root"] == output_dir
    # No ogr2ogr/tippecanoe/tile-join commands on this path.
    assert recorded_run.calls == []


def test_generate_4326_partial_selection_narrows_categories(
    fake_repo: Path, recorded_run, monkeypatch
) -> None:
    seen: dict[str, object] = {}

    def fake_generate_mvt_dataset(layer_type, settings, registry, output_root, **kwargs):
        seen["categories"] = kwargs.get("categories")
        return output_root / "physical_tiles"

    monkeypatch.setattr(engine_mod, "generate_mvt_dataset", fake_generate_mvt_dataset)

    engine = make_engine(fake_repo)
    projection = engine.registry.projections["4326"]
    job = TileJob(
        layer_type="physical",
        projection=projection,
        layers=[engine.registry.layer("water")],
        output_dir=engine.output_dir_for("physical", projection),
    )

    engine.generate(job)

    assert seen["categories"] == ["water"]


def test_generate_layer_4326_uses_gdal_mvt(fake_repo: Path, recorded_run, monkeypatch) -> None:
    seen: dict[str, object] = {}

    def fake_generate_mvt_dataset(layer_type, settings, registry, output_root, **kwargs):
        seen["layer_type"] = layer_type
        seen["categories"] = kwargs.get("categories")
        return output_root / "physical_tiles"

    monkeypatch.setattr(engine_mod, "generate_mvt_dataset", fake_generate_mvt_dataset)
    settings = load_settings(overrides={"TILE_TEMP_DIR": str(fake_repo / "output" / "tile-temp")})

    result = engine_mod.generate_layer("water", "4326", settings)

    assert result.kind == "directory"
    assert result.layer is None
    assert seen["layer_type"] == "physical"
    # The single-layer convenience path narrows the 4326 dataset to that category.
    assert seen["categories"] == ["water"]
    # No tippecanoe/ogr2ogr/tile-join on the 4326 path.
    assert recorded_run.calls == []


def test_tile_result_mbtiles_aliases_output() -> None:
    projection = Projection(
        code="3857",
        epsg="EPSG:3857",
        output_dir="tiles_3857",
        tile_origin_x="0",
        tile_origin_y="0",
        tile_dimension_zoom_0="0",
    )
    result = TileResult(layer=None, projection=projection, output=Path("/tiles/x.mbtiles"))

    assert result.mbtiles == result.output == Path("/tiles/x.mbtiles")
