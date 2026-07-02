"""Tests for the BTIS metadata writer."""

from __future__ import annotations

import sqlite3
from pathlib import Path

import pytest

from rbt.layers import Projection
from rbt.tiles.btis import apply_btis_metadata

PROJECTION_3395 = Projection(
    code="3395",
    epsg="EPSG:3395",
    output_dir="tiles_3395",
    tile_origin_x="-20037508.342789244",
    tile_origin_y="20037508.342789244",
    tile_dimension_zoom_0="40075016.685578488",
)


def read_metadata(path: Path) -> dict[str, str]:
    conn = sqlite3.connect(path)
    try:
        rows = conn.execute("SELECT name, value FROM metadata").fetchall()
    finally:
        conn.close()
    return dict(rows)


def test_writes_btis_rows(mbtiles_factory) -> None:
    path = mbtiles_factory()

    apply_btis_metadata(
        path, PROJECTION_3395, "9.9.9", changelog_url="https://example.com/changelog"
    )

    meta = read_metadata(path)
    assert meta["crs"] == "EPSG:3395"
    assert meta["tile_origin_upper_left_x"] == PROJECTION_3395.tile_origin_x
    assert meta["tile_origin_upper_left_y"] == PROJECTION_3395.tile_origin_y
    assert meta["tile_dimension_zoom_0"] == PROJECTION_3395.tile_dimension_zoom_0
    assert meta["btp_schema_version"] == "9.9.9"
    assert meta["changelog_url"] == "https://example.com/changelog"


def test_changelog_url_defaults_to_empty(mbtiles_factory) -> None:
    path = mbtiles_factory()

    apply_btis_metadata(path, PROJECTION_3395, "1.0.0")

    assert read_metadata(path)["changelog_url"] == ""


def test_deletes_generator_options_and_strategies(mbtiles_factory) -> None:
    path = mbtiles_factory()
    before = read_metadata(path)
    assert "generator_options" in before
    assert "strategies" in before

    apply_btis_metadata(path, PROJECTION_3395, "1.0.0")

    after = read_metadata(path)
    assert "generator_options" not in after
    assert "strategies" not in after
    # Pre-existing rows other than the scrubbed ones survive.
    assert after["name"] == "test"
    assert after["format"] == "pbf"


def test_missing_file_raises(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        apply_btis_metadata(tmp_path / "missing.mbtiles", PROJECTION_3395, "1.0.0")


def test_idempotent_on_second_run(mbtiles_factory) -> None:
    path = mbtiles_factory("idempotent.mbtiles")
    # Real tippecanoe output carries a unique index on metadata.name; it is
    # what makes INSERT OR REPLACE an upsert instead of a plain insert.
    conn = sqlite3.connect(path)
    try:
        conn.execute("CREATE UNIQUE INDEX metadata_name ON metadata(name)")
        conn.commit()
    finally:
        conn.close()

    apply_btis_metadata(path, PROJECTION_3395, "1.0.0")
    apply_btis_metadata(path, PROJECTION_3395, "2.0.0")

    conn = sqlite3.connect(path)
    try:
        duplicates = conn.execute(
            "SELECT name FROM metadata GROUP BY name HAVING COUNT(*) > 1"
        ).fetchall()
    finally:
        conn.close()
    assert duplicates == []
    assert read_metadata(path)["btp_schema_version"] == "2.0.0"
