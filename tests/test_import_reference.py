"""Tests for the native reference-data importer (rbt.importers.reference)."""

from __future__ import annotations

from pathlib import Path

import pytest

from rbt.config import Settings
from rbt.importers import reference
from rbt.importers._support import ImportFailed
from rbt.importers.reference import (
    DATASETS,
    FIELDMAPS_GDAL_CONFIG,
    USA_SUBSET_CLUSTER_SQL,
    USA_SUBSET_INDEX_SQL,
    USA_SUBSET_SQL,
    USA_SUBSET_VACUUM_SQL,
    dataset_names,
    import_reference,
)

# Registry ground truth: name -> (schema, table, group), in DATASETS order
# (mirrors the DATASET_MANIFEST in import-reference-data.sh).
EXPECTED_REGISTRY = {
    "fieldmaps_adm0": ("fieldmap", "adm0", "fieldmaps"),
    "fieldmaps_adm1": ("fieldmap", "adm1", "fieldmaps"),
    "fieldmaps_adm2": ("fieldmap", "adm2", "fieldmaps"),
    "fieldmaps_adm0_lines": ("fieldmap", "adm0_lines", "fieldmaps"),
    "fieldmaps_adm1_lines": ("fieldmap", "adm1_lines", "fieldmaps"),
    "fieldmaps_adm2_lines": ("fieldmap", "adm2_lines", "fieldmaps"),
    "fieldmaps_adm0_labels": ("fieldmap", "adm0_labels", "fieldmaps"),
    "fieldmaps_adm1_labels": ("fieldmap", "adm1_labels", "fieldmaps"),
    "fieldmaps_adm2_labels": ("fieldmap", "adm2_labels", "fieldmaps"),
    "ourairports_airports": ("ourairports", "airport", "independent"),
    "ourairports_runways": ("ourairports", "runway", "independent"),
    "naturalearth": ("naturalearth", "ne_10m_admin_0_countries", "independent"),
    "osm_ocean": ("rbt", "osm_ocean", "independent"),
    "osm_ocean_simplified": ("rbt", "osm_ocean_simplified", "independent"),
    "osm_coastline": ("rbt", "coastline", "independent"),
    "osm_antarctica": ("rbt", "osm_antarctica_icesheet", "independent"),
    "mirta": ("mirta", "us_military_installations", "independent"),
}

FIELDMAPS_NAMES = [name for name, spec in EXPECTED_REGISTRY.items() if spec[2] == "fieldmaps"]
INDEPENDENT_NAMES = [name for name, spec in EXPECTED_REGISTRY.items() if spec[2] == "independent"]


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return Settings(
        database_host="db.example",
        database_port=5433,
        database_name="rbtdb",
        database_user="rbt_user",
        database_password="s3cret",
        retry_count=2,
        retry_delay=0,
        shared_log_dir=tmp_path / "logs",
        shared_temp_dir=tmp_path / "temp",
    )


class DbState:
    """Recorded psycopg interactions from the stubbed _support helpers."""

    def __init__(self) -> None:
        self.schemas: list[list[str]] = []
        self.existing: set[str] = set()
        self.sql: list[str] = []


@pytest.fixture
def no_db(monkeypatch) -> DbState:
    """Neutralize every psycopg touchpoint bound into the reference module."""
    state = DbState()

    def fake_ensure_schemas(settings, schemas, *, dry_run=False):
        state.schemas.append(list(schemas))

    def fake_table_exists(settings, schema, table):
        return f"{schema}.{table}" in state.existing

    def fake_execute_sql(settings, statement, description, *, dry_run=False):
        state.sql.append(statement)

    monkeypatch.setattr(reference, "ensure_schemas", fake_ensure_schemas)
    monkeypatch.setattr(reference, "table_exists", fake_table_exists)
    monkeypatch.setattr(reference, "execute_sql", fake_execute_sql)
    return state


# ---------------------------------------------------------------------------
# Registry completeness
# ---------------------------------------------------------------------------


def test_registry_names_tables_and_groups() -> None:
    actual = {d.name: (d.schema, d.table, d.group) for d in DATASETS}
    assert actual == EXPECTED_REGISTRY
    assert [d.name for d in DATASETS] == list(EXPECTED_REGISTRY)  # order + uniqueness


def test_dataset_names_includes_usa_subset() -> None:
    assert dataset_names() == [*EXPECTED_REGISTRY, "usa_subset"]


def test_fieldmaps_datasets_carry_exact_gdal_config() -> None:
    expected = (
        ("GDAL_DISABLE_READDIR_ON_OPEN", "EMPTY_DIR"),
        ("CPL_VSIL_CURL_ALLOWED_EXTENSIONS", ".parquet"),
        ("GDAL_HTTP_TIMEOUT", "300"),
        ("GDAL_HTTP_CONNECTTIMEOUT", "60"),
        ("VSI_CACHE", "TRUE"),
        ("VSI_CACHE_SIZE", "2500000000"),
    )
    assert expected == FIELDMAPS_GDAL_CONFIG
    fieldmaps = [d for d in DATASETS if d.group == "fieldmaps"]
    assert len(fieldmaps) == 9
    for dataset in fieldmaps:
        assert dataset.gdal_config == expected, dataset.name
    for dataset in DATASETS:
        if dataset.group != "fieldmaps":
            assert dataset.gdal_config == (), dataset.name


def test_fieldmaps_sources_and_geometry_types() -> None:
    actual = {d.name: (d.source, d.nlt) for d in DATASETS if d.group == "fieldmaps"}
    base_adm0 = "/vsicurl/https://data.fieldmaps.io/adm0/osm/all"
    base_intl = "/vsicurl/https://data.fieldmaps.io/edge-matched/humanitarian/intl"
    assert actual == {
        "fieldmaps_adm0": (f"{base_adm0}/adm0_polygons.parquet", "MULTIPOLYGON"),
        "fieldmaps_adm1": (f"{base_intl}/adm1_polygons.parquet", "MULTIPOLYGON"),
        "fieldmaps_adm2": (f"{base_intl}/adm2_polygons.parquet", "MULTIPOLYGON"),
        "fieldmaps_adm0_lines": (f"{base_adm0}/adm0_lines.parquet", "MULTILINESTRING"),
        "fieldmaps_adm1_lines": (f"{base_intl}/adm1_lines.parquet", "MULTILINESTRING"),
        "fieldmaps_adm2_lines": (f"{base_intl}/adm2_lines.parquet", "MULTILINESTRING"),
        "fieldmaps_adm0_labels": (f"{base_adm0}/adm0_points.parquet", "POINT"),
        "fieldmaps_adm1_labels": (f"{base_intl}/adm1_points.parquet", "POINT"),
        "fieldmaps_adm2_labels": (f"{base_intl}/adm2_points.parquet", "POINT"),
    }


# ---------------------------------------------------------------------------
# ogr2ogr argv goldens
# ---------------------------------------------------------------------------


def _oo_values(cmd: list[str]) -> list[str]:
    return [cmd[i + 1] for i, token in enumerate(cmd) if token == "-oo"]


def _lco_values(cmd: list[str]) -> list[str]:
    return [cmd[i + 1] for i, token in enumerate(cmd) if token == "-lco"]


def test_fieldmaps_adm0_argv_golden(settings: Settings, no_db: DbState, recorded_run) -> None:
    import_reference(settings, only=["fieldmaps_adm0"])

    [call] = recorded_run.calls
    assert call["cmd"] == [
        "ogr2ogr",
        "-progress",
        "--config",
        "GDAL_DISABLE_READDIR_ON_OPEN",
        "EMPTY_DIR",
        "--config",
        "CPL_VSIL_CURL_ALLOWED_EXTENSIONS",
        ".parquet",
        "--config",
        "GDAL_HTTP_TIMEOUT",
        "300",
        "--config",
        "GDAL_HTTP_CONNECTTIMEOUT",
        "60",
        "--config",
        "VSI_CACHE",
        "TRUE",
        "--config",
        "VSI_CACHE_SIZE",
        "2500000000",
        "--config",
        "PG_USE_COPY",
        "YES",
        "-f",
        "PostgreSQL",
        settings.ogr_pg_connection(),
        "-nln",
        "fieldmap.adm0",
        "-nlt",
        "MULTIPOLYGON",
        "-lco",
        "GEOMETRY_NAME=geometry",
        "-lco",
        "DIM=2",
        "-lco",
        "UNLOGGED=ON",
        "-skipfailures",
        "/vsicurl/https://data.fieldmaps.io/adm0/osm/all/adm0_polygons.parquet",
    ]
    # Password travels via PGPASSWORD (libpq env), never argv.
    assert all("s3cret" not in arg for arg in call["cmd"])
    assert call["env"] == settings.libpq_env()
    assert call["env"]["PGPASSWORD"] == "s3cret"
    assert call["dry_run"] is False


def test_naturalearth_argv(settings: Settings, no_db: DbState, recorded_run) -> None:
    import_reference(settings, only=["naturalearth"])

    [call] = recorded_run.calls
    cmd = call["cmd"]
    assert "-nln" not in cmd  # multi-layer load: schema lco instead of a table
    assert "SCHEMA=naturalearth" in _lco_values(cmd)
    assert "-overwrite" in cmd
    assert cmd[cmd.index("-nlt") + 1] == "PROMOTE_TO_MULTI"
    assert cmd[-1] == (
        "/vsizip//vsicurl/https://naciscdn.org/naturalearth/packages/"
        "natural_earth_vector.gpkg.zip/packages/natural_earth_vector.gpkg"
    )


def test_ourairports_airports_argv(settings: Settings, no_db: DbState, recorded_run) -> None:
    import_reference(settings, only=["ourairports_airports"])

    [call] = recorded_run.calls
    cmd = call["cmd"]
    assert cmd[cmd.index("-a_srs") + 1] == "EPSG:4326"
    assert cmd[cmd.index("-nln") + 1] == "ourairports.airport"
    assert cmd[cmd.index("-nlt") + 1] == "POINT"
    assert "PRECISION=NO" in _lco_values(cmd)
    assert _oo_values(cmd) == [
        "AUTODETECT_TYPE=YES",
        "QUOTED_FIELDS_AS_STRING=YES",
        "X_POSSIBLE_NAMES=longitude_deg",
        "Y_POSSIBLE_NAMES=latitude_deg",
        "EMPTY_STRING_AS_NULL=YES",
    ]
    assert cmd[-1].endswith("/airports.csv")


def test_ourairports_runways_argv_matches_bash(
    settings: Settings, no_db: DbState, recorded_run
) -> None:
    import_reference(settings, only=["ourairports_runways"])

    [call] = recorded_run.calls
    cmd = call["cmd"]
    assert "-nlt" not in cmd  # the bash importer sets no geometry type for runways
    assert cmd[cmd.index("-a_srs") + 1] == "EPSG:4326"
    assert cmd[cmd.index("-nln") + 1] == "ourairports.runway"
    assert "PRECISION=NO" in _lco_values(cmd)
    assert _oo_values(cmd) == [
        "AUTODETECT_TYPE=YES",
        "QUOTED_FIELDS_AS_STRING=YES",
        "EMPTY_STRING_AS_NULL=YES",
        "X_POSSIBLE_NAMES=le_longitude_deg",
        "Y_POSSIBLE_NAMES=le_latitude_deg",
    ]
    assert cmd[-1].endswith("/runways.csv")


# ---------------------------------------------------------------------------
# MIRTA callable source
# ---------------------------------------------------------------------------


def test_mirta_downloads_extracts_and_targets_gdb(
    settings: Settings, no_db: DbState, recorded_run, monkeypatch
) -> None:
    recorded: dict[str, object] = {}

    def fake_download(url, dest, **kwargs):
        recorded["url"] = url
        recorded["insecure_tls"] = kwargs.get("insecure_tls")
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(b"zip-bytes")
        return dest

    def fake_extract_zip(archive, dest_dir, **kwargs):
        recorded["archive"] = archive
        (dest_dir / "FY23_MIRTA_Final.gdb").mkdir(parents=True, exist_ok=True)

    monkeypatch.setattr(reference, "download", fake_download)
    monkeypatch.setattr(reference, "extract_zip", fake_extract_zip)

    import_reference(settings, only=["mirta"])  # runs just mirta

    [call] = recorded_run.calls
    cmd = call["cmd"]
    gdb = settings.shared_temp_dir / "mirta" / "FY23_MIRTA_Final.gdb"
    assert cmd[-2:] == [str(gdb), "MirtaLocations_A"]
    assert cmd[cmd.index("-nlt") + 1] == "GEOMETRY"
    assert cmd[cmd.index("-nln") + 1] == "mirta.us_military_installations"
    assert "-overwrite" in cmd
    assert recorded["insecure_tls"] is True
    assert recorded["url"] == (
        "https://www.acq.osd.mil/eie/imr/rpid/disdi/Downloads/installations_ranges.zip"
    )
    assert recorded["archive"] == settings.shared_temp_dir / "mirta" / "installations_ranges.zip"


def test_mirta_reuses_extracted_gdb(
    settings: Settings, no_db: DbState, recorded_run, monkeypatch
) -> None:
    gdb = settings.shared_temp_dir / "mirta" / "FY23_MIRTA_Final.gdb"
    gdb.mkdir(parents=True)

    def boom(*args, **kwargs):
        raise AssertionError("download must not run when the FileGDB is cached")

    monkeypatch.setattr(reference, "download", boom)

    import_reference(settings, only=["mirta"])

    [call] = recorded_run.calls
    assert call["cmd"][-2:] == [str(gdb), "MirtaLocations_A"]


def test_mirta_failure_collected_as_import_failure(
    settings: Settings, no_db: DbState, recorded_run, monkeypatch
) -> None:
    def failing_download(*args, **kwargs):
        raise OSError("network down")

    monkeypatch.setattr(reference, "download", failing_download)

    with pytest.raises(ImportFailed) as excinfo:
        import_reference(settings, only=["mirta"])
    assert excinfo.value.failed == ["mirta"]
    assert recorded_run.calls == []


# ---------------------------------------------------------------------------
# USA subset: frozen SQL + degradation ladder
# ---------------------------------------------------------------------------


def test_usa_subset_sql_frozen_fragments() -> None:
    assert USA_SUBSET_SQL.startswith("CREATE TABLE fieldmap.usa AS SELECT adm0_id, 'USA' AS gid_0")
    assert "ST_MakeValid(geometry, 'method=structure')" in USA_SUBSET_SQL
    assert "ST_SimplifyPreserveTopology" in USA_SUBSET_SQL
    assert "0.00001" in USA_SUBSET_SQL
    assert ".geom::geometry(Polygon,4326) AS geometry" in USA_SUBSET_SQL
    assert "FROM fieldmap.adm0" in USA_SUBSET_SQL
    assert "WHERE iso_3 IN ('GUM', 'PRI', 'MNP', 'ASM', 'UMI', 'VIR', 'USA');" in USA_SUBSET_SQL
    assert USA_SUBSET_INDEX_SQL == (
        "CREATE INDEX idx_fieldmap_usa_geometry_gist ON fieldmap.usa USING GIST (geometry);"
    )
    assert USA_SUBSET_CLUSTER_SQL == "CLUSTER fieldmap.usa USING idx_fieldmap_usa_geometry_gist;"
    assert USA_SUBSET_VACUUM_SQL == "VACUUM FULL ANALYZE fieldmap.usa;"


def test_usa_subset_runs_all_four_statements(settings: Settings, no_db: DbState) -> None:
    no_db.existing.add("fieldmap.adm0")

    import_reference(settings, only=["usa_subset"])

    assert no_db.sql == [
        USA_SUBSET_SQL,
        USA_SUBSET_INDEX_SQL,
        USA_SUBSET_CLUSTER_SQL,
        USA_SUBSET_VACUUM_SQL,
    ]


def _failing_execute_sql(state: DbState, fail_on: str):
    def fake_execute_sql(settings, statement, description, *, dry_run=False):
        state.sql.append(statement)
        if statement == fail_on:
            raise RuntimeError(f"boom: {description}")

    return fake_execute_sql


def test_usa_subset_create_failure_fails_job(
    settings: Settings, no_db: DbState, monkeypatch
) -> None:
    no_db.existing.add("fieldmap.adm0")
    monkeypatch.setattr(reference, "execute_sql", _failing_execute_sql(no_db, USA_SUBSET_SQL))

    with pytest.raises(ImportFailed) as excinfo:
        import_reference(settings, only=["usa_subset"])
    assert excinfo.value.failed == ["usa_subset"]
    assert no_db.sql == [USA_SUBSET_SQL]  # ladder never reached


def test_usa_subset_index_failure_skips_cluster_and_vacuum(
    settings: Settings, no_db: DbState, monkeypatch
) -> None:
    no_db.existing.add("fieldmap.adm0")
    monkeypatch.setattr(reference, "execute_sql", _failing_execute_sql(no_db, USA_SUBSET_INDEX_SQL))

    import_reference(settings, only=["usa_subset"])  # warns, does not raise

    assert no_db.sql == [USA_SUBSET_SQL, USA_SUBSET_INDEX_SQL]


def test_usa_subset_cluster_failure_skips_vacuum(
    settings: Settings, no_db: DbState, monkeypatch
) -> None:
    no_db.existing.add("fieldmap.adm0")
    monkeypatch.setattr(
        reference, "execute_sql", _failing_execute_sql(no_db, USA_SUBSET_CLUSTER_SQL)
    )

    import_reference(settings, only=["usa_subset"])  # warns, does not raise

    assert no_db.sql == [USA_SUBSET_SQL, USA_SUBSET_INDEX_SQL, USA_SUBSET_CLUSTER_SQL]


def test_usa_subset_skipped_when_table_exists(settings: Settings, no_db: DbState) -> None:
    no_db.existing.update({"fieldmap.adm0", "fieldmap.usa"})

    import_reference(settings, only=["usa_subset"])

    assert no_db.sql == []


def test_usa_subset_skipped_when_adm0_missing(settings: Settings, no_db: DbState) -> None:
    import_reference(settings, only=["usa_subset"])  # no fieldmap.adm0 => warn + skip

    assert no_db.sql == []


# ---------------------------------------------------------------------------
# Phase ordering + failure accumulation
# ---------------------------------------------------------------------------


@pytest.fixture
def phase_events(no_db: DbState, monkeypatch) -> list[tuple[str, object]]:
    """Record run_jobs pools and SQL statements in dispatch order."""
    events: list[tuple[str, object]] = []

    def fake_run_jobs(jobs, settings, **kwargs):
        events.append(("jobs", [job.name for job in jobs]))
        return []

    def fake_execute_sql(settings, statement, description, *, dry_run=False):
        events.append(("sql", statement))

    monkeypatch.setattr(reference, "run_jobs", fake_run_jobs)
    monkeypatch.setattr(reference, "execute_sql", fake_execute_sql)
    monkeypatch.setattr(reference, "table_exists", lambda s, schema, table: table == "adm0")
    return events


def test_default_mode_runs_fieldmaps_then_usa_then_independent(
    settings: Settings, phase_events: list[tuple[str, object]]
) -> None:
    import_reference(settings)

    assert phase_events == [
        ("jobs", FIELDMAPS_NAMES),
        ("sql", USA_SUBSET_SQL),
        ("sql", USA_SUBSET_INDEX_SQL),
        ("sql", USA_SUBSET_CLUSTER_SQL),
        ("sql", USA_SUBSET_VACUUM_SQL),
        ("jobs", INDEPENDENT_NAMES),
    ]


def test_parallel_mode_uses_single_pool_then_usa(
    settings: Settings, phase_events: list[tuple[str, object]]
) -> None:
    import_reference(settings, parallel=True)

    assert phase_events == [
        ("jobs", FIELDMAPS_NAMES + INDEPENDENT_NAMES),
        ("sql", USA_SUBSET_SQL),
        ("sql", USA_SUBSET_INDEX_SQL),
        ("sql", USA_SUBSET_CLUSTER_SQL),
        ("sql", USA_SUBSET_VACUUM_SQL),
    ]


def test_failures_accumulate_across_phases(settings: Settings, no_db: DbState, monkeypatch) -> None:
    results = iter([["fieldmaps_adm1"], ["mirta"]])
    monkeypatch.setattr(reference, "run_jobs", lambda jobs, s, **kwargs: next(results))

    with pytest.raises(ImportFailed) as excinfo:
        import_reference(settings)  # usa skipped (no fieldmap.adm0), not a failure
    assert excinfo.value.failed == ["fieldmaps_adm1", "mirta"]


# ---------------------------------------------------------------------------
# only= filter, table_exists skip, dry run
# ---------------------------------------------------------------------------


def test_only_unknown_name_raises_keyerror_with_valid_names(
    settings: Settings, no_db: DbState
) -> None:
    with pytest.raises(KeyError) as excinfo:
        import_reference(settings, only=["fieldmaps_adm0", "bogus"])
    message = str(excinfo.value)
    assert "bogus" in message
    assert "usa_subset" in message
    assert "fieldmaps_adm0" in message
    assert no_db.schemas == []  # validation happens before any work


def test_only_usa_subset_runs_no_ogr2ogr(settings: Settings, no_db: DbState, recorded_run) -> None:
    no_db.existing.add("fieldmap.adm0")

    import_reference(settings, only=["usa_subset"])

    assert recorded_run.calls == []
    assert no_db.sql[0] == USA_SUBSET_SQL


def test_table_exists_skips_ingest(settings: Settings, no_db: DbState, recorded_run) -> None:
    no_db.existing.add("rbt.osm_ocean")

    import_reference(settings, only=["osm_ocean"])

    assert recorded_run.calls == []


def test_schemas_ensured_before_ingest(settings: Settings, no_db: DbState, recorded_run) -> None:
    import_reference(settings, only=["osm_coastline"])

    assert no_db.schemas == [["fieldmap", "mirta", "naturalearth", "ourairports", "rbt"]]


def test_dry_run_records_all_commands_without_db(
    settings: Settings, recorded_run, monkeypatch
) -> None:
    def no_db_allowed(*args, **kwargs):
        raise AssertionError("psycopg must not be touched in a dry run")

    # ensure_schemas/execute_sql short-circuit on dry_run before psycopg;
    # table_exists has no dry-run path, so it must never be called at all.
    monkeypatch.setattr(reference, "table_exists", no_db_allowed)

    import_reference(settings, dry_run=True)

    assert len(recorded_run.calls) == len(DATASETS)
    assert all(call["dry_run"] is True for call in recorded_run.calls)
    assert all(call["env"] == settings.libpq_env() for call in recorded_run.calls)
    # The MIRTA callable is never invoked in a dry run — a representative
    # local path stands in for the extracted FileGDB.
    mirta_cmd = next(cmd for cmd in recorded_run.commands if cmd[-1] == "MirtaLocations_A")
    assert mirta_cmd[-2] == str(settings.shared_temp_dir / "mirta")
