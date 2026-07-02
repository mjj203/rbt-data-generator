"""Tests for setup orchestration (``rbt.setup_db``)."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import psycopg
import pytest
from typer.testing import CliRunner

from rbt import setup_db
from rbt.cli import app
from rbt.config import Settings, load_settings
from rbt.importers import buildings, geonames, osm, reference
from rbt.layers import load_registry

runner = CliRunner()

# ---------------------------------------------------------------------------
# SetupSteps
# ---------------------------------------------------------------------------


def test_setup_steps_all_selects_everything() -> None:
    steps = setup_db.SetupSteps.all()
    assert steps == setup_db.SetupSteps(
        bootstrap=True,
        import_osm=True,
        import_reference=True,
        import_geonames=True,
        import_buildings=True,
        process_schemas=True,
    )
    assert steps.any_selected()


def test_setup_steps_any_selected() -> None:
    assert not setup_db.SetupSteps().any_selected()
    assert setup_db.SetupSteps(process_schemas=True).any_selected()
    assert setup_db.SetupSteps(bootstrap=True).any_selected()


# ---------------------------------------------------------------------------
# run_setup sequencing
# ---------------------------------------------------------------------------


@pytest.fixture
def call_order(monkeypatch: pytest.MonkeyPatch) -> list[str]:
    """Replace bootstrap, the four importers, and run_schemas with recorders."""
    calls: list[str] = []

    def _record(name: str):
        def _fake(settings: Settings, *args: object, **kwargs: object) -> None:
            calls.append(name)

        return _fake

    monkeypatch.setattr(setup_db, "bootstrap", _record("bootstrap"))
    monkeypatch.setattr(osm, "import_osm", _record("osm"))
    monkeypatch.setattr(reference, "import_reference", _record("reference"))
    monkeypatch.setattr(geonames, "import_geonames", _record("geonames"))
    monkeypatch.setattr(buildings, "import_buildings", _record("buildings"))
    monkeypatch.setattr(setup_db, "run_schemas", _record("schemas"))
    return calls


def test_run_setup_full_dependency_order(fake_repo: Path, call_order: list[str]) -> None:
    setup_db.run_setup(load_settings(), load_registry(), setup_db.SetupSteps.all())
    assert call_order == ["bootstrap", "osm", "reference", "geonames", "buildings", "schemas"]


def test_run_setup_skips_deselected_steps(fake_repo: Path, call_order: list[str]) -> None:
    steps = setup_db.SetupSteps(import_geonames=True, process_schemas=True)
    setup_db.run_setup(load_settings(), load_registry(), steps)
    assert call_order == ["geonames", "schemas"]


def test_run_setup_nothing_selected_runs_nothing(fake_repo: Path, call_order: list[str]) -> None:
    setup_db.run_setup(load_settings(), load_registry(), setup_db.SetupSteps())
    assert call_order == []


# ---------------------------------------------------------------------------
# OSM import args (the leaf script exits non-zero when called with no stage flag)
# ---------------------------------------------------------------------------


@pytest.fixture
def osm_dispatch(monkeypatch: pytest.MonkeyPatch) -> list[list[str]]:
    """Capture the args run_setup hands to the OSM importer."""
    calls: list[list[str]] = []

    def _fake(settings: Settings, args: list[str], *, dry_run: bool = False) -> None:
        calls.append(list(args))

    monkeypatch.setattr(osm, "import_osm", _fake)
    return calls


def test_run_setup_defaults_osm_args_to_all(fake_repo: Path, osm_dispatch: list[list[str]]) -> None:
    steps = setup_db.SetupSteps(import_osm=True)
    setup_db.run_setup(load_settings(), load_registry(), steps)
    assert osm_dispatch == [["--all"]]


def test_run_setup_passes_explicit_osm_args(fake_repo: Path, osm_dispatch: list[list[str]]) -> None:
    steps = setup_db.SetupSteps(import_osm=True)
    setup_db.run_setup(load_settings(), load_registry(), steps, osm_args=["--import"])
    assert osm_dispatch == [["--import"]]


@pytest.fixture
def osm_leaf_script(fake_repo: Path) -> Path:
    script = fake_repo / "setup/data-sources/osm/import-osm-data.sh"
    script.parent.mkdir(parents=True, exist_ok=True)
    script.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    script.chmod(0o755)
    return fake_repo


def test_setup_cli_osm_step_dispatches_all_by_default(osm_leaf_script: Path, recorded_run) -> None:
    result = runner.invoke(app, ["--no-log-file", "setup", "--import-osm-data"])
    assert result.exit_code == 0, result.output

    script = osm_leaf_script.resolve() / "setup/data-sources/osm/import-osm-data.sh"
    [call] = recorded_run.calls
    assert call["cmd"] == ["bash", str(script), "--all"]


def test_setup_cli_osm_arg_passthrough(osm_leaf_script: Path, recorded_run) -> None:
    result = runner.invoke(
        app,
        ["--no-log-file", "setup", "--import-osm-data", "--osm-arg=--import"],
    )
    assert result.exit_code == 0, result.output

    script = osm_leaf_script.resolve() / "setup/data-sources/osm/import-osm-data.sh"
    [call] = recorded_run.calls
    assert call["cmd"] == ["bash", str(script), "--import"]


# ---------------------------------------------------------------------------
# bootstrap (dry-run branch only — never touches a real database)
# ---------------------------------------------------------------------------


def test_bootstrap_dry_run_never_connects(fake_repo: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    def _no_connect(*args: object, **kwargs: object) -> None:
        raise AssertionError("psycopg.connect must not be called in dry-run")

    monkeypatch.setattr(psycopg, "connect", _no_connect)
    setup_db.bootstrap(load_settings(), dry_run=True)


class _RecordingCursor:
    def __init__(self, result: object) -> None:
        self._result = result

    def fetchone(self) -> object:
        return self._result


class _RecordingConnection:
    """Fake psycopg connection that records executed statements as SQL text."""

    def __init__(self, executed: list[str], *, db_exists: bool) -> None:
        self._executed = executed
        self._db_exists = db_exists

    def __enter__(self) -> _RecordingConnection:
        return self

    def __exit__(self, *exc_info: object) -> None:
        return None

    def execute(self, query: Any, params: Any = None) -> _RecordingCursor:
        text = query if isinstance(query, str) else query.as_string(None)
        self._executed.append(text)
        if isinstance(query, str) and "pg_database" in query:
            return _RecordingCursor((1,) if self._db_exists else None)
        return _RecordingCursor((1,))


def test_bootstrap_creates_database_and_extensions(
    fake_repo: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    executed: list[str] = []
    monkeypatch.setattr(
        psycopg, "connect", lambda *a, **k: _RecordingConnection(executed, db_exists=False)
    )
    settings = load_settings()

    setup_db.bootstrap(settings)

    assert any("pg_database" in stmt for stmt in executed)
    assert any("CREATE DATABASE" in stmt for stmt in executed)
    ext_stmts = [stmt for stmt in executed if "CREATE EXTENSION" in stmt]
    assert len(ext_stmts) == len(settings.database_extensions)
    for extension in settings.database_extensions:
        assert any(extension in stmt for stmt in ext_stmts)


def test_bootstrap_skips_create_when_database_exists(
    fake_repo: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    executed: list[str] = []
    monkeypatch.setattr(
        psycopg, "connect", lambda *a, **k: _RecordingConnection(executed, db_exists=True)
    )

    setup_db.bootstrap(load_settings())

    assert any("pg_database" in stmt for stmt in executed)
    # Database already present, so no CREATE DATABASE, but extensions are ensured.
    assert not any("CREATE DATABASE" in stmt for stmt in executed)
    assert any("CREATE EXTENSION" in stmt for stmt in executed)
