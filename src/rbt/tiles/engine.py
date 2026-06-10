"""High-level tile generation engine.

Reads the layer registry at ``config/layers.yml`` and dispatches the right
backend per projection:

- **EPSG:3857 / EPSG:3395** — ogr2ogr → FlatGeoBuf → tippecanoe → MBTiles
  (replaces ``production/tile-generation/*/generate-*-3857-3395.sh``).
- **EPSG:4326** — GDAL's MVT driver writes a tile directory in one
  multi-table ogr2ogr call (replaces ``generate-*-4326.sh``); tippecanoe is
  not involved and tile-join/BTIS do not apply.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from ..config import Settings
from ..layers import Layer, LayerRegistry, Projection, load_registry
from ..logging import get_logger
from .btis import apply_btis_metadata
from .exporter import export_layer_to_fgb
from .gdal_mvt import generate_mvt_dataset
from .tile_join import join_layers
from .tippecanoe import run_tippecanoe

log = get_logger(__name__)


@dataclass(slots=True)
class TileJob:
    layer_type: str
    projection: Projection
    layers: list[Layer]
    output_dir: Path
    tile_join: bool = True
    add_btis: bool = True
    # Explicit category selection (None = everything). Used by the EPSG:4326
    # GDAL-MVT backend, whose table groups are keyed by category rather than
    # by Layer objects.
    categories: list[str] | None = None


@dataclass(slots=True)
class TileResult:
    layer: Layer | None
    projection: Projection
    output: Path
    fgb: Path | None = None
    kind: str = "mbtiles"  # 'mbtiles' or 'directory'
    skipped: bool = False

    @property
    def mbtiles(self) -> Path:
        """Backwards-compatible alias for the output path."""
        return self.output


@dataclass(slots=True)
class TileEngine:
    settings: Settings
    registry: LayerRegistry = field(default_factory=load_registry)
    dry_run: bool = False
    force: bool = False

    def output_dir_for(self, layer_type: str, projection: Projection) -> Path:
        root = self.settings.tile_cache_dir
        return root / layer_type / projection.code

    def resolve_layers(
        self,
        layer_type: str,
        *,
        categories: list[str] | None = None,
        layer_keys: list[str] | None = None,
    ) -> list[Layer]:
        if not categories and not layer_keys:
            return self.registry.layers_for_type(layer_type)

        selected: dict[str, Layer] = {}
        for cat in categories or []:
            for layer in self.registry.layers_for_category(layer_type, cat):
                selected[layer.key] = layer
        for key in layer_keys or []:
            layer = self.registry.layer(key)
            if layer.layer_type != layer_type:
                log.warning(
                    "layer %r is type %r, skipping under --layer-type %r",
                    key,
                    layer.layer_type,
                    layer_type,
                )
                continue
            selected[layer.key] = layer
        return list(selected.values())

    def generate(self, job: TileJob) -> list[TileResult]:
        if job.projection.code == "4326":
            return self._generate_gdal_mvt(job)

        results: list[TileResult] = []
        job.output_dir.mkdir(parents=True, exist_ok=True)

        for layer in job.layers:
            if job.projection.code not in layer.projections:
                log.info(
                    "skipping %s: not configured for EPSG:%s",
                    layer.key,
                    job.projection.code,
                )
                continue
            results.append(self._generate_single(layer, job.projection, job.output_dir))

        if job.tile_join and len(results) > 1:
            merged = job.output_dir / f"{job.layer_type}_{job.projection.code}.mbtiles"
            join_layers(
                (r.output for r in results),
                merged,
                dry_run=self.dry_run,
                log_file=job.output_dir / f"merge_{job.projection.code}.log",
            )
            if job.add_btis and not self.dry_run:
                apply_btis_metadata(
                    merged, job.projection, self.registry.btp_schema_version
                )
        elif job.add_btis and len(results) == 1 and not self.dry_run:
            apply_btis_metadata(
                results[0].output,
                job.projection,
                self.registry.btp_schema_version,
            )

        return results

    def _generate_gdal_mvt(self, job: TileJob) -> list[TileResult]:
        """EPSG:4326 backend — one tile directory per dataset, no tippecanoe."""
        categories = job.categories
        if categories is None and job.layers:
            # A specific layer selection (e.g. --layer water) narrows the
            # dataset to those layers' categories.
            selected = {layer.category for layer in job.layers}
            all_layers = {
                layer.key for layer in self.registry.layers_for_type(job.layer_type)
            }
            if {layer.key for layer in job.layers} != all_layers:
                categories = sorted(selected)

        tile_dir = generate_mvt_dataset(
            job.layer_type,
            self.settings,
            self.registry,
            job.output_dir,
            categories=categories,
            dry_run=self.dry_run,
            log_file=job.output_dir / f"{job.layer_type}_4326_mvt.log"
            if not self.dry_run
            else None,
        )
        return [
            TileResult(
                layer=None,
                projection=job.projection,
                output=tile_dir,
                kind="directory",
            )
        ]

    def _generate_single(
        self, layer: Layer, projection: Projection, output_dir: Path
    ) -> TileResult:
        log_file = output_dir / f"{layer.output_basename(projection.code)}.log"
        fgb = export_layer_to_fgb(
            layer,
            projection,
            self.settings,
            output_dir,
            force=self.force,
            dry_run=self.dry_run,
            log_file=log_file,
        )
        mbtiles = run_tippecanoe(
            layer,
            projection,
            self.settings,
            fgb,
            output_dir,
            self.registry,
            dry_run=self.dry_run,
            log_file=log_file,
        )
        return TileResult(layer=layer, projection=projection, output=mbtiles, fgb=fgb)


def generate_layer(
    layer_key: str,
    projection_code: str,
    settings: Settings,
    *,
    dry_run: bool = False,
    force: bool = False,
) -> TileResult:
    """Convenience helper for generating a single layer/projection pair."""
    registry = load_registry()
    layer = registry.layer(layer_key)
    projection = registry.projections[projection_code]
    engine = TileEngine(settings=settings, registry=registry, dry_run=dry_run, force=force)
    output_dir = engine.output_dir_for(layer.layer_type, projection)
    if projection_code == "4326":
        job = TileJob(
            layer_type=layer.layer_type,
            projection=projection,
            layers=[layer],
            output_dir=output_dir,
            categories=[layer.category],
        )
        return engine.generate(job)[0]
    return engine._generate_single(layer, projection, output_dir)  # noqa: SLF001


__all__ = ["TileEngine", "TileJob", "TileResult", "generate_layer"]
