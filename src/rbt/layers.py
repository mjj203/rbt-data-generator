"""Loader and data classes for ``config/layers.yml``."""

from __future__ import annotations

from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Any

import yaml

from .paths import config_dir


class LayerRegistryError(ValueError):
    """Raised for a malformed ``config/layers.yml`` (missing/invalid fields).

    Distinct from :class:`KeyError` (used by :meth:`LayerRegistry.layer` for
    "unknown layer key at CLI time") so registry-load-time schema problems and
    runtime lookup misses are never confused with each other.
    """


@dataclass(frozen=True, slots=True)
class Projection:
    code: str
    epsg: str
    output_dir: str
    tile_origin_x: str
    tile_origin_y: str
    tile_dimension_zoom_0: str


@dataclass(frozen=True, slots=True)
class OgrOptions:
    spatial_index: bool = True
    skipfailures: bool = True


@dataclass(frozen=True, slots=True)
class TippecanoeOptions:
    options: tuple[str, ...] = ()
    int_attrs: tuple[str, ...] = ()
    float_attrs: tuple[str, ...] = ()
    bool_attrs: tuple[str, ...] = ()
    string_attrs: tuple[str, ...] = ()
    filter_ref: str | None = None


@dataclass(frozen=True, slots=True)
class Layer:
    key: str
    layer_type: str  # 'cultural' or 'physical'
    source_table: str
    category: str
    layer_name: str
    mbtiles_name: str
    min_zoom: int
    max_zoom: int
    projections: tuple[str, ...]
    ogr: OgrOptions
    tippecanoe: TippecanoeOptions
    btis: bool = False

    def output_basename(self, projection_code: str) -> str:
        return f"{self.mbtiles_name}_{projection_code}"


@dataclass(frozen=True, slots=True)
class SchemaFile:
    """One database schema unit (a PL/pgSQL file dispatched via psql)."""

    key: str
    layer_type: str  # 'cultural' or 'physical'
    sql: str  # path relative to the repository root
    description: str = ""


@dataclass(frozen=True, slots=True)
class MvtSourceTable:
    """One source table feeding the GDAL-MVT (EPSG:4326) backend.

    Zoom-variant views (e.g. ``rbt.highway_z6``) map onto the same
    ``target_name`` with different zoom windows, which is how the GDAL MVT
    driver blends pre-simplified geometry per zoom range.
    """

    source_table: str
    target_name: str
    minzoom: int
    maxzoom: int
    description: str = ""


@dataclass(frozen=True, slots=True)
class MvtDataset:
    """Per-layer-type dataset definition for the GDAL-MVT backend."""

    name: str
    description: str
    groups: dict[str, tuple[MvtSourceTable, ...]]  # category -> tables

    def tables_for(self, categories: list[str] | None = None) -> list[MvtSourceTable]:
        selected = categories if categories else list(self.groups.keys())
        tables: list[MvtSourceTable] = []
        for category in selected:
            tables.extend(self.groups.get(category, ()))
        return tables


@dataclass(frozen=True, slots=True)
class MvtConfig:
    """Settings for the EPSG:4326 GDAL-MVT tile backend."""

    tiling_scheme: str
    max_tile_size: int
    max_features: int
    datasets: dict[str, MvtDataset]  # layer_type -> dataset


@dataclass(frozen=True, slots=True)
class LayerRegistry:
    btp_schema_version: str
    defaults: dict[str, Any]
    filters: dict[str, str]
    projections: dict[str, Projection]
    layers: dict[str, Layer]
    categories: dict[str, dict[str, tuple[str, ...]]]
    gdal_mvt: MvtConfig | None = None
    schemas: dict[str, SchemaFile] = field(default_factory=dict)

    def schemas_for_type(self, layer_type: str) -> list[SchemaFile]:
        return [s for s in self.schemas.values() if s.layer_type == layer_type]

    def layer(self, key: str) -> Layer:
        try:
            return self.layers[key]
        except KeyError as exc:  # pragma: no cover - user-facing CLI error
            raise KeyError(f"Unknown layer '{key}'") from exc

    def layers_for_category(self, layer_type: str, category: str) -> list[Layer]:
        keys = self.categories.get(layer_type, {}).get(category, ())
        return [self.layers[k] for k in keys if k in self.layers]

    def layers_for_type(self, layer_type: str) -> list[Layer]:
        return [layer for layer in self.layers.values() if layer.layer_type == layer_type]

    def filter_for(self, layer: Layer) -> str | None:
        ref = layer.tippecanoe.filter_ref
        if not ref:
            return None
        return self.filters.get(ref)

    def categories_for(self, layer_type: str) -> list[str]:
        return list(self.categories.get(layer_type, {}).keys())


def _require(raw: dict[str, Any], key: str, *, context: str) -> Any:
    try:
        return raw[key]
    except KeyError as exc:
        raise LayerRegistryError(f"{context}: missing required field '{key}'") from exc


def _build_layer(
    key: str, layer_type: str, raw: dict[str, Any], known_projections: set[str]
) -> Layer:
    context = f"layer '{key}' ({layer_type})"
    ogr_raw = raw.get("ogr2ogr", {}) or {}
    tipp_raw = raw.get("tippecanoe", {}) or {}

    projections = tuple(str(p) for p in raw.get("projections", ["3857", "3395", "4326"]))
    unknown_projections = set(projections) - known_projections
    if unknown_projections:
        raise LayerRegistryError(
            f"{context}: references unknown projection(s) {sorted(unknown_projections)} "
            f"— declare them under the 'projections' section first"
        )

    return Layer(
        key=key,
        layer_type=layer_type,
        source_table=_require(raw, "source_table", context=context),
        category=raw.get("category", key),
        layer_name=raw.get("layer_name", key),
        mbtiles_name=raw.get("mbtiles_name", key),
        min_zoom=int(raw.get("min_zoom", 0)),
        max_zoom=int(raw.get("max_zoom", 13)),
        projections=projections,
        ogr=OgrOptions(
            spatial_index=bool(ogr_raw.get("spatial_index", True)),
            skipfailures=bool(ogr_raw.get("skipfailures", True)),
        ),
        tippecanoe=TippecanoeOptions(
            options=tuple(str(o) for o in tipp_raw.get("options", [])),
            int_attrs=tuple(str(a) for a in tipp_raw.get("int_attrs", [])),
            float_attrs=tuple(str(a) for a in tipp_raw.get("float_attrs", [])),
            bool_attrs=tuple(str(a) for a in tipp_raw.get("bool_attrs", [])),
            string_attrs=tuple(str(a) for a in tipp_raw.get("string_attrs", [])),
            filter_ref=tipp_raw.get("filter_ref"),
        ),
        btis=bool(raw.get("btis", False)),
    )


@lru_cache(maxsize=1)
def load_registry(path: Path | None = None) -> LayerRegistry:
    """Parse ``config/layers.yml`` and return a :class:`LayerRegistry`.

    Cached for the lifetime of the process (``lru_cache``); tests pointing at
    a different registry must call ``load_registry.cache_clear()`` (the shared
    ``fake_repo`` fixture does).
    """
    if path is None:
        path = config_dir() / "layers.yml"
    raw = yaml.safe_load(path.read_text(encoding="utf-8"))

    meta = raw.get("meta", {}) or {}
    filters = {k: v.strip() for k, v in (raw.get("filters", {}) or {}).items()}

    projections: dict[str, Projection] = {}
    for code, raw_info in (raw.get("projections", {}) or {}).items():
        info = raw_info or {}
        context = f"projection '{code}'"
        projections[str(code)] = Projection(
            code=str(code),
            epsg=str(_require(info, "epsg", context=context)),
            output_dir=info.get("output_dir", f"tiles_{code}"),
            tile_origin_x=str(info.get("tile_origin_x", "0")),
            tile_origin_y=str(info.get("tile_origin_y", "0")),
            tile_dimension_zoom_0=str(info.get("tile_dimension_zoom_0", "0")),
        )

    known_projections = set(projections.keys())
    layers: dict[str, Layer] = {}
    categories: dict[str, dict[str, tuple[str, ...]]] = {}
    for layer_type in ("cultural", "physical"):
        type_layers = raw.get(layer_type, {}) or {}
        for key, layer_raw in type_layers.items():
            layers[key] = _build_layer(key, layer_type, layer_raw, known_projections)

        type_cats = raw.get("categories", {}).get(layer_type, {}) or {}
        categories[layer_type] = {
            cat: tuple(str(k) for k in keys) for cat, keys in type_cats.items()
        }

    for layer_type, cats in categories.items():
        for category, layer_keys in cats.items():
            dangling = [k for k in layer_keys if k not in layers]
            if dangling:
                raise LayerRegistryError(
                    f"categories.{layer_type}.{category}: references unknown layer "
                    f"key(s) {dangling} — add them under '{layer_type}:' first"
                )

    schemas: dict[str, SchemaFile] = {}
    for key, raw_spec in (raw.get("schemas", {}) or {}).items():
        spec = raw_spec or {}
        context = f"schemas.{key}"
        schemas[str(key)] = SchemaFile(
            key=str(key),
            layer_type=str(_require(spec, "type", context=context)),
            sql=str(_require(spec, "sql", context=context)),
            description=str(spec.get("description", "")),
        )

    return LayerRegistry(
        btp_schema_version=str(meta.get("btp_schema_version", "1.0.0")),
        defaults=meta.get("defaults", {}) or {},
        filters=filters,
        projections=projections,
        layers=layers,
        categories=categories,
        gdal_mvt=_build_mvt_config(raw.get("gdal_mvt")),
        schemas=schemas,
    )


def _build_mvt_source_table(table: str, spec: dict[str, Any], *, context: str) -> MvtSourceTable:
    target = _require(spec, "target", context=context)
    return MvtSourceTable(
        source_table=str(table),
        target_name=str(target),
        minzoom=int(_require(spec, "minzoom", context=context)),
        maxzoom=int(_require(spec, "maxzoom", context=context)),
        description=str(spec.get("description", target)),
    )


def _build_mvt_config(raw: dict[str, Any] | None) -> MvtConfig | None:
    if not raw:
        return None
    datasets: dict[str, MvtDataset] = {}
    for layer_type, ds_raw in (raw.get("datasets", {}) or {}).items():
        groups: dict[str, tuple[MvtSourceTable, ...]] = {}
        for category, tables_raw in (ds_raw.get("groups", {}) or {}).items():
            tables = tuple(
                _build_mvt_source_table(
                    table,
                    spec,
                    context=f"gdal_mvt.datasets.{layer_type}.groups.{category}.{table}",
                )
                for table, spec in (tables_raw or {}).items()
            )
            groups[str(category)] = tables
        datasets[str(layer_type)] = MvtDataset(
            name=str(ds_raw.get("name", layer_type)),
            description=str(ds_raw.get("description", f"{layer_type} vector tiles dataset")),
            groups=groups,
        )
    return MvtConfig(
        tiling_scheme=str(raw.get("tiling_scheme", "EPSG:4326,-180,180,360")),
        max_tile_size=int(raw.get("max_tile_size", 900000)),
        max_features=int(raw.get("max_features", 500000)),
        datasets=datasets,
    )


__all__ = [
    "Layer",
    "LayerRegistry",
    "LayerRegistryError",
    "MvtConfig",
    "MvtDataset",
    "MvtSourceTable",
    "OgrOptions",
    "Projection",
    "SchemaFile",
    "TippecanoeOptions",
    "load_registry",
]
