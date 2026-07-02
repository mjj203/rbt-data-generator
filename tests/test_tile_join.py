"""Tests for tile-join command construction."""

from __future__ import annotations

from pathlib import Path

import pytest

from rbt.tiles.tile_join import join_layers


def test_empty_inputs_raise(tmp_path: Path, recorded_run) -> None:
    with pytest.raises(ValueError, match="No MBTiles"):
        join_layers([], tmp_path / "merged.mbtiles")
    assert recorded_run.calls == []


def test_all_nonexistent_inputs_raise(tmp_path: Path, recorded_run) -> None:
    inputs = [tmp_path / "a.mbtiles", tmp_path / "b.mbtiles"]

    with pytest.raises(ValueError, match="No MBTiles"):
        join_layers(inputs, tmp_path / "merged.mbtiles")
    assert recorded_run.calls == []


def test_nonexistent_paths_filtered_out(tmp_path: Path, recorded_run) -> None:
    first = tmp_path / "water_3857.mbtiles"
    second = tmp_path / "waterway_3857.mbtiles"
    first.touch()
    second.touch()
    missing = tmp_path / "missing.mbtiles"
    output = tmp_path / "merged" / "physical_3857.mbtiles"

    result = join_layers([first, missing, second], output)

    assert result == output
    (cmd,) = recorded_run.commands
    assert cmd == ["tile-join", "-f", "-pk", "-o", str(output), str(first), str(second)]
    # The output's parent directory is created up front.
    assert output.parent.is_dir()


def test_argv_shape(tmp_path: Path, recorded_run) -> None:
    inputs = [tmp_path / "a.mbtiles", tmp_path / "b.mbtiles", tmp_path / "c.mbtiles"]
    for path in inputs:
        path.touch()
    output = tmp_path / "out.mbtiles"

    join_layers(inputs, output)

    (cmd,) = recorded_run.commands
    assert cmd == ["tile-join", "-f", "-pk", "-o", str(output), *[str(p) for p in inputs]]
