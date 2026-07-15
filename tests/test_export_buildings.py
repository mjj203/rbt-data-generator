"""Tests for the DuckDB Overture buildings export (rbt.importers.buildings_export).

Mirrors the OSM/reference importer tests: golden ``duckdb`` argv + env via
``recorded_run``, plus behavioral tests (output validation, scratch-db cleanup)
driven by a fake run that materializes the output files the way DuckDB would.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest
from typer.testing import CliRunner

import rbt.process
from rbt.cli import app
from rbt.config import Settings, load_settings
from rbt.importers.buildings_export import OUTPUT_FILES, export_buildings

runner = CliRunner()


def _settings(out: Path) -> Settings:
    """Direct Settings pointed at a throwaway output dir (no load_settings)."""
    return Settings(
        retry_count=2,
        retry_delay=0,
        shared_log_dir=out / "logs",
        overture_export_dir=out,
        duckdb_temp_dir=out,
        overture_export_sql=Path("setup/data-sources/overture/duckdb-building-export.sql"),
    )


def _writing_run(out: Path, *, files=OUTPUT_FILES, make_db: bool = True):
    """A fake process.run_with_retry that creates what DuckDB would create."""

    def fake(cmd, **kwargs):
        if make_db:
            (out / "overture_buildings.db").write_bytes(b"scratch-db")
        for name in files:
            (out / name).write_bytes(b"fgb-data")
        return subprocess.CompletedProcess(list(cmd), 0, "", "")

    return fake


# ---------------------------------------------------------------------------
# Golden command / env (dry-run, via recorded_run + load_settings wiring)
# ---------------------------------------------------------------------------


def test_dry_run_golden(fake_repo: Path, recorded_run) -> None:
    settings = load_settings()
    export_buildings(settings, dry_run=True)

    [call] = recorded_run.calls
    db = settings.overture_export_dir / "overture_buildings.db"
    assert call["cmd"] == ["duckdb", str(db), "-f", str(settings.overture_export_sql)]
    assert call["retries"] == 1
    assert call["dry_run"] is True
    assert call["env"] == {
        "OUTPUT_DIR": str(settings.overture_export_dir),
        "OVERTURE_RELEASE": settings.overture_release,
        "OVERTURE_S3_BUCKET": settings.overture_s3_bucket,
        "DUCKDB_MEMORY_LIMIT": "200GB",
        "DUCKDB_MAX_TEMP_SIZE": "2900GB",
        "DUCKDB_TEMP_DIRECTORY": str(settings.duckdb_temp_dir),
    }
    log_file = call["log_file"]
    assert log_file.parent == settings.shared_log_dir
    assert log_file.name.startswith("buildings_export_duckdb_")
    assert log_file.name.endswith(".log")

    # dry-run must not create the output directory or any files.
    assert not settings.overture_export_dir.exists()


def test_env_overrides_flow_through(fake_repo: Path, recorded_run, monkeypatch, tmp_path) -> None:
    out = tmp_path / "bldg-out"
    monkeypatch.setenv("OVERTURE_EXPORT_DIR", str(out))
    monkeypatch.setenv("DUCKDB_MEMORY_LIMIT", "16GB")
    monkeypatch.setenv("OVERTURE_RELEASE", "2099-01-01.0")

    settings = load_settings()
    # DUCKDB_TEMP_DIRECTORY defaults to the resolved export dir.
    assert settings.duckdb_temp_dir == out

    export_buildings(settings, dry_run=True)
    [call] = recorded_run.calls
    assert call["env"]["OUTPUT_DIR"] == str(out)
    assert call["env"]["DUCKDB_MEMORY_LIMIT"] == "16GB"
    assert call["env"]["OVERTURE_RELEASE"] == "2099-01-01.0"
    assert call["env"]["DUCKDB_TEMP_DIRECTORY"] == str(out)


def test_release_argument_overrides_settings(fake_repo: Path, recorded_run) -> None:
    settings = load_settings()
    export_buildings(settings, release="2030-12-31.0", dry_run=True)
    [call] = recorded_run.calls
    assert call["env"]["OVERTURE_RELEASE"] == "2030-12-31.0"


def test_dry_run_preserves_existing_outputs(tmp_path: Path, recorded_run) -> None:
    out = tmp_path / "out"
    out.mkdir()
    stale = out / OUTPUT_FILES[0]
    stale.write_bytes(b"stale")

    export_buildings(_settings(out), dry_run=True)

    # dry-run does not remove prior outputs.
    assert stale.read_bytes() == b"stale"
    assert recorded_run.calls[0]["dry_run"] is True


# ---------------------------------------------------------------------------
# Real-run behavior (validation + scratch-db cleanup)
# ---------------------------------------------------------------------------


def test_success_validates_and_removes_scratch_db(tmp_path: Path, monkeypatch) -> None:
    out = tmp_path / "out"
    monkeypatch.setattr(rbt.process, "run_with_retry", _writing_run(out))

    export_buildings(_settings(out))

    for name in OUTPUT_FILES:
        assert (out / name).is_file()
    # Scratch DuckDB database is removed on success.
    assert not (out / "overture_buildings.db").exists()


def test_keep_db_retains_scratch_db(tmp_path: Path, monkeypatch) -> None:
    out = tmp_path / "out"
    monkeypatch.setattr(rbt.process, "run_with_retry", _writing_run(out))

    export_buildings(_settings(out), keep_db=True)

    assert (out / "overture_buildings.db").is_file()


def test_missing_output_raises_and_keeps_db(tmp_path: Path, monkeypatch) -> None:
    out = tmp_path / "out"
    # Write only five of the six expected files.
    monkeypatch.setattr(rbt.process, "run_with_retry", _writing_run(out, files=OUTPUT_FILES[:-1]))

    with pytest.raises(RuntimeError, match=OUTPUT_FILES[-1]):
        export_buildings(_settings(out))

    # The scratch db is left in place for debugging on failure.
    assert (out / "overture_buildings.db").is_file()


def test_empty_output_file_fails_validation(tmp_path: Path, monkeypatch) -> None:
    out = tmp_path / "out"

    def fake(cmd, **kwargs):
        (out / "overture_buildings.db").write_bytes(b"db")
        for name in OUTPUT_FILES:
            (out / name).write_bytes(b"" if name == OUTPUT_FILES[2] else b"data")
        return subprocess.CompletedProcess(list(cmd), 0, "", "")

    monkeypatch.setattr(rbt.process, "run_with_retry", fake)
    with pytest.raises(RuntimeError, match=OUTPUT_FILES[2]):
        export_buildings(_settings(out))


# ---------------------------------------------------------------------------
# CLI wiring
# ---------------------------------------------------------------------------


def test_cli_export_buildings_dry_run(fake_repo: Path, recorded_run) -> None:
    result = runner.invoke(app, ["--no-log-file", "export", "buildings", "--dry-run"])
    assert result.exit_code == 0, result.output
    [call] = recorded_run.calls
    assert call["cmd"][0] == "duckdb"
    assert call["dry_run"] is True
