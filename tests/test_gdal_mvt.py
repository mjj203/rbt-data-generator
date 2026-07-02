"""Tests for the EPSG:4326 GDAL-MVT backend."""

from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path

import pytest

import rbt.tiles.gdal_mvt as gdal_mvt_mod
from rbt.config import load_settings
from rbt.layers import MvtSourceTable, load_registry
from rbt.tiles.gdal_mvt import (
    build_conf_json,
    build_ogr_mvt_command,
    generate_mvt_dataset,
    write_metadata,
)


def option_values(cmd: list[str], flag: str) -> list[str]:
    return [cmd[i + 1] for i, token in enumerate(cmd) if token == flag]


# ---------------------------------------------------------------- build_conf_json


def test_build_conf_json_maps_source_tables() -> None:
    tables = [
        MvtSourceTable("rbt.water_simplified", "water", 0, 9, "simplified water"),
        MvtSourceTable("rbt.water", "water", 10, 13),
    ]

    conf = json.loads(build_conf_json(tables))

    assert conf == {
        "rbt.water_simplified": {
            "target_name": "water",
            "description": "simplified water",
            "minzoom": 0,
            "maxzoom": 9,
        },
        "rbt.water": {
            "target_name": "water",
            # Empty description falls back to the target name.
            "description": "water",
            "minzoom": 10,
            "maxzoom": 13,
        },
    }


# ---------------------------------------------------------------- build_ogr_mvt_command


def test_build_ogr_mvt_command_flags(fake_repo: Path, tmp_path: Path) -> None:
    settings = load_settings()
    registry = load_registry()
    mvt = registry.gdal_mvt
    assert mvt is not None
    dataset = mvt.datasets["physical"]
    tables = dataset.tables_for(["water"])
    output_dir = tmp_path / "physical_tiles"

    cmd = build_ogr_mvt_command(dataset, tables, mvt, settings, output_dir)

    assert cmd[0] == "ogr2ogr"
    assert option_values(cmd, "-f") == ["MVT"]
    assert option_values(cmd, "-t_srs") == ["EPSG:4326"]
    assert str(output_dir) in cmd
    assert settings.ogr_pg_connection() in cmd

    open_options = option_values(cmd, "-oo")
    assert "ACTIVE_SCHEMA=rbt" in open_options
    assert "SCHEMAS=rbt" in open_options
    # Comma list preserves registry order.
    assert "TABLES=rbt.water_simplified,rbt.water" in open_options

    dsco = option_values(cmd, "-dsco")
    conf_entries = [value for value in dsco if value.startswith("CONF=")]
    assert len(conf_entries) == 1
    conf = json.loads(conf_entries[0][len("CONF=") :])
    assert set(conf) == {"rbt.water_simplified", "rbt.water"}
    assert f"MINZOOM={settings.tile_min_zoom}" in dsco
    assert f"MAXZOOM={settings.tile_max_zoom}" in dsco
    assert "MAX_SIZE=900000" in dsco
    assert "MAX_FEATURES=500000" in dsco
    assert "TILING_SCHEME=EPSG:4326,-180,180,360" in dsco
    assert "-skipfailures" in cmd
    assert "-progress" in cmd


# ---------------------------------------------------------------- write_metadata


def test_write_metadata_contents(fake_repo: Path, tmp_path: Path) -> None:
    settings = load_settings()
    registry = load_registry()
    mvt = registry.gdal_mvt
    assert mvt is not None
    dataset = mvt.datasets["physical"]
    categories = ["water"]
    tables = dataset.tables_for(categories)
    output_dir = tmp_path / "physical_tiles"
    output_dir.mkdir()

    path = write_metadata(dataset, categories, tables, mvt, settings, output_dir)

    assert path == output_dir / "metadata.json"
    metadata = json.loads(path.read_text(encoding="utf-8"))
    assert metadata["name"] == "physical"
    assert metadata["selected_layers"] == ["water"]
    assert metadata["categories"] == {"water": ["water"]}
    assert metadata["tables_processed"] == ["rbt.water_simplified", "rbt.water"]
    assert metadata["layer_count"] == 2
    assert metadata["projection"] == "EPSG:4326"
    assert metadata["tiling_scheme"] == "EPSG:4326,-180,180,360"
    # ISO UTC stamp.
    datetime.strptime(metadata["created"], "%Y-%m-%dT%H:%M:%SZ")  # noqa: DTZ007


# ---------------------------------------------------------------- generate_mvt_dataset


def test_generate_unknown_layer_type_raises_key_error(
    fake_repo: Path, recorded_run, tmp_path: Path
) -> None:
    with pytest.raises(KeyError, match="bogus"):
        generate_mvt_dataset("bogus", load_settings(), load_registry(), tmp_path)
    assert recorded_run.calls == []


def test_generate_unmatched_categories_raise_value_error(
    fake_repo: Path, recorded_run, tmp_path: Path
) -> None:
    with pytest.raises(ValueError, match="None of the requested categories"):
        generate_mvt_dataset(
            "physical",
            load_settings(),
            load_registry(),
            tmp_path,
            categories=["nope"],
        )
    assert recorded_run.calls == []


def test_generate_removes_stale_tile_dir(
    fake_repo: Path, recorded_run, monkeypatch, tmp_path: Path
) -> None:
    output_root = tmp_path / "4326"
    tile_dir = output_root / "physical_tiles"
    tile_dir.mkdir(parents=True)
    sentinel = tile_dir / "stale.pbf"
    sentinel.write_text("old tiles")

    # The real ogr2ogr -f MVT run creates the tile directory; emulate that on
    # top of the recorder so write_metadata has somewhere to land.
    def run_and_mkdir(cmd, **kwargs):
        result = recorded_run(cmd, **kwargs)
        tile_dir.mkdir(parents=True, exist_ok=True)
        return result

    monkeypatch.setattr(gdal_mvt_mod, "run", run_and_mkdir)
    settings = load_settings()

    result = generate_mvt_dataset("physical", settings, load_registry(), output_root)

    assert result == tile_dir
    assert not sentinel.exists()
    assert (tile_dir / "metadata.json").is_file()
    (call,) = recorded_run.calls
    assert call["cmd"][0] == "ogr2ogr"
    assert call["env"] == settings.libpq_env()
    assert call["dry_run"] is False


def test_generate_dry_run_skips_metadata_and_cleanup(
    fake_repo: Path, recorded_run, tmp_path: Path
) -> None:
    output_root = tmp_path / "4326"
    tile_dir = output_root / "physical_tiles"
    tile_dir.mkdir(parents=True)
    sentinel = tile_dir / "stale.pbf"
    sentinel.write_text("old tiles")

    result = generate_mvt_dataset(
        "physical", load_settings(), load_registry(), output_root, dry_run=True
    )

    assert result == tile_dir
    # Dry run leaves the previous tree alone and writes no metadata.
    assert sentinel.exists()
    assert not (tile_dir / "metadata.json").exists()
    (call,) = recorded_run.calls
    assert call["dry_run"] is True
