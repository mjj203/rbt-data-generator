"""Smoke tests for config/layers.yml, plus malformed-YAML validation tests."""

from __future__ import annotations

from pathlib import Path

import pytest

from rbt.layers import LayerRegistryError, load_registry

# Base for every malformed-config test: one valid cultural layer explicitly
# scoped to the one declared projection (3857), a matching category, and one
# schema unit. Deliberately smaller than tests/conftest.py's FAKE_LAYERS_YML
# fixture — only enough to reach the specific validation branch under test.
_BASE = """\
meta:
  btp_schema_version: "1.0.0"

projections:
  3857:
    epsg: "EPSG:3857"

cultural:
  building:
    source_table: rbt.building
    projections: [3857]

categories:
  cultural:
    building: [building]

schemas:
  cultural:
    type: cultural
    sql: setup/data-sources/schemas/cultural/cultural-core.sql
"""


def _load(tmp_path: Path, content: str) -> None:
    load_registry.cache_clear()
    path = tmp_path / "layers.yml"
    path.write_text(content, encoding="utf-8")
    try:
        load_registry(path)
    finally:
        load_registry.cache_clear()


def test_minimal_valid_config_loads(tmp_path: Path) -> None:
    _load(tmp_path, _BASE)


def test_missing_source_table_raises(tmp_path: Path) -> None:
    content = """\
meta:
  btp_schema_version: "1.0.0"
projections:
  3857:
    epsg: "EPSG:3857"
cultural:
  building:
    projections: [3857]
"""
    with pytest.raises(LayerRegistryError, match="missing required field 'source_table'"):
        _load(tmp_path, content)


def test_unknown_projection_reference_raises(tmp_path: Path) -> None:
    content = _BASE.replace("projections: [3857]", "projections: [3857, 9999]")
    with pytest.raises(LayerRegistryError, match="unknown projection"):
        _load(tmp_path, content)


def test_dangling_category_reference_raises(tmp_path: Path) -> None:
    content = _BASE.replace("building: [building]", "building: [building, ghost_layer]")
    with pytest.raises(LayerRegistryError, match="ghost_layer"):
        _load(tmp_path, content)


def test_schema_missing_sql_field_raises(tmp_path: Path) -> None:
    content = _BASE.replace("    sql: setup/data-sources/schemas/cultural/cultural-core.sql\n", "")
    with pytest.raises(LayerRegistryError, match="missing required field 'sql'"):
        _load(tmp_path, content)


def test_gdal_mvt_missing_target_raises(tmp_path: Path) -> None:
    content = (
        _BASE
        + """
gdal_mvt:
  datasets:
    cultural:
      groups:
        building:
          rbt.building: {minzoom: 10, maxzoom: 13}
"""
    )
    with pytest.raises(LayerRegistryError, match="missing required field 'target'"):
        _load(tmp_path, content)


def test_gdal_mvt_missing_zoom_raises(tmp_path: Path) -> None:
    content = (
        _BASE
        + """
gdal_mvt:
  datasets:
    cultural:
      groups:
        building:
          rbt.building: {target: building, maxzoom: 13}
"""
    )
    with pytest.raises(LayerRegistryError, match="missing required field 'minzoom'"):
        _load(tmp_path, content)


def test_registry_loads() -> None:
    registry = load_registry()
    assert registry.btp_schema_version
    assert "3857" in registry.projections
    assert "3395" in registry.projections
    assert "4326" in registry.projections


def test_known_layer_keys_exist() -> None:
    registry = load_registry()
    for expected in ("building", "highway", "water", "waterway", "landcover"):
        assert expected in registry.layers, f"missing layer {expected!r}"


def test_category_membership() -> None:
    registry = load_registry()
    cultural = registry.categories.get("cultural", {})
    assert "building" in cultural["building"]
    assert "highway" in cultural["transportation"]
    assert "railway" in cultural["transportation"]


def test_filters_reachable() -> None:
    registry = load_registry()
    building = registry.layer("building")
    assert registry.filter_for(building) is not None


def test_physical_layer_projections() -> None:
    registry = load_registry()
    contour = registry.layer("contour")
    assert "4326" not in contour.projections
    assert "3857" in contour.projections


def test_every_layer_has_source_table() -> None:
    registry = load_registry()
    for layer in registry.layers.values():
        assert layer.source_table.startswith("rbt."), (
            f"{layer.key} source_table does not live in rbt schema: {layer.source_table}"
        )
