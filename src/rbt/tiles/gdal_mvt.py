"""GDAL-MVT tile backend for EPSG:4326.

The 4326 pipeline does not use tippecanoe. GDAL's MVT driver cuts the tiles
directly from PostGIS in a single multi-table ``ogr2ogr -f MVT`` invocation,
using a CONF json that maps each source table to a target MVT layer with a
per-table zoom window. This module is the Python replacement for
the retired bash 4326 generators.

Output is a tile *directory* (``{z}/{x}/{y}.pbf`` plus ``metadata.json``),
not an MBTiles file.
"""

from __future__ import annotations

import json
import shutil
from datetime import UTC, datetime
from pathlib import Path

from ..config import Settings
from ..layers import LayerRegistry, MvtConfig, MvtDataset, MvtSourceTable
from ..logging import get_logger
from ..process import run

log = get_logger(__name__)

# The MVT driver reads from the ``rbt`` schema; source tables are fully
# qualified (``rbt.water``) and ACTIVE_SCHEMA/SCHEMAS pin the search path.
_ACTIVE_SCHEMA = "rbt"


def build_conf_json(tables: list[MvtSourceTable]) -> str:
    """Render the ``-dsco CONF=`` json for the selected source tables."""
    conf = {
        table.source_table: {
            "target_name": table.target_name,
            "description": table.description or table.target_name,
            "minzoom": table.minzoom,
            "maxzoom": table.maxzoom,
        }
        for table in tables
    }
    return json.dumps(conf)


def build_ogr_mvt_command(
    dataset: MvtDataset,
    tables: list[MvtSourceTable],
    mvt: MvtConfig,
    settings: Settings,
    output_dir: Path,
) -> list[str]:
    """Build the single multi-table ``ogr2ogr -f MVT`` command."""
    table_list = ",".join(t.source_table for t in tables)
    return [
        "ogr2ogr",
        "-f",
        "MVT",
        "-t_srs",
        "EPSG:4326",
        str(output_dir),
        settings.ogr_pg_connection(),
        "-oo",
        f"ACTIVE_SCHEMA={_ACTIVE_SCHEMA}",
        "-oo",
        f"SCHEMAS={_ACTIVE_SCHEMA}",
        "-oo",
        f"TABLES={table_list}",
        "-dsco",
        f"NAME={dataset.name}",
        "-dsco",
        f"DESCRIPTION={dataset.description}",
        "-dsco",
        "FORMAT=DIRECTORY",
        "-dsco",
        f"CONF={build_conf_json(tables)}",
        "-dsco",
        f"MINZOOM={settings.tile_min_zoom}",
        "-dsco",
        f"MAXZOOM={settings.tile_max_zoom}",
        "-dsco",
        f"MAX_SIZE={mvt.max_tile_size}",
        "-dsco",
        f"MAX_FEATURES={mvt.max_features}",
        "-dsco",
        f"TILING_SCHEME={mvt.tiling_scheme}",
        "-skipfailures",
        "-progress",
    ]


def write_metadata(
    dataset: MvtDataset,
    categories: list[str],
    tables: list[MvtSourceTable],
    mvt: MvtConfig,
    settings: Settings,
    output_dir: Path,
) -> Path:
    """Write ``metadata.json`` alongside the tile directory.

    ``categories`` maps each selected group to the target layers it produced
    (the bash scripts hardcoded a per-dataset grouping; deriving it from the
    registry keeps the file accurate for any selection).
    """
    category_layers: dict[str, list[str]] = {}
    for category in categories:
        targets = sorted({t.target_name for t in dataset.groups.get(category, ())})
        if targets:
            category_layers[category] = targets

    metadata = {
        "name": dataset.name,
        "description": dataset.description,
        "version": "1.0",
        "minzoom": settings.tile_min_zoom,
        "maxzoom": settings.tile_max_zoom,
        "format": "pbf",
        "type": "baselayer",
        "attribution": "Generated from PostgreSQL RBT schema",
        "created": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "projection": "EPSG:4326",
        "tiling_scheme": mvt.tiling_scheme,
        "selected_layers": categories,
        "layer_count": len(tables),
        "categories": category_layers,
        "tables_processed": [t.source_table for t in tables],
    }
    path = output_dir / "metadata.json"
    path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    log.info("metadata written: %s", path)
    return path


def generate_mvt_dataset(
    layer_type: str,
    settings: Settings,
    registry: LayerRegistry,
    output_root: Path,
    *,
    categories: list[str] | None = None,
    dry_run: bool = False,
    log_file: Path | None = None,
) -> Path:
    """Generate the EPSG:4326 tile directory for *layer_type*.

    Returns the tile directory path (``<output_root>/<dataset>_tiles``).
    Raises ``KeyError`` if the registry has no GDAL-MVT dataset for the type
    and ``ValueError`` if the selection matches no tables.
    """
    mvt = registry.gdal_mvt
    if mvt is None or layer_type not in mvt.datasets:
        raise KeyError(f"No gdal_mvt dataset for layer type {layer_type!r} in config/layers.yml")
    dataset = mvt.datasets[layer_type]

    selected_categories = [c for c in (categories or []) if c in dataset.groups]
    if categories and not selected_categories:
        raise ValueError(
            f"None of the requested categories {categories!r} exist in the "
            f"{layer_type} gdal_mvt dataset (available: {sorted(dataset.groups)})"
        )
    effective = selected_categories or list(dataset.groups.keys())
    tables = dataset.tables_for(effective)
    if not tables:
        raise ValueError(f"No source tables selected for {layer_type} 4326 generation")

    tile_dir = output_root / f"{dataset.name}_tiles"
    if tile_dir.exists() and not dry_run:
        # The MVT driver writes a complete directory per run; stale trees from
        # a previous run would mix old and new tiles.
        log.info("removing previous tile directory %s", tile_dir)
        shutil.rmtree(tile_dir)
    output_root.mkdir(parents=True, exist_ok=True)

    cmd = build_ogr_mvt_command(dataset, tables, mvt, settings, tile_dir)
    log.info(
        "generating EPSG:4326 %s tiles (%d tables, %d groups) → %s",
        layer_type,
        len(tables),
        len(effective),
        tile_dir,
    )
    run(cmd, env=settings.libpq_env(), log_file=log_file, dry_run=dry_run)

    if not dry_run:
        write_metadata(dataset, effective, tables, mvt, settings, tile_dir)
    return tile_dir


__all__ = [
    "build_conf_json",
    "build_ogr_mvt_command",
    "generate_mvt_dataset",
    "write_metadata",
]
