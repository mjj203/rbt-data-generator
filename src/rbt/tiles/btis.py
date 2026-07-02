"""Batched BTIS metadata writer for MBTiles files.

The legacy Bash generators open ``sqlite3`` seven times to mutate metadata.
This helper does it in a single transaction.
"""

from __future__ import annotations

import contextlib
import sqlite3
from pathlib import Path

from ..layers import Projection
from ..logging import get_logger

log = get_logger(__name__)


def apply_btis_metadata(
    mbtiles: Path,
    projection: Projection,
    btp_schema_version: str,
    *,
    changelog_url: str = "",
) -> None:
    if not mbtiles.is_file():
        raise FileNotFoundError(f"MBTiles not found: {mbtiles}")

    log.info(
        "Applying BTIS metadata (CRS %s, BTP %s) to %s",
        projection.epsg,
        btp_schema_version,
        mbtiles.name,
    )

    # contextlib.closing: sqlite3's context manager commits but never closes.
    with contextlib.closing(sqlite3.connect(mbtiles)) as conn:
        conn.execute("BEGIN TRANSACTION")
        for name, value in (
            ("crs", projection.epsg),
            ("tile_origin_upper_left_x", projection.tile_origin_x),
            ("tile_origin_upper_left_y", projection.tile_origin_y),
            ("tile_dimension_zoom_0", projection.tile_dimension_zoom_0),
            ("btp_schema_version", btp_schema_version),
            ("changelog_url", changelog_url),
        ):
            conn.execute(
                "INSERT OR REPLACE INTO metadata(name, value) VALUES(?, ?)",
                (name, value),
            )
        conn.execute("DELETE FROM metadata WHERE name = 'generator_options'")
        conn.execute("DELETE FROM metadata WHERE name = 'strategies'")
        conn.execute("COMMIT")


__all__ = ["apply_btis_metadata"]
