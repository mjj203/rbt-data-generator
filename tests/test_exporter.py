"""Tests for the ogr2ogr FlatGeoBuf exporter."""

from __future__ import annotations

from dataclasses import replace
from pathlib import Path

import pytest

import rbt.tiles.exporter as exporter_mod
from rbt.config import Settings
from rbt.layers import Layer, OgrOptions, Projection, TippecanoeOptions
from rbt.process import CommandFailed
from rbt.tiles.exporter import export_layer_to_fgb

PROJECTION_3857 = Projection(
    code="3857",
    epsg="EPSG:3857",
    output_dir="tiles_3857",
    tile_origin_x="-20037508.342789244",
    tile_origin_y="20037508.342789244",
    tile_dimension_zoom_0="40075016.685578488",
)

_BASE_LAYER = Layer(
    key="water",
    layer_type="physical",
    source_table="rbt.water",
    category="water",
    layer_name="water",
    mbtiles_name="water",
    min_zoom=0,
    max_zoom=13,
    projections=("3857", "3395", "4326"),
    ogr=OgrOptions(),
    tippecanoe=TippecanoeOptions(),
)


def make_layer(**overrides: object) -> Layer:
    return replace(_BASE_LAYER, **overrides) if overrides else _BASE_LAYER  # type: ignore[arg-type]


def test_command_contains_srs_connection_and_table(tmp_path: Path, recorded_run) -> None:
    settings = Settings()

    fgb = export_layer_to_fgb(make_layer(), PROJECTION_3857, settings, tmp_path)

    assert fgb == tmp_path / "water_3857.fgb"
    (cmd,) = recorded_run.commands
    assert cmd[0] == "ogr2ogr"
    assert cmd[cmd.index("-t_srs") + 1] == "EPSG:3857"
    assert settings.ogr_pg_connection() in cmd
    # The source table directly follows the PG: datasource.
    assert cmd[cmd.index(settings.ogr_pg_connection()) + 1] == "rbt.water"


def test_spatial_index_disabled_adds_lco(tmp_path: Path, recorded_run) -> None:
    layer = make_layer(ogr=OgrOptions(spatial_index=False))

    export_layer_to_fgb(layer, PROJECTION_3857, Settings(), tmp_path)

    (cmd,) = recorded_run.commands
    assert cmd[cmd.index("-lco") + 1] == "SPATIAL_INDEX=NO"


def test_spatial_index_default_omits_lco(tmp_path: Path, recorded_run) -> None:
    export_layer_to_fgb(make_layer(), PROJECTION_3857, Settings(), tmp_path)

    (cmd,) = recorded_run.commands
    assert "-lco" not in cmd
    assert "SPATIAL_INDEX=NO" not in cmd


def test_skipfailures_present_when_enabled(tmp_path: Path, recorded_run) -> None:
    export_layer_to_fgb(make_layer(), PROJECTION_3857, Settings(), tmp_path)

    (cmd,) = recorded_run.commands
    assert "-skipfailures" in cmd


def test_skipfailures_absent_when_disabled(tmp_path: Path, recorded_run) -> None:
    layer = make_layer(ogr=OgrOptions(skipfailures=False))

    export_layer_to_fgb(layer, PROJECTION_3857, Settings(), tmp_path)

    (cmd,) = recorded_run.commands
    assert "-skipfailures" not in cmd


def test_existing_fgb_skips_export(tmp_path: Path, recorded_run) -> None:
    cached = tmp_path / "water_3857.fgb"
    cached.touch()

    result = export_layer_to_fgb(make_layer(), PROJECTION_3857, Settings(), tmp_path)

    assert result == cached
    assert recorded_run.calls == []


def test_force_unlinks_cached_fgb_and_reexports(tmp_path: Path, recorded_run) -> None:
    cached = tmp_path / "water_3857.fgb"
    cached.write_text("stale export")

    result = export_layer_to_fgb(make_layer(), PROJECTION_3857, Settings(), tmp_path, force=True)

    assert result == cached
    assert len(recorded_run.calls) == 1
    # The stale file was unlinked before dispatch (the recorder never recreates it).
    assert not cached.exists()


def test_exports_via_temp_then_renames(tmp_path: Path, monkeypatch) -> None:
    final = tmp_path / "water_3857.fgb"
    partial = tmp_path / "water_3857.partial.fgb"

    def fake_run(cmd, **kwargs):
        # ogr2ogr writes to the temp path, which must not be the final path.
        out = Path(cmd[cmd.index("-t_srs") + 2])
        assert out == partial
        out.write_text("real export")

    monkeypatch.setattr(exporter_mod, "run_with_retry", fake_run)

    result = export_layer_to_fgb(make_layer(), PROJECTION_3857, Settings(), tmp_path)

    assert result == final
    assert final.read_text() == "real export"
    assert not partial.exists()


def test_failed_export_removes_partial_and_leaves_no_cache(tmp_path: Path, monkeypatch) -> None:
    final = tmp_path / "water_3857.fgb"
    partial = tmp_path / "water_3857.partial.fgb"

    def boom(cmd, **kwargs):
        # A retry attempt wrote a partial file before failing.
        partial.write_text("partial")
        raise CommandFailed(list(cmd), 1)

    monkeypatch.setattr(exporter_mod, "run_with_retry", boom)

    with pytest.raises(CommandFailed):
        export_layer_to_fgb(make_layer(), PROJECTION_3857, Settings(), tmp_path)

    # No partial left behind for a later run to mistake for a valid cache hit.
    assert not partial.exists()
    assert not final.exists()


def test_force_dry_run_keeps_cached_fgb(tmp_path: Path, recorded_run) -> None:
    cached = tmp_path / "water_3857.fgb"
    cached.write_text("stale export")

    result = export_layer_to_fgb(
        make_layer(), PROJECTION_3857, Settings(), tmp_path, force=True, dry_run=True
    )

    assert result == cached
    # Dry run must not delete the cached export nor dispatch a re-export.
    assert cached.exists()
    assert cached.read_text() == "stale export"
    assert recorded_run.calls == []


def test_retry_settings_threaded_to_run_with_retry(tmp_path: Path, recorded_run) -> None:
    settings = Settings(retry_count=7, retry_delay=3)
    log_file = tmp_path / "export.log"

    export_layer_to_fgb(
        make_layer(),
        PROJECTION_3857,
        settings,
        tmp_path,
        dry_run=True,
        log_file=log_file,
    )

    (call,) = recorded_run.calls
    assert call["retries"] == 7
    assert call["delay"] == 3
    assert call["env"] == settings.libpq_env()
    assert call["log_file"] == log_file
    assert call["dry_run"] is True
