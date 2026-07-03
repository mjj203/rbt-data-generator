"""CLI tests for ``rbt tiles`` dispatch and read-only logging behaviour."""

from __future__ import annotations

from pathlib import Path

import pytest
from typer.testing import CliRunner

from rbt.cli import app

runner = CliRunner()


@pytest.fixture
def tile_repo(fake_repo: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """fake_repo with the tippecanoe temp dir redirected inside the fixture."""
    monkeypatch.setenv("TILE_TEMP_DIR", str(fake_repo / "output" / "tile-temp"))
    return fake_repo


def _commands_for(recorded_run, executable: str) -> list[list[str]]:
    return [cmd for cmd in recorded_run.commands if cmd[0] == executable]


def test_tiles_water_3857_dry_run(tile_repo: Path, recorded_run) -> None:
    result = runner.invoke(
        app,
        [
            "--no-log-file",
            "tiles",
            "--layer-type",
            "physical",
            "--projection",
            "3857",
            "--water",
            "--dry-run",
        ],
    )
    assert result.exit_code == 0, result.output

    ogr_cmds = _commands_for(recorded_run, "ogr2ogr")
    tip_cmds = _commands_for(recorded_run, "tippecanoe")
    assert len(ogr_cmds) == 1
    assert len(tip_cmds) == 1

    assert "rbt.water" in ogr_cmds[0]
    assert "-t_srs" in ogr_cmds[0]
    assert "EPSG:3857" in ogr_cmds[0]

    # tippecanoe consumes the exported water FlatGeoBuf for this projection.
    assert any("water_3857.fgb" in part for part in tip_cmds[0])
    assert "water" in tip_cmds[0]  # -l layer name

    assert all(call["dry_run"] is True for call in recorded_run.calls)


def test_tiles_all_expands_types_and_projections(tile_repo: Path, recorded_run) -> None:
    result = runner.invoke(app, ["--no-log-file", "tiles", "--all", "--no-tile-join", "--dry-run"])
    assert result.exit_code == 0, result.output

    joined = [" ".join(cmd) for cmd in recorded_run.commands]
    # Both layer types are expanded…
    assert any("rbt.water" in cmd for cmd in joined)
    assert any("rbt.waterway" in cmd for cmd in joined)
    assert any("rbt.building" in cmd for cmd in joined)

    # …across all projections: 3857+3395 run tippecanoe per layer (water,
    # waterway, building × 2 projections), 4326 runs one GDAL-MVT export per
    # dataset and never invokes tippecanoe.
    tip_cmds = _commands_for(recorded_run, "tippecanoe")
    assert len(tip_cmds) == 6
    mvt_cmds = [cmd for cmd in recorded_run.commands if cmd[:3] == ["ogr2ogr", "-f", "MVT"]]
    assert len(mvt_cmds) == 2
    assert not any("4326" in part for cmd in tip_cmds for part in cmd)


def test_tiles_specific_layer_option(tile_repo: Path, recorded_run) -> None:
    result = runner.invoke(
        app,
        [
            "--no-log-file",
            "tiles",
            "--layer-type",
            "physical",
            "--projection",
            "3857",
            "--layer",
            "water",
            "--dry-run",
        ],
    )
    assert result.exit_code == 0, result.output

    ogr_cmds = _commands_for(recorded_run, "ogr2ogr")
    assert len(ogr_cmds) == 1
    assert "rbt.water" in ogr_cmds[0]
    assert not any("rbt.waterway" in " ".join(cmd) for cmd in recorded_run.commands)


def test_tiles_layer_subcommand(tile_repo: Path, recorded_run) -> None:
    result = runner.invoke(
        app,
        ["--no-log-file", "tiles", "layer", "water", "--projection", "3857", "--dry-run"],
    )
    assert result.exit_code == 0, result.output

    ogr_cmds = _commands_for(recorded_run, "ogr2ogr")
    assert len(ogr_cmds) == 1
    assert "rbt.water" in ogr_cmds[0]
    assert len(_commands_for(recorded_run, "tippecanoe")) == 1


def test_tiles_unknown_layer_errors(tile_repo: Path, recorded_run) -> None:
    result = runner.invoke(
        app,
        ["--no-log-file", "tiles", "--layer", "not-a-layer", "--dry-run"],
    )
    assert result.exit_code != 0
    assert isinstance(result.exception, KeyError)
    assert recorded_run.calls == []


def test_all_combined_with_category_is_rejected(tile_repo: Path, recorded_run) -> None:
    result = runner.invoke(
        app,
        ["--no-log-file", "tiles", "--all", "--water", "--dry-run"],
    )
    assert result.exit_code != 0
    assert "--all" in result.output
    # Must not silently fall through to generating every layer.
    assert recorded_run.calls == []


def test_read_only_commands_do_not_create_log_files(fake_repo: Path) -> None:
    logs_dir = fake_repo / "output" / "logs"

    result = runner.invoke(app, ["layers", "list"])
    assert result.exit_code == 0, result.output

    result = runner.invoke(app, ["schema", "list"])
    assert result.exit_code == 0, result.output

    assert list(logs_dir.iterdir()) == []
