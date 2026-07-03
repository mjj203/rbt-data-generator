"""Reference-data importer (native port of import-reference-data.sh).

FieldMaps administrative boundaries, OurAirports, Natural Earth, the OSM
water/coastline/Antarctica shapefiles, and MIRTA — every dataset streams
straight from its remote source into PostGIS via ogr2ogr (``/vsicurl/`` /
``/vsizip//vsicurl/``), except MIRTA, whose FileGDB zip must be downloaded
and extracted first (its TLS chain also requires ``insecure_tls``).

Flow (mirroring the retired bash script):

1. ensure the fieldmap/mirta/naturalearth/ourairports/rbt schemas exist;
2. phase 1 — the nine FieldMaps datasets in a parallel job pool;
3. the ``fieldmap.usa`` subset (frozen SQL; needs ``fieldmap.adm0``);
4. phase 2 — the independent datasets in a parallel job pool.

``parallel=True`` collapses both phases into one pool (the bash
``PARALLEL_INGESTION=true`` mode) with the USA subset still running after.
Failures accumulate across phases and raise :class:`ImportFailed` at the
end — one bad dataset never blocks the rest.
"""

from __future__ import annotations

from collections.abc import Sequence
from pathlib import Path

from .. import process
from ..config import Settings
from ..logging import get_logger
from ._support import (
    ImportFailed,
    Job,
    OgrDataset,
    build_ogr2ogr_cmd,
    download,
    ensure_schemas,
    execute_sql,
    extract_zip,
    job_log_file,
    run_jobs,
    table_exists,
)

log = get_logger(__name__)

SCHEMAS: tuple[str, ...] = ("fieldmap", "mirta", "naturalearth", "ourairports", "rbt")

USA_SUBSET_NAME = "usa_subset"

#: GDAL ``--config`` pairs for the remote-Parquet FieldMaps loads (verbatim
#: from the bash importer): no directory listing over HTTP, parquet-only
#: vsicurl, generous HTTP timeouts, and a 2.5 GB VSI cache.
FIELDMAPS_GDAL_CONFIG: tuple[tuple[str, str], ...] = (
    ("GDAL_DISABLE_READDIR_ON_OPEN", "EMPTY_DIR"),
    ("CPL_VSIL_CURL_ALLOWED_EXTENSIONS", ".parquet"),
    ("GDAL_HTTP_TIMEOUT", "300"),
    ("GDAL_HTTP_CONNECTTIMEOUT", "60"),
    ("VSI_CACHE", "TRUE"),
    ("VSI_CACHE_SIZE", "2500000000"),
)

_MIRTA_URL = "https://www.acq.osd.mil/eie/imr/rpid/disdi/Downloads/installations_ranges.zip"

# --- fieldmap.usa subset — SQL ported VERBATIM from create_usa_subset() ----
USA_SUBSET_SQL = (
    "CREATE TABLE fieldmap.usa AS SELECT adm0_id, 'USA' AS gid_0, "
    "(ST_Dump(ST_SimplifyPreserveTopology(ST_MakeValid(geometry, 'method=structure'),"
    "0.00001))).geom::geometry(Polygon,4326) AS geometry "
    "FROM fieldmap.adm0 "
    "WHERE iso_3 IN ('GUM', 'PRI', 'MNP', 'ASM', 'UMI', 'VIR', 'USA');"
)
USA_SUBSET_INDEX_SQL = (
    "CREATE INDEX idx_fieldmap_usa_geometry_gist ON fieldmap.usa USING GIST (geometry);"
)
USA_SUBSET_CLUSTER_SQL = "CLUSTER fieldmap.usa USING idx_fieldmap_usa_geometry_gist;"
USA_SUBSET_VACUUM_SQL = "VACUUM FULL ANALYZE fieldmap.usa;"


def _find_gdb(root: Path) -> Path | None:
    """First ``*.gdb`` directory under *root* (FileGDBs are directories)."""
    if not root.is_dir():
        return None
    for candidate in sorted(root.glob("*.gdb")):
        if candidate.is_dir():
            return candidate
    return None


def _mirta_source(settings: Settings) -> Path:
    """Download + extract the MIRTA FileGDB zip, returning the ``.gdb`` path.

    Resume semantics match the bash importer: an already-extracted ``.gdb``
    under the temp dir short-circuits the download. The MIRTA endpoint's TLS
    chain is absent from standard trust stores, hence ``insecure_tls=True``
    (the bash used ``wget --no-check-certificate``).
    """
    dest_dir = settings.shared_temp_dir / "mirta"
    existing = _find_gdb(dest_dir)
    if existing is not None:
        log.info("MIRTA FileGDB already extracted at %s — skipping download", existing)
        return existing
    archive = download(_MIRTA_URL, dest_dir / "installations_ranges.zip", insecure_tls=True)
    extract_zip(archive, dest_dir)
    gdb = _find_gdb(dest_dir)
    if gdb is None:
        raise FileNotFoundError(
            f"no .gdb directory under {dest_dir} after extracting the MIRTA archive"
        )
    return gdb


def _fieldmaps(table: str, nlt: str, url: str) -> OgrDataset:
    return OgrDataset(
        name=f"fieldmaps_{table}",
        schema="fieldmap",
        table=table,
        source=f"/vsicurl/{url}",
        nlt=nlt,
        gdal_config=FIELDMAPS_GDAL_CONFIG,
        group="fieldmaps",
    )


DATASETS: tuple[OgrDataset, ...] = (
    # --- FieldMaps admin boundaries (remote Parquet over vsicurl) ----------
    _fieldmaps(
        "adm0",
        "MULTIPOLYGON",
        "https://data.fieldmaps.io/adm0/osm/all/adm0_polygons.parquet",
    ),
    _fieldmaps(
        "adm1",
        "MULTIPOLYGON",
        "https://data.fieldmaps.io/edge-matched/humanitarian/intl/adm1_polygons.parquet",
    ),
    _fieldmaps(
        "adm2",
        "MULTIPOLYGON",
        "https://data.fieldmaps.io/edge-matched/humanitarian/intl/adm2_polygons.parquet",
    ),
    _fieldmaps(
        "adm0_lines",
        "MULTILINESTRING",
        "https://data.fieldmaps.io/adm0/osm/all/adm0_lines.parquet",
    ),
    _fieldmaps(
        "adm1_lines",
        "MULTILINESTRING",
        "https://data.fieldmaps.io/edge-matched/humanitarian/intl/adm1_lines.parquet",
    ),
    _fieldmaps(
        "adm2_lines",
        "MULTILINESTRING",
        "https://data.fieldmaps.io/edge-matched/humanitarian/intl/adm2_lines.parquet",
    ),
    _fieldmaps(
        "adm0_labels",
        "POINT",
        "https://data.fieldmaps.io/adm0/osm/all/adm0_points.parquet",
    ),
    _fieldmaps(
        "adm1_labels",
        "POINT",
        "https://data.fieldmaps.io/edge-matched/humanitarian/intl/adm1_points.parquet",
    ),
    _fieldmaps(
        "adm2_labels",
        "POINT",
        "https://data.fieldmaps.io/edge-matched/humanitarian/intl/adm2_points.parquet",
    ),
    # --- Independent sources ------------------------------------------------
    OgrDataset(
        name="ourairports_airports",
        schema="ourairports",
        table="airport",
        source=(
            "/vsicurl/https://raw.githubusercontent.com/davidmegginson/"
            "ourairports-data/refs/heads/main/airports.csv"
        ),
        nlt="POINT",
        a_srs="EPSG:4326",
        layer_creation=("PRECISION=NO",),
        open_options=(
            "AUTODETECT_TYPE=YES",
            "QUOTED_FIELDS_AS_STRING=YES",
            "X_POSSIBLE_NAMES=longitude_deg",
            "Y_POSSIBLE_NAMES=latitude_deg",
            "EMPTY_STRING_AS_NULL=YES",
        ),
    ),
    OgrDataset(
        name="ourairports_runways",
        schema="ourairports",
        table="runway",
        source=(
            "/vsicurl/https://raw.githubusercontent.com/davidmegginson/"
            "ourairports-data/refs/heads/main/runways.csv"
        ),
        # No -nlt for runways, and the low-end coordinates locate the point —
        # exactly as the bash importer did.
        a_srs="EPSG:4326",
        layer_creation=("PRECISION=NO",),
        open_options=(
            "AUTODETECT_TYPE=YES",
            "QUOTED_FIELDS_AS_STRING=YES",
            "EMPTY_STRING_AS_NULL=YES",
            "X_POSSIBLE_NAMES=le_longitude_deg",
            "Y_POSSIBLE_NAMES=le_latitude_deg",
        ),
    ),
    OgrDataset(
        name="naturalearth",
        schema="naturalearth",
        # Multi-layer load (no -nln); this table is only the skip-check probe.
        table="ne_10m_admin_0_countries",
        source=(
            "/vsizip//vsicurl/https://naciscdn.org/naturalearth/packages/"
            "natural_earth_vector.gpkg.zip/packages/natural_earth_vector.gpkg"
        ),
        nlt="PROMOTE_TO_MULTI",
        overwrite=True,
        schema_lco="naturalearth",
    ),
    OgrDataset(
        name="osm_ocean",
        schema="rbt",
        table="osm_ocean",
        source=(
            "/vsizip//vsicurl/https://osmdata.openstreetmap.de/download/"
            "water-polygons-split-4326.zip/water-polygons-split-4326/water_polygons.shp"
        ),
        nlt="PROMOTE_TO_MULTI",
        t_srs="EPSG:4326",
        overwrite=True,
    ),
    OgrDataset(
        name="osm_ocean_simplified",
        schema="rbt",
        table="osm_ocean_simplified",
        source=(
            "/vsizip//vsicurl/https://osmdata.openstreetmap.de/download/"
            "simplified-water-polygons-split-3857.zip/"
            "simplified-water-polygons-split-3857/simplified_water_polygons.shp"
        ),
        nlt="PROMOTE_TO_MULTI",
        t_srs="EPSG:4326",  # source is 3857; the bash reprojects to 4326
        overwrite=True,
    ),
    OgrDataset(
        name="osm_coastline",
        schema="rbt",
        table="coastline",
        source=(
            "/vsizip//vsicurl/https://osmdata.openstreetmap.de/download/"
            "coastlines-split-4326.zip/coastlines-split-4326/lines.shp"
        ),
        nlt="MULTILINESTRING",  # no -t_srs in the bash: already EPSG:4326
        overwrite=True,
    ),
    OgrDataset(
        name="osm_antarctica",
        schema="rbt",
        table="osm_antarctica_icesheet",
        source=(
            "/vsizip//vsicurl/https://osmdata.openstreetmap.de/download/"
            "antarctica-icesheet-polygons-3857.zip/"
            "antarctica-icesheet-polygons-3857/icesheet_polygons.shp"
        ),
        nlt="PROMOTE_TO_MULTI",
        t_srs="EPSG:4326",
        overwrite=True,
    ),
    OgrDataset(
        name="mirta",
        schema="mirta",
        table="us_military_installations",
        source=_mirta_source,
        src_layer="MirtaLocations_A",
        nlt="GEOMETRY",
        overwrite=True,
    ),
)


def dataset_names() -> list[str]:
    """All importable dataset names, plus the ``usa_subset`` pseudo-dataset."""
    return [dataset.name for dataset in DATASETS] + [USA_SUBSET_NAME]


def _validate_only(only: list[str] | None) -> set[str] | None:
    if only is None:
        return None
    valid = set(dataset_names())
    unknown = sorted(set(only) - valid)
    if unknown:
        raise KeyError(
            f"unknown dataset(s): {', '.join(unknown)}; valid names: {', '.join(dataset_names())}"
        )
    return set(only)


def _resolve_source(dataset: OgrDataset, settings: Settings, *, dry_run: bool) -> str:
    if callable(dataset.source):
        if dry_run:
            # Never download in a dry run; log a representative local path.
            return str(settings.shared_temp_dir / dataset.name)
        return str(dataset.source(settings))
    return dataset.source


def _run_dataset(dataset: OgrDataset, settings: Settings, *, dry_run: bool) -> None:
    if not dry_run and table_exists(settings, dataset.schema, dataset.table):
        log.info("%s already exists — skipping %s", dataset.qualified_table, dataset.name)
        return
    source = _resolve_source(dataset, settings, dry_run=dry_run)
    process.run_with_retry(
        build_ogr2ogr_cmd(dataset, settings, source),
        # run_jobs already retries settings.retry_count times per job (parity
        # with the bash run_job wrapper), so each attempt runs the subprocess
        # exactly once.
        retries=1,
        env=settings.libpq_env(),
        log_file=job_log_file(settings, "reference", dataset.name),
        dry_run=dry_run,
    )


def _jobs(datasets: Sequence[OgrDataset], settings: Settings, *, dry_run: bool) -> list[Job]:
    def make(dataset: OgrDataset) -> Job:
        return Job(
            name=dataset.name,
            action=lambda: _run_dataset(dataset, settings, dry_run=dry_run),
        )

    return [make(dataset) for dataset in datasets]


def _create_usa_subset(settings: Settings, *, dry_run: bool = False) -> None:
    """Build ``fieldmap.usa`` with the bash importer's degradation ladder.

    CREATE TABLE failure propagates (the job fails); a failed index warns and
    skips cluster+vacuum; a failed cluster warns and skips vacuum; a failed
    vacuum only warns.
    """
    if not dry_run:
        if table_exists(settings, "fieldmap", "usa"):
            log.info("fieldmap.usa already exists — skipping USA subset")
            return
        if not table_exists(settings, "fieldmap", "adm0"):
            log.warning("fieldmap.adm0 not found — skipping USA subset creation")
            return
    execute_sql(settings, USA_SUBSET_SQL, "USA subset creation", dry_run=dry_run)
    try:
        execute_sql(settings, USA_SUBSET_INDEX_SQL, "GIST geometry index creation", dry_run=dry_run)
    except Exception as exc:  # noqa: BLE001 - degradation ladder, parity with bash
        log.warning(
            "failed to create GIST index on fieldmap.usa, continuing without index: %s", exc
        )
        return
    try:
        execute_sql(
            settings, USA_SUBSET_CLUSTER_SQL, "Table clustering on geometry index", dry_run=dry_run
        )
    except Exception as exc:  # noqa: BLE001 - degradation ladder, parity with bash
        log.warning("failed to cluster fieldmap.usa, continuing without clustering: %s", exc)
        return
    try:
        execute_sql(
            settings, USA_SUBSET_VACUUM_SQL, "VACUUM FULL ANALYZE fieldmap.usa", dry_run=dry_run
        )
    except Exception as exc:  # noqa: BLE001 - degradation ladder, parity with bash
        log.warning("VACUUM FULL ANALYZE fieldmap.usa failed: %s", exc)


def import_reference(
    settings: Settings,
    *,
    only: list[str] | None = None,
    parallel: bool = False,
    dry_run: bool = False,
) -> None:
    """Import all reference datasets (or the *only* subset).

    Default mode runs two phases — FieldMaps, then the USA subset, then the
    independent sources. ``parallel=True`` runs every dataset in a single
    pool and creates the USA subset afterwards. Job failures accumulate and
    raise :class:`ImportFailed` once everything has been attempted.
    """
    selected = _validate_only(only)
    ensure_schemas(settings, SCHEMAS, dry_run=dry_run)

    datasets = [d for d in DATASETS if selected is None or d.name in selected]
    fieldmaps = [d for d in datasets if d.group == "fieldmaps"]
    independent = [d for d in datasets if d.group != "fieldmaps"]
    run_usa = selected is None or USA_SUBSET_NAME in selected

    failures: list[str] = []

    def usa_subset() -> None:
        if not run_usa:
            return
        try:
            _create_usa_subset(settings, dry_run=dry_run)
        except Exception as exc:  # noqa: BLE001 - collected like any failed job
            log.error("USA subset creation failed: %s", exc)
            failures.append(USA_SUBSET_NAME)

    if parallel:
        failures.extend(
            run_jobs(
                _jobs(fieldmaps + independent, settings, dry_run=dry_run), settings, dry_run=dry_run
            )
        )
        usa_subset()
    else:
        failures.extend(
            run_jobs(_jobs(fieldmaps, settings, dry_run=dry_run), settings, dry_run=dry_run)
        )
        usa_subset()
        failures.extend(
            run_jobs(_jobs(independent, settings, dry_run=dry_run), settings, dry_run=dry_run)
        )

    if failures:
        raise ImportFailed(failures)


__all__ = [
    "DATASETS",
    "FIELDMAPS_GDAL_CONFIG",
    "USA_SUBSET_CLUSTER_SQL",
    "USA_SUBSET_INDEX_SQL",
    "USA_SUBSET_NAME",
    "USA_SUBSET_SQL",
    "USA_SUBSET_VACUUM_SQL",
    "dataset_names",
    "import_reference",
]
