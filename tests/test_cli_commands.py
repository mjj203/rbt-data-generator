"""CLI-level coverage for operational commands not exercised elsewhere:
``rbt validate``, ``rbt health``, ``rbt smoke``, ``rbt osm status``,
and ``rbt schema run``.

Unlike ``tests/test_checks.py`` (which calls the underlying functions
directly), these tests go through ``CliRunner`` to confirm the Typer wiring
(argument parsing, exit-code propagation) works end to end.
"""

from __future__ import annotations

import shutil
from pathlib import Path

import psycopg
import pytest
from typer.testing import CliRunner

from rbt import checks
from rbt.cli import app

runner = CliRunner()


class _FakeCursor:
    def fetchone(self) -> tuple[int]:
        return (1,)


class _FakeConnection:
    def __enter__(self) -> _FakeConnection:
        return self

    def __exit__(self, *exc_info: object) -> None:
        return None

    def execute(self, *args: object, **kwargs: object) -> _FakeCursor:
        return _FakeCursor()


def _connect_ok(conninfo: str, **kwargs: object) -> _FakeConnection:
    return _FakeConnection()


def _connect_fail(conninfo: str, **kwargs: object) -> _FakeConnection:
    raise psycopg.OperationalError("connection refused")


# ---------------------------------------------------------------------------
# rbt health / rbt validate
# ---------------------------------------------------------------------------


def test_cli_health_ok(fake_repo: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(psycopg, "connect", _connect_ok)
    result = runner.invoke(app, ["--no-log-file", "health"])
    assert result.exit_code == 0, result.output


def test_cli_health_database_failure_exits_1(
    fake_repo: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(psycopg, "connect", _connect_fail)
    result = runner.invoke(app, ["--no-log-file", "health"])
    assert result.exit_code == 1


def test_cli_validate_missing_tools_exits_1(
    fake_repo: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # No stubbing of psql/ogr2ogr/etc.: forcing shutil.which to fail for every
    # tool keeps this deterministic regardless of what's on the runner's PATH.
    monkeypatch.setattr(shutil, "which", lambda tool: None)
    result = runner.invoke(app, ["--no-log-file", "validate"])
    assert result.exit_code == 1


# ---------------------------------------------------------------------------
# rbt smoke
# ---------------------------------------------------------------------------


def test_cli_smoke_happy_path(
    fake_repo: Path, monkeypatch: pytest.MonkeyPatch, recorded_run
) -> None:
    """``rbt smoke`` wires validate -> bootstrap -> schema -> tile dry-runs -> DB.

    ``validate``/``bootstrap`` are stubbed (they are exercised in their own
    dedicated tests); the schema and tile-generation steps run for real
    against ``recorded_run``, which intercepts every subprocess call.
    """
    monkeypatch.setattr(checks, "validate", lambda settings: 0)
    monkeypatch.setattr(checks, "bootstrap", lambda settings: None)
    monkeypatch.setattr(psycopg, "connect", _connect_ok)

    result = runner.invoke(app, ["--no-log-file", "smoke"])
    assert result.exit_code == 0, result.output
    assert recorded_run.calls  # schema + tile dry-run commands were dispatched


def test_cli_smoke_aborts_when_validate_fails(
    fake_repo: Path, monkeypatch: pytest.MonkeyPatch, recorded_run
) -> None:
    monkeypatch.setattr(checks, "validate", lambda settings: 1)
    result = runner.invoke(app, ["--no-log-file", "smoke"])
    assert result.exit_code == 1
    assert recorded_run.calls == []


# ---------------------------------------------------------------------------
# rbt osm status
# ---------------------------------------------------------------------------


def test_cli_osm_status_no_pidfile_exits_1(
    fake_repo: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # No real database is reachable; update_status() must degrade gracefully
    # (warn + report "unknown") rather than hang or raise.
    monkeypatch.setattr(psycopg, "connect", _connect_fail)
    result = runner.invoke(app, ["--no-log-file", "osm", "status"])
    assert result.exit_code == 1


# ---------------------------------------------------------------------------
# rbt schema run
# ---------------------------------------------------------------------------


def test_cli_schema_run_dispatches_psql(fake_repo: Path, recorded_run) -> None:
    result = runner.invoke(app, ["--no-log-file", "schema", "run", "physical"])
    assert result.exit_code == 0, result.output
    [call] = recorded_run.calls
    assert call["cmd"] == ["psql", "-v", "ON_ERROR_STOP=1", "-f", "physical-core.sql"]


def test_cli_schema_run_bare_requires_explicit_selection(fake_repo: Path, recorded_run) -> None:
    result = runner.invoke(app, ["--no-log-file", "schema", "run"])
    assert result.exit_code != 0
    assert "--all" in result.output
    # A bare `schema run` must not silently execute every schema.
    assert recorded_run.calls == []


def test_cli_schema_run_all_dispatches_every_schema(fake_repo: Path, recorded_run) -> None:
    result = runner.invoke(app, ["--no-log-file", "schema", "run", "--all"])
    assert result.exit_code == 0, result.output
    assert {call["cmd"][-1] for call in recorded_run.calls} == {
        "physical-core.sql",
        "cultural-core.sql",
    }


def test_cli_setup_all_with_step_flag_is_rejected(fake_repo: Path, recorded_run) -> None:
    result = runner.invoke(
        app, ["--no-log-file", "setup", "--all", "--setup-database", "--dry-run"]
    )
    assert result.exit_code != 0
    assert "--all" in result.output
    assert recorded_run.calls == []
