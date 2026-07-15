"""Tests for the PostGIS Overture buildings importer (rbt.importers.buildings).

Fills a previously-missing coverage gap: golden ``aws s3 sync`` + ``ogr2ogr``
argv, the ``--skip-parts`` path, the "table already exists → skip" short-circuit,
and the building_part warn-don't-fail parity with the retired bash importer.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

from rbt import process
from rbt.config import Settings
from rbt.importers import buildings


def _settings(tmp_path: Path) -> Settings:
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


def _dest(settings: Settings, release: str) -> Path:
    return settings.shared_temp_dir / "overture-buildings" / release


def test_dry_run_golden_argv(tmp_path: Path, recorded_run) -> None:
    settings = _settings(tmp_path)
    buildings.import_buildings(settings, dry_run=True)

    # s3 sync → ogr2ogr(building) → ogr2ogr(building_part)
    assert len(recorded_run.calls) == 3
    sync, ingest_building, ingest_part = (c["cmd"] for c in recorded_run.calls)

    dest = _dest(settings, settings.overture_release)
    assert sync == [
        "aws",
        "s3",
        "sync",
        "--no-sign-request",
        f"{settings.overture_s3_bucket.rstrip('/')}/release/"
        f"{settings.overture_release}/theme=buildings/",
        str(dest),
        "--only-show-errors",
        "--cli-read-timeout",
        "0",
        "--cli-connect-timeout",
        "0",
    ]
    assert ingest_building == [
        "ogr2ogr",
        "-progress",
        "--config",
        "PG_USE_COPY",
        "YES",
        "-f",
        "PostgreSQL",
        settings.ogr_pg_connection(),
        "-nln",
        "overture.building",
        "-lco",
        "GEOMETRY_NAME=geometry",
        "-lco",
        "DIM=2",
        "-lco",
        "UNLOGGED=ON",
        "-skipfailures",
        str(dest / "type=building"),
    ]
    assert ingest_part[-1] == str(dest / "type=building_part")
    assert "overture.buildingpart" in ingest_part


def test_skip_parts_omits_building_part(tmp_path: Path, recorded_run) -> None:
    settings = _settings(tmp_path)
    buildings.import_buildings(settings, skip_parts=True, dry_run=True)

    assert len(recorded_run.calls) == 2
    assert not any("overture.buildingpart" in c["cmd"] for c in recorded_run.calls)


def test_release_override_flows_into_sync(tmp_path: Path, recorded_run) -> None:
    settings = _settings(tmp_path)
    buildings.import_buildings(settings, release="2030-01-01.0", dry_run=True)

    sync = recorded_run.calls[0]["cmd"]
    assert "/release/2030-01-01.0/theme=buildings/" in sync[4]
    assert str(_dest(settings, "2030-01-01.0")) == sync[5]


def test_existing_table_short_circuits(tmp_path: Path, monkeypatch, recorded_run) -> None:
    settings = _settings(tmp_path)
    monkeypatch.setattr(buildings, "table_exists", lambda *a, **k: True)

    buildings.import_buildings(settings)  # not a dry-run

    # No sync/ingest work when overture.building already exists.
    assert recorded_run.calls == []


def test_building_part_failure_is_non_fatal(tmp_path: Path, monkeypatch) -> None:
    settings = _settings(tmp_path)
    release = settings.overture_release
    dest = _dest(settings, release)
    (dest / "type=building").mkdir(parents=True)
    (dest / "type=building_part").mkdir(parents=True)

    monkeypatch.setattr(buildings, "table_exists", lambda *a, **k: False)
    monkeypatch.setattr(buildings, "ensure_schemas", lambda *a, **k: None)
    executed: list[str] = []
    monkeypatch.setattr(buildings, "execute_sql", lambda s, stmt, desc, **k: executed.append(stmt))

    calls: list[list[str]] = []

    def fake_run(cmd, **kwargs):
        calls.append(list(cmd))
        # Fail only the building_part ingest; parity: parts are optional.
        if "overture.buildingpart" in cmd:
            raise process.CommandFailed(cmd, 1, "boom")
        return subprocess.CompletedProcess(list(cmd), 0, "", "")

    monkeypatch.setattr(process, "run_with_retry", fake_run)

    # Must not raise despite the building_part failure.
    buildings.import_buildings(settings)

    # The building ingest + ANALYZE still happened.
    assert any("overture.building" in c for c in calls)
    assert "ANALYZE overture.building" in executed
