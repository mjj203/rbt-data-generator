"""Shared fixtures for the rbt test suite."""

from __future__ import annotations

import os
import sqlite3
import subprocess
from pathlib import Path
from typing import cast

import pytest

import rbt.process
import rbt.schema
import rbt.tiles.exporter
import rbt.tiles.gdal_mvt
import rbt.tiles.tile_join
import rbt.tiles.tippecanoe
from rbt import layers, paths

# Minimal but representative registry: two tippecanoe layers (one per type),
# one filter, a schemas block, and a gdal_mvt dataset with a zoom-variant
# blend — enough to exercise every dispatch path without the real 600-line file.
FAKE_LAYERS_YML = """\
meta:
  btp_schema_version: "9.9.9"
  defaults:
    tippecanoe_options: [--no-progress-indicator]

filters:
  water_filter: |
    {"*":["any",["all",[">=","$zoom",1]]]}

cultural:
  building:
    category: building
    source_table: rbt.building
    min_zoom: 10
    tippecanoe:
      options: [-pk]
      float_attrs: [height]

physical:
  water:
    category: water
    source_table: rbt.water
    min_zoom: 0
    tippecanoe:
      options: [--drop-smallest-as-needed]
      filter_ref: water_filter
  waterway:
    category: waterway
    source_table: rbt.waterway
    projections: [3857, 3395]
    min_zoom: 6

categories:
  cultural:
    building: [building]
  physical:
    water: [water]
    waterway: [waterway]

schemas:
  physical:
    type: physical
    sql: setup/data-sources/schemas/physical/physical-core.sql
    description: Core physical views
  cultural:
    type: cultural
    sql: setup/data-sources/schemas/cultural/cultural-core.sql
    description: Core cultural views

gdal_mvt:
  tiling_scheme: "EPSG:4326,-180,180,360"
  max_tile_size: 900000
  max_features: 500000
  datasets:
    physical:
      name: physical
      description: Physical vector tiles dataset
      groups:
        water:
          rbt.water_simplified: {target: water, minzoom: 0, maxzoom: 9}
          rbt.water: {target: water, minzoom: 10, maxzoom: 13}
    cultural:
      name: cultural
      description: Cultural vector tiles dataset
      groups:
        building:
          rbt.building_z10: {target: building, minzoom: 10, maxzoom: 13}
          rbt.building: {target: building, minzoom: 13, maxzoom: 13}

projections:
  3857:
    epsg: "EPSG:3857"
  3395:
    epsg: "EPSG:3395"
  4326:
    epsg: "EPSG:4326"
"""

FAKE_RBT_CONF = """\
MAX_PARALLEL_JOBS=${MAX_PARALLEL_JOBS:-2}
RETRY_COUNT=${RETRY_COUNT:-2}
RETRY_DELAY=${RETRY_DELAY:-1}
LOG_LEVEL=${LOG_LEVEL:-INFO}
DATABASE_HOST=${PG_HOST:-localhost}
DATABASE_PORT=${PG_PORT:-5432}
DATABASE_NAME=${PG_DATABASE:-rbt}
DATABASE_USER=${PG_USR:-postgres}
DATABASE_PASSWORD=${PG_PASS:-}
"""

# Mirrors the committed setup/data-sources/osm/imposm-config.json: replication
# settings only — `rbt osm run` merges connection/mapping/dirs at runtime.
FAKE_IMPOSM_CONFIG = """\
{
    "replication_url": "https://planet.openstreetmap.org/replication/day/",
    "replication_interval": "24h",
    "diff_state_before": "24h"
}
"""

_SCRUBBED_ENV_PREFIXES = ("PG", "DATABASE_", "RBT_", "OSM_", "TILE_", "SHARED_")


@pytest.fixture(autouse=True)
def _clean_env_and_caches(monkeypatch):
    """Scrub connection env vars and reset process-lifetime caches.

    ``paths.project_root`` and ``layers.load_registry`` are ``lru_cache``d, so
    every test starts from a cold cache and a clean environment.
    """
    for key in list(os.environ):
        if key.startswith(_SCRUBBED_ENV_PREFIXES):
            monkeypatch.delenv(key, raising=False)
    paths.project_root.cache_clear()
    layers.load_registry.cache_clear()
    yield
    paths.project_root.cache_clear()
    layers.load_registry.cache_clear()


@pytest.fixture
def fake_repo(tmp_path: Path, monkeypatch) -> Path:
    """A throwaway project root with minimal rbt.conf + layers.yml.

    Points ``RBT_PROJECT_ROOT`` at it so ``load_settings``/``load_registry``
    resolve against the fixture instead of the real repository.
    """
    (tmp_path / "config").mkdir()
    (tmp_path / "config" / "rbt.conf").write_text(FAKE_RBT_CONF, encoding="utf-8")
    (tmp_path / "config" / "layers.yml").write_text(FAKE_LAYERS_YML, encoding="utf-8")
    for rel in (
        "setup/data-sources/schemas/physical",
        "setup/data-sources/schemas/cultural",
        "setup/data-sources/osm",
        "output/logs",
        "output/tiles",
    ):
        (tmp_path / rel).mkdir(parents=True)
    (tmp_path / "setup/data-sources/schemas/physical/physical-core.sql").write_text(
        "SELECT 1;\n", encoding="utf-8"
    )
    (tmp_path / "setup/data-sources/schemas/cultural/cultural-core.sql").write_text(
        "SELECT 1;\n", encoding="utf-8"
    )
    (tmp_path / "setup/data-sources/osm/imposm-config.json").write_text(
        FAKE_IMPOSM_CONFIG, encoding="utf-8"
    )
    monkeypatch.setenv("RBT_PROJECT_ROOT", str(tmp_path))
    paths.project_root.cache_clear()
    layers.load_registry.cache_clear()
    return tmp_path


class RecordedRun:
    """Captures every command dispatched through ``rbt.process``."""

    def __init__(self) -> None:
        self.calls: list[dict[str, object]] = []

    def __call__(self, cmd, **kwargs):
        self.calls.append({"cmd": list(cmd), **kwargs})
        return subprocess.CompletedProcess(list(cmd), 0, "", "")

    @property
    def commands(self) -> list[list[str]]:
        return [cast("list[str]", call["cmd"]) for call in self.calls]


@pytest.fixture
def recorded_run(monkeypatch) -> RecordedRun:
    """Replace ``process.run``/``run_with_retry`` (and module-level imports of
    them) with a recorder so command construction can be asserted without
    executing anything."""
    recorder = RecordedRun()
    monkeypatch.setattr(rbt.process, "run", recorder)
    monkeypatch.setattr(rbt.process, "run_with_retry", recorder)
    # Modules import these names at import time; patch their local bindings.
    monkeypatch.setattr(rbt.tiles.exporter, "run_with_retry", recorder)
    monkeypatch.setattr(rbt.tiles.tippecanoe, "run", recorder)
    monkeypatch.setattr(rbt.tiles.tile_join, "run", recorder, raising=False)
    monkeypatch.setattr(rbt.tiles.gdal_mvt, "run", recorder)
    monkeypatch.setattr(rbt.schema, "run", recorder)
    return recorder


@pytest.fixture
def mbtiles_factory(tmp_path: Path):
    """Create real sqlite MBTiles files with a populated metadata table."""

    def factory(name: str = "test.mbtiles", metadata: dict[str, str] | None = None) -> Path:
        path = tmp_path / name
        conn = sqlite3.connect(path)
        try:
            conn.execute("CREATE TABLE metadata (name TEXT, value TEXT)")
            conn.execute(
                "CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER,"
                " tile_row INTEGER, tile_data BLOB)"
            )
            rows = {
                "name": "test",
                "format": "pbf",
                "generator_options": "should-be-removed",
                "strategies": "should-be-removed",
                **(metadata or {}),
            }
            conn.executemany("INSERT INTO metadata (name, value) VALUES (?, ?)", rows.items())
            conn.commit()
        finally:
            conn.close()
        return path

    return factory
