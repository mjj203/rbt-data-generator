"""Tests for the native GeoNames importer (``rbt.importers.geonames``)."""

from __future__ import annotations

import zipfile
from pathlib import Path
from urllib.parse import urlparse

import pytest

from rbt.config import Settings, load_settings
from rbt.importers import _support, geonames

EXPECTED_TABLES = {
    "administrative_regions",
    "hydrographic",
    "hypsographic",
    "populated_places",
    "areas_localities",
    "undersea",
    "transportation_networks",
    "spot_features",
    "vegetation",
    "populatedplaces_national",
    "historicalfeatures_national",
}


def _dataset(name: str) -> geonames.GnsDataset:
    return next(dataset for dataset in geonames.DATASETS if dataset.name == name)


def _write_valid_csv(settings: Settings, name: str, lines: int = 12) -> Path:
    path = settings.shared_temp_dir / "geonames" / _dataset(name).csv_name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("header\n" + "row\n" * (lines - 1), encoding="utf-8")
    return path


def _nln_targets(commands: list[list[str]]) -> list[str]:
    return [cmd[cmd.index("-nln") + 1] for cmd in commands]


def _no_db(monkeypatch: pytest.MonkeyPatch) -> None:
    """Neutralize the psycopg-touching helpers bound into the geonames module."""
    monkeypatch.setattr(geonames, "ensure_schemas", lambda *args, **kwargs: None)
    monkeypatch.setattr(geonames, "table_exists", lambda *args, **kwargs: False)


# ---------------------------------------------------------------------------
# registry
# ---------------------------------------------------------------------------


def test_registry_has_eleven_datasets() -> None:
    assert len(geonames.DATASETS) == 11


def test_registry_table_names_exact() -> None:
    assert set(geonames.dataset_names()) == EXPECTED_TABLES


def test_dataset_names_are_unique_and_ordered() -> None:
    names = geonames.dataset_names()
    assert len(names) == len(set(names))
    assert names[0] == "administrative_regions"
    assert names[-2:] == ["populatedplaces_national", "historicalfeatures_national"]


def test_nga_datasets_fields_and_urls() -> None:
    nga = [d for d in geonames.DATASETS if "geonames.nga.mil" in d.url]
    assert len(nga) == 9
    for dataset in nga:
        assert dataset.x_field == "long_dd"
        assert dataset.y_field == "lat_dd"
        assert dataset.txt_subdir == ""
        stem = Path(dataset.expected_txt).stem
        assert dataset.url == f"https://geonames.nga.mil/geonames/GNSData/fc_files/{stem}.zip"
        assert dataset.name == stem.lower()


def test_usgs_datasets_fields_and_urls() -> None:
    usgs = [d for d in geonames.DATASETS if "prd-tnm.s3.amazonaws.com" in d.url]
    assert len(usgs) == 2
    for dataset in usgs:
        assert dataset.x_field == "prim_long_dec"
        assert dataset.y_field == "prim_lat_dec"
        assert dataset.txt_subdir == "Text"
        assert dataset.expected_member == f"Text/{dataset.expected_txt}"
    assert {d.url.rsplit("/", 1)[-1] for d in usgs} == {
        "PopulatedPlaces_National_Text.zip",
        "HistoricalFeatures_National_Text.zip",
    }
    assert {d.name for d in usgs} == {"populatedplaces_national", "historicalfeatures_national"}


def test_registry_urls_well_formed() -> None:
    for dataset in geonames.DATASETS:
        parsed = urlparse(dataset.url)
        assert parsed.scheme == "https"
        assert parsed.netloc
        assert parsed.path.endswith(".zip")


# ---------------------------------------------------------------------------
# `only` filtering
# ---------------------------------------------------------------------------


def test_only_filters_datasets(fake_repo: Path, recorded_run) -> None:
    geonames.import_geonames(load_settings(), only=["vegetation", "undersea"], dry_run=True)
    assert sorted(_nln_targets(recorded_run.commands)) == [
        "geonames.undersea",
        "geonames.vegetation",
    ]


def test_only_unknown_name_raises_keyerror_listing_valid_names(fake_repo: Path) -> None:
    with pytest.raises(KeyError) as excinfo:
        geonames.import_geonames(load_settings(), only=["nope", "vegetation"])
    message = str(excinfo.value)
    assert "nope" in message
    for name in geonames.dataset_names():
        assert name in message


# ---------------------------------------------------------------------------
# zip member selection
# ---------------------------------------------------------------------------


def test_select_txt_member_prefers_expected(tmp_path: Path) -> None:
    zip_path = tmp_path / "Undersea.zip"
    with zipfile.ZipFile(zip_path, "w") as zf:
        zf.writestr("disclaimer.txt", "legal " * 100)
        zf.writestr("GNS_Country_Files_Guide.txt", "guide " * 1000)
        zf.writestr("Countries.txt", "bigger than the data file " * 1000)
        zf.writestr("Undersea.txt", "sea\t-42.0\t13.37\n")
    with zipfile.ZipFile(zip_path) as zf:
        member = geonames.select_txt_member(zf.infolist(), "Undersea.txt")
    assert member == "Undersea.txt"


def test_select_txt_member_falls_back_to_largest(tmp_path: Path) -> None:
    zip_path = tmp_path / "archive.zip"
    with zipfile.ZipFile(zip_path, "w") as zf:
        zf.writestr("disclaimer.txt", "legal " * 100)
        zf.writestr("small.txt", "tiny")
        zf.writestr("Undersea_Features.txt", "row\n" * 5000)
    with zipfile.ZipFile(zip_path) as zf:
        member = geonames.select_txt_member(zf.infolist(), "Undersea.txt")
    assert member == "Undersea_Features.txt"


def test_select_txt_member_returns_none_without_candidates(tmp_path: Path) -> None:
    zip_path = tmp_path / "archive.zip"
    with zipfile.ZipFile(zip_path, "w") as zf:
        zf.writestr("disclaimer.txt", "legal")
        zf.writestr("Some_Guide.txt", "guide")
        zf.writestr("readme.pdf", "not text")
    with zipfile.ZipFile(zip_path) as zf:
        member = geonames.select_txt_member(zf.infolist(), "Undersea.txt")
    assert member is None


# ---------------------------------------------------------------------------
# phase 1: prepare (download / extract / convert)
# ---------------------------------------------------------------------------


def test_prepare_extracts_and_converts_usgs_zip(
    fake_repo: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    settings = load_settings()
    dataset = _dataset("populatedplaces_national")
    header = "feature_name\tprim_long_dec\tprim_lat_dec\n"
    rows = "".join(f"place {i}\t-9{i}.5\t3{i}.25\n" for i in range(12))

    def fake_download(url: str, dest: Path, **kwargs: object) -> Path:
        assert url == dataset.url
        dest.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(dest, "w") as zf:
            zf.writestr("disclaimer.txt", "legal")
            zf.writestr("Text/PopulatedPlaces_National.txt", header + rows)
        return dest

    monkeypatch.setattr(geonames, "download", fake_download)
    geonames._prepare(dataset, settings)

    csv_path = settings.shared_temp_dir / "geonames" / "PopulatedPlaces_National.csv"
    lines = csv_path.read_text(encoding="utf-8").splitlines()
    assert lines[0] == "feature_name,prim_long_dec,prim_lat_dec"
    assert len(lines) == 13
    # The intermediate .txt is cleaned up after conversion.
    txt_path = settings.shared_temp_dir / "geonames" / "Text" / "PopulatedPlaces_National.txt"
    assert not txt_path.exists()


def test_prepare_raises_when_no_data_txt(fake_repo: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    settings = load_settings()

    def fake_download(url: str, dest: Path, **kwargs: object) -> Path:
        dest.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(dest, "w") as zf:
            zf.writestr("disclaimer.txt", "legal")
            zf.writestr("GNS_Country_Files_Guide.txt", "guide")
        return dest

    monkeypatch.setattr(geonames, "download", fake_download)
    with pytest.raises(FileNotFoundError, match="no data .txt"):
        geonames._prepare(_dataset("undersea"), settings)


def test_resume_skips_download_but_still_ingests(
    fake_repo: Path, recorded_run, monkeypatch: pytest.MonkeyPatch
) -> None:
    settings = load_settings()
    _no_db(monkeypatch)

    def refuse_download(*args: object, **kwargs: object) -> None:
        raise AssertionError("download must not be called when a valid CSV exists")

    monkeypatch.setattr(geonames, "download", refuse_download)
    _write_valid_csv(settings, "undersea")

    geonames.import_geonames(settings, only=["undersea"])
    assert _nln_targets(recorded_run.commands) == ["geonames.undersea"]


# ---------------------------------------------------------------------------
# phase 2: ingest (ogr2ogr argv goldens)
# ---------------------------------------------------------------------------


def test_ingest_argv_golden_nga(
    fake_repo: Path, recorded_run, monkeypatch: pytest.MonkeyPatch
) -> None:
    settings = load_settings()
    monkeypatch.setattr(geonames, "table_exists", lambda *args, **kwargs: False)

    geonames._ingest(_dataset("administrative_regions"), settings)

    csv = str(settings.shared_temp_dir / "geonames" / "Administrative_Regions.csv")
    [cmd] = recorded_run.commands
    assert cmd == [
        "ogr2ogr",
        "-progress",
        "--config",
        "PG_USE_COPY",
        "YES",
        "-f",
        "PostgreSQL",
        settings.ogr_pg_connection(),
        "-a_srs",
        "EPSG:4326",
        "-nln",
        "geonames.administrative_regions",
        "-nlt",
        "POINT",
        "-lco",
        "GEOMETRY_NAME=geometry",
        "-lco",
        "DIM=2",
        "-lco",
        "UNLOGGED=ON",
        "-lco",
        "PRECISION=NO",
        "-oo",
        "QUOTED_FIELDS_AS_STRING=YES",
        "-oo",
        "X_POSSIBLE_NAMES=long_dd",
        "-oo",
        "Y_POSSIBLE_NAMES=lat_dd",
        "-oo",
        "EMPTY_STRING_AS_NULL=YES",
        "-skipfailures",
        csv,
    ]
    assert all("password" not in part.lower() for part in cmd)
    [call] = recorded_run.calls
    assert call["env"] == settings.libpq_env()
    assert call["retries"] == settings.retry_count
    assert call["dry_run"] is False


def test_ingest_argv_golden_usgs(
    fake_repo: Path, recorded_run, monkeypatch: pytest.MonkeyPatch
) -> None:
    settings = load_settings()
    monkeypatch.setattr(geonames, "table_exists", lambda *args, **kwargs: False)

    geonames._ingest(_dataset("populatedplaces_national"), settings)

    csv = str(settings.shared_temp_dir / "geonames" / "PopulatedPlaces_National.csv")
    [cmd] = recorded_run.commands
    assert cmd == [
        "ogr2ogr",
        "-progress",
        "--config",
        "PG_USE_COPY",
        "YES",
        "-f",
        "PostgreSQL",
        settings.ogr_pg_connection(),
        "-a_srs",
        "EPSG:4326",
        "-nln",
        "geonames.populatedplaces_national",
        "-nlt",
        "POINT",
        "-lco",
        "GEOMETRY_NAME=geometry",
        "-lco",
        "DIM=2",
        "-lco",
        "UNLOGGED=ON",
        "-lco",
        "PRECISION=NO",
        "-oo",
        "QUOTED_FIELDS_AS_STRING=YES",
        "-oo",
        "X_POSSIBLE_NAMES=prim_long_dec",
        "-oo",
        "Y_POSSIBLE_NAMES=prim_lat_dec",
        "-oo",
        "EMPTY_STRING_AS_NULL=YES",
        "-skipfailures",
        csv,
    ]
    assert all("password" not in part.lower() for part in cmd)


def test_ingest_skipped_when_table_exists(
    fake_repo: Path, recorded_run, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(geonames, "table_exists", lambda *args, **kwargs: True)
    geonames._ingest(_dataset("vegetation"), load_settings())
    assert recorded_run.calls == []


# ---------------------------------------------------------------------------
# failure handling
# ---------------------------------------------------------------------------


def test_prepare_failure_excludes_ingest_and_raises(
    fake_repo: Path, recorded_run, monkeypatch: pytest.MonkeyPatch
) -> None:
    settings = load_settings()
    _no_db(monkeypatch)
    monkeypatch.setattr("rbt.importers._support.time.sleep", lambda _seconds: None)

    def failing_download(url: str, dest: Path, **kwargs: object) -> Path:
        raise OSError("network down")

    monkeypatch.setattr(geonames, "download", failing_download)
    # vegetation resumes from a valid CSV; undersea must download and fails.
    _write_valid_csv(settings, "vegetation")

    with pytest.raises(_support.ImportFailed) as excinfo:
        geonames.import_geonames(settings, only=["undersea", "vegetation"])

    assert excinfo.value.failed == ["undersea"]
    assert "undersea" in str(excinfo.value)
    # Phase 2 ran only for the dataset whose prepare succeeded.
    assert _nln_targets(recorded_run.commands) == ["geonames.vegetation"]


# ---------------------------------------------------------------------------
# dry-run
# ---------------------------------------------------------------------------


def test_dry_run_end_to_end(fake_repo: Path, recorded_run) -> None:
    settings = load_settings()
    geonames.import_geonames(settings, dry_run=True)

    assert len(recorded_run.calls) == 11
    assert all(cmd[0] == "ogr2ogr" for cmd in recorded_run.commands)
    assert all(call["dry_run"] is True for call in recorded_run.calls)
    assert set(_nln_targets(recorded_run.commands)) == {
        f"geonames.{name}" for name in geonames.dataset_names()
    }
    # No zips, txts, or CSVs are required or produced in dry-run mode.
    work_dir = settings.shared_temp_dir / "geonames"
    assert not work_dir.exists() or not any(work_dir.iterdir())
