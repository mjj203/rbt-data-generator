"""GeoNames importer (native port of import-geonames.sh).

Eleven point datasets land in the ``geonames`` schema: nine NGA GNS feature
classes plus two USGS national files. Flow mirrors the retired bash script:

- Phase 1 (parallel, ``download_parallel_jobs`` workers): download each zip,
  pick the data ``.txt`` member (skipping disclaimer/guide files), convert
  tabs to CSV. A valid CSV on disk short-circuits the phase (resume).
- Phase 2 (parallel, ``max_parallel_jobs`` workers): ogr2ogr each CSV into
  ``geonames.<table>`` unless the table already exists.

Failures are collected from both phases and raised at the end as
:class:`~rbt.importers._support.ImportFailed`; a dataset that failed to
prepare is never ingested.
"""

from __future__ import annotations

import zipfile
from collections.abc import Iterable
from dataclasses import dataclass
from functools import partial
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
    extract_zip,
    job_log_file,
    run_jobs,
    table_exists,
    tsv_to_csv,
    validate_min_lines,
)

log = get_logger(__name__)

SCHEMA = "geonames"

_NGA_URL_TEMPLATE = "https://geonames.nga.mil/geonames/GNSData/fc_files/{name}.zip"
_USGS_URL_TEMPLATE = (
    "https://prd-tnm.s3.amazonaws.com/StagedProducts/GeographicNames/Topical/{name}_Text.zip"
)
_MIN_ZIP_BYTES = 10_000
_MIN_CSV_LINES = 10
_EXCLUDED_MEMBER_HINTS = ("disclaimer", "guide")


@dataclass(frozen=True, slots=True)
class GnsDataset:
    """One GeoNames dataset (NGA GNS feature class or USGS national file)."""

    name: str  # registry key == target table under the geonames schema
    url: str
    expected_txt: str  # preferred data .txt basename inside the zip
    x_field: str
    y_field: str
    txt_subdir: str = ""  # zip member subdirectory holding the .txt ("Text" for USGS)

    @property
    def expected_member(self) -> str:
        """Expected zip member path of the data ``.txt``."""
        return f"{self.txt_subdir}/{self.expected_txt}" if self.txt_subdir else self.expected_txt

    @property
    def csv_name(self) -> str:
        return Path(self.expected_txt).stem + ".csv"


def _nga(feature_class: str) -> GnsDataset:
    return GnsDataset(
        name=feature_class.lower(),
        url=_NGA_URL_TEMPLATE.format(name=feature_class),
        expected_txt=f"{feature_class}.txt",
        x_field="long_dd",
        y_field="lat_dd",
    )


def _usgs(stem: str) -> GnsDataset:
    return GnsDataset(
        name=stem.lower(),
        url=_USGS_URL_TEMPLATE.format(name=stem),
        expected_txt=f"{stem}.txt",
        x_field="prim_long_dec",
        y_field="prim_lat_dec",
        txt_subdir="Text",
    )


_NGA_FEATURE_CLASSES = (
    "Administrative_Regions",
    "Hydrographic",
    "Hypsographic",
    "Populated_Places",
    "Areas_Localities",
    "Undersea",
    "Transportation_Networks",
    "Spot_Features",
    "Vegetation",
)

DATASETS: tuple[GnsDataset, ...] = (
    *(_nga(feature_class) for feature_class in _NGA_FEATURE_CLASSES),
    _usgs("PopulatedPlaces_National"),
    _usgs("HistoricalFeatures_National"),
)


def dataset_names() -> list[str]:
    return [dataset.name for dataset in DATASETS]


def select_txt_member(members: Iterable[zipfile.ZipInfo], expected: str) -> str | None:
    """Choose the data ``.txt`` member of a GNS/USGS archive.

    Disclaimer/guide files are excluded (case-insensitive). The member
    matching *expected* (full path or basename) is preferred; otherwise the
    largest remaining ``.txt`` wins — the bash script's ``find … | head``
    fallback, made deterministic.
    """
    candidates = [
        info
        for info in members
        if not info.is_dir()
        and info.filename.lower().endswith(".txt")
        and not any(hint in info.filename.lower() for hint in _EXCLUDED_MEMBER_HINTS)
    ]
    if not candidates:
        return None
    expected_name = Path(expected).name
    for info in candidates:
        if info.filename == expected or Path(info.filename).name == expected_name:
            return info.filename
    return max(candidates, key=lambda info: info.file_size).filename


def _work_dir(settings: Settings) -> Path:
    return settings.shared_temp_dir / "geonames"


def _csv_path(dataset: GnsDataset, settings: Settings) -> Path:
    return _work_dir(settings) / dataset.csv_name


def _prepare(dataset: GnsDataset, settings: Settings, *, dry_run: bool = False) -> None:
    """Phase 1: download the zip, extract the data .txt, convert to CSV."""
    csv_path = _csv_path(dataset, settings)
    if validate_min_lines(csv_path, _MIN_CSV_LINES):
        log.info("%s: %s already valid — skipping download", dataset.name, csv_path.name)
        return

    zip_path = _work_dir(settings) / dataset.url.rsplit("/", 1)[-1]
    download(
        dataset.url,
        zip_path,
        min_bytes=_MIN_ZIP_BYTES,
        retries=settings.retry_count,
        delay=settings.retry_delay,
        dry_run=dry_run,
    )
    if dry_run:
        log.info(
            "[dry-run] would extract %s from %s and convert to %s",
            dataset.expected_member,
            zip_path.name,
            csv_path.name,
        )
        return

    with zipfile.ZipFile(zip_path) as archive:
        member = select_txt_member(archive.infolist(), dataset.expected_member)
    if member is None:
        raise FileNotFoundError(f"{dataset.name}: no data .txt member found in {zip_path.name}")
    extract_zip(zip_path, _work_dir(settings), members=[member])
    txt_path = _work_dir(settings) / member
    tsv_to_csv(txt_path, csv_path)
    txt_path.unlink(missing_ok=True)
    if not validate_min_lines(csv_path, _MIN_CSV_LINES):
        raise OSError(f"{dataset.name}: converted CSV {csv_path.name} looks incomplete")
    log.info("%s prepared -> %s", dataset.name, csv_path.name)


def _ingest(dataset: GnsDataset, settings: Settings, *, dry_run: bool = False) -> None:
    """Phase 2: ogr2ogr the prepared CSV into ``geonames.<table>``."""
    if not dry_run and table_exists(settings, SCHEMA, dataset.name):
        log.info("geonames.%s already exists — skipping ingest", dataset.name)
        return
    csv_path = _csv_path(dataset, settings)
    ogr = OgrDataset(
        name=dataset.name,
        schema=SCHEMA,
        table=dataset.name,
        source=str(csv_path),
        nlt="POINT",
        a_srs="EPSG:4326",
        open_options=(
            "QUOTED_FIELDS_AS_STRING=YES",
            f"X_POSSIBLE_NAMES={dataset.x_field}",
            f"Y_POSSIBLE_NAMES={dataset.y_field}",
            "EMPTY_STRING_AS_NULL=YES",
        ),
        layer_creation=("PRECISION=NO",),
    )
    process.run_with_retry(
        build_ogr2ogr_cmd(ogr, settings, str(csv_path)),
        retries=settings.retry_count,
        delay=settings.retry_delay,
        env=settings.libpq_env(),
        log_file=job_log_file(settings, "geonames", dataset.name),
        dry_run=dry_run,
    )


def _select(only: list[str] | None) -> list[GnsDataset]:
    if only is None:
        return list(DATASETS)
    valid = dataset_names()
    unknown = sorted(set(only) - set(valid))
    if unknown:
        raise KeyError(
            f"unknown geonames dataset(s): {', '.join(unknown)}; valid names: {', '.join(valid)}"
        )
    wanted = set(only)
    return [dataset for dataset in DATASETS if dataset.name in wanted]


def import_geonames(
    settings: Settings, *, only: list[str] | None = None, dry_run: bool = False
) -> None:
    selected = _select(only)
    ensure_schemas(settings, [SCHEMA], dry_run=dry_run)

    log.info("geonames: preparing %d dataset(s)", len(selected))
    prepare_jobs = [
        Job(dataset.name, partial(_prepare, dataset, settings, dry_run=dry_run))
        for dataset in selected
    ]
    failed_prepare = run_jobs(
        prepare_jobs, settings, max_workers=settings.download_parallel_jobs, dry_run=dry_run
    )
    if failed_prepare:
        log.warning(
            "geonames: prepare failed for %s — their ingest will be skipped",
            ", ".join(sorted(failed_prepare)),
        )

    ready = [dataset for dataset in selected if dataset.name not in set(failed_prepare)]
    log.info("geonames: ingesting %d dataset(s)", len(ready))
    ingest_jobs = [
        Job(dataset.name, partial(_ingest, dataset, settings, dry_run=dry_run)) for dataset in ready
    ]
    failed_ingest = run_jobs(
        ingest_jobs, settings, max_workers=settings.max_parallel_jobs, dry_run=dry_run
    )

    all_failed = sorted({*failed_prepare, *failed_ingest})
    if all_failed:
        raise ImportFailed(all_failed)


__all__ = [
    "DATASETS",
    "GnsDataset",
    "dataset_names",
    "import_geonames",
    "select_txt_member",
]
