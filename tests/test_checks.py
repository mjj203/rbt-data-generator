"""Tests for operational checks (``rbt.checks``)."""

from __future__ import annotations

import shutil
from pathlib import Path
from types import SimpleNamespace

import psycopg
import pytest

from rbt import checks
from rbt.config import load_settings


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


def _which_all(tool: str) -> str:
    return f"/usr/bin/{tool}"


# ---------------------------------------------------------------------------
# rbt health
# ---------------------------------------------------------------------------


def test_health_ok(fake_repo: Path, monkeypatch: pytest.MonkeyPatch, capsys) -> None:
    monkeypatch.setattr(psycopg, "connect", _connect_ok)
    monkeypatch.setattr(shutil, "which", _which_all)

    assert checks.health(load_settings()) == 0
    captured = capsys.readouterr()
    assert "OK: database reachable" in captured.out
    assert "WARN" not in captured.out


def test_health_database_failure_exits_1(
    fake_repo: Path, monkeypatch: pytest.MonkeyPatch, capsys
) -> None:
    monkeypatch.setattr(psycopg, "connect", _connect_fail)
    monkeypatch.setattr(shutil, "which", _which_all)

    assert checks.health(load_settings()) == 1
    assert "ERROR: database round-trip failed" in capsys.readouterr().err


def test_health_missing_tools_warn_but_stay_healthy(
    fake_repo: Path, monkeypatch: pytest.MonkeyPatch, capsys
) -> None:
    monkeypatch.setattr(psycopg, "connect", _connect_ok)
    monkeypatch.setattr(shutil, "which", lambda tool: None)

    assert checks.health(load_settings()) == 0
    captured = capsys.readouterr()
    assert "WARN: tippecanoe not on PATH" in captured.out
    assert "WARN: imposm not on PATH" in captured.out


# ---------------------------------------------------------------------------
# rbt validate
# ---------------------------------------------------------------------------

# Required paths the fake_repo fixture does not already provide.
_REQUIRED_EXTRA_PATHS = (
    "setup/data-sources/osm/imposm-config.json",
    "setup/data-sources/osm/imposm-mapping.yaml",
)


def _complete_structure(root: Path) -> None:
    for rel in _REQUIRED_EXTRA_PATHS:
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("placeholder\n", encoding="utf-8")


def _disk(free_gb: int):
    def _usage(path: object) -> SimpleNamespace:
        free = free_gb * 1024**3
        return SimpleNamespace(total=free * 2, used=free, free=free)

    return _usage


@pytest.fixture
def healthy_env(fake_repo: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """fake_repo with every validate() probe stubbed to succeed."""
    _complete_structure(fake_repo)
    monkeypatch.setattr(psycopg, "connect", _connect_ok)
    monkeypatch.setattr(shutil, "which", _which_all)
    monkeypatch.setattr(checks, "_tool_version", lambda tool: "v0.0-test")
    monkeypatch.setattr(shutil, "disk_usage", _disk(500))
    return fake_repo


def test_validate_all_green(healthy_env: Path, capsys) -> None:
    assert checks.validate(load_settings()) == 0
    captured = capsys.readouterr()
    assert "Exists: config/layers.yml" in captured.out
    assert "Database connection successful" in captured.out
    assert "Required path missing" not in captured.err


def test_validate_missing_required_tool_exits_1(
    healthy_env: Path, monkeypatch: pytest.MonkeyPatch, capsys
) -> None:
    monkeypatch.setattr(
        shutil, "which", lambda tool: None if tool == "tippecanoe" else f"/usr/bin/{tool}"
    )
    assert checks.validate(load_settings()) == 1
    assert "tippecanoe not found" in capsys.readouterr().err


def test_validate_missing_optional_tool_only_warns(
    healthy_env: Path, monkeypatch: pytest.MonkeyPatch, capsys
) -> None:
    monkeypatch.setattr(
        shutil, "which", lambda tool: None if tool == "docker" else f"/usr/bin/{tool}"
    )
    assert checks.validate(load_settings()) == 0
    assert "docker not found (optional)" in capsys.readouterr().out


def test_validate_database_connection_error_exits_1(
    healthy_env: Path, monkeypatch: pytest.MonkeyPatch, capsys
) -> None:
    monkeypatch.setattr(psycopg, "connect", _connect_fail)
    assert checks.validate(load_settings()) == 1
    assert "Cannot connect to database" in capsys.readouterr().err


def test_validate_insufficient_disk_exits_1(
    healthy_env: Path, monkeypatch: pytest.MonkeyPatch, capsys
) -> None:
    monkeypatch.setattr(shutil, "disk_usage", _disk(1))
    assert checks.validate(load_settings()) == 1
    assert "Insufficient disk space" in capsys.readouterr().err


def test_validate_reports_missing_required_paths(
    fake_repo: Path, monkeypatch: pytest.MonkeyPatch, capsys
) -> None:
    # Remove the imposm files so validate has something to report (fake_repo
    # ships imposm-config.json for the `rbt osm run` tests).
    for rel in _REQUIRED_EXTRA_PATHS:
        (fake_repo / rel).unlink(missing_ok=True)
    monkeypatch.setattr(psycopg, "connect", _connect_ok)
    monkeypatch.setattr(shutil, "which", _which_all)
    monkeypatch.setattr(checks, "_tool_version", lambda tool: "v0.0-test")
    monkeypatch.setattr(shutil, "disk_usage", _disk(500))

    assert checks.validate(load_settings()) == 1
    captured = capsys.readouterr()
    for rel in _REQUIRED_EXTRA_PATHS:
        assert f"Required path missing: {rel}" in captured.err
    # Paths provided by fake_repo are recognised against the fixture root.
    assert "Exists: config/rbt.conf" in captured.out
    assert "Exists: setup/data-sources/schemas/physical/physical-core.sql" in captured.out
