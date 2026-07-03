"""Tests for the imposm update supervisor (``rbt.importers.osm``)."""

from __future__ import annotations

import json
import logging
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

import psycopg
import pytest

from rbt.config import Settings, load_settings
from rbt.importers import osm as osm_mod


def _pidfile(settings: Settings) -> Path:
    return settings.shared_temp_dir / "imposm-run.pid"


# ---------------------------------------------------------------------------
# dry-run
# ---------------------------------------------------------------------------


def test_run_updates_dry_run_skips_popen(fake_repo: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    def _boom(*args: object, **kwargs: object) -> None:
        raise AssertionError("subprocess.Popen must not be called in dry-run")

    monkeypatch.setattr(subprocess, "Popen", _boom)
    settings = load_settings()
    osm_mod.run_updates(settings, dry_run=True)
    assert not _pidfile(settings).exists()


def test_run_updates_dry_run_redacts_connection(
    fake_repo: Path, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    monkeypatch.setenv("PG_PASS", "s3cret-pw")
    settings = load_settings()
    with caplog.at_level(logging.INFO):
        osm_mod.run_updates(settings, dry_run=True)
    assert "s3cret-pw" not in caplog.text
    assert "<generated>" in caplog.text


# ---------------------------------------------------------------------------
# generated run config
# ---------------------------------------------------------------------------


def test_build_run_config_merges_settings(
    fake_repo: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """`imposm run` gets connection/mapping/dirs/srid merged over the base config."""
    monkeypatch.setenv("PG_PASS", "s3cret-pw")
    monkeypatch.setenv("OSM_CACHE_DIR", "/app/output/osm/cache")
    monkeypatch.setenv("OSM_DIFF_DIR", "/app/output/osm/diff")
    settings = load_settings()

    config = osm_mod._build_run_config(settings)

    # the committed replication settings survive the merge...
    assert config["replication_url"] == "https://planet.openstreetmap.org/replication/day/"
    assert config["replication_interval"] == "24h"
    assert config["diff_state_before"] == "24h"
    # ...and everything imposm needs to actually apply diffs is added.
    assert config["connection"] == settings.imposm_connection()
    assert "s3cret-pw" in str(config["connection"])  # imposm needs it embedded
    assert config["mapping"] == str(fake_repo / "setup/data-sources/osm/imposm-mapping.yaml")
    assert config["cachedir"] == "/app/output/osm/cache"
    assert config["diffdir"] == "/app/output/osm/diff"
    assert config["srid"] == settings.osm_srid


def test_run_updates_passes_generated_config(
    fake_repo: Path, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    """The supervisor hands imposm a generated config file and removes it after exit."""
    bindir = fake_repo / "fakebin"
    bindir.mkdir()
    captured_config = fake_repo / "captured-config.json"
    captured_argv = fake_repo / "captured-argv.txt"
    shim = bindir / "imposm"
    # $1=run $2=-config $3=<generated path>; record both the path and its contents.
    shim.write_text(
        f'#!/bin/sh\nprintf \'%s\' "$3" > "{captured_argv}"\ncat "$3" > "{captured_config}"\n',
        encoding="utf-8",
    )
    shim.chmod(0o755)
    monkeypatch.setenv("PATH", f"{bindir}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("PG_PASS", "s3cret-pw")
    settings = load_settings()

    with caplog.at_level(logging.INFO):
        osm_mod.run_updates(settings)

    config = json.loads(captured_config.read_text(encoding="utf-8"))
    assert config["connection"] == settings.imposm_connection()
    assert config["mapping"] == str(fake_repo / "setup/data-sources/osm/imposm-mapping.yaml")
    assert config["cachedir"] == str(settings.osm_cache_dir)
    assert config["diffdir"] == str(settings.osm_diff_dir)
    assert config["srid"] == settings.osm_srid
    assert config["replication_url"] == "https://planet.openstreetmap.org/replication/day/"
    # the generated temp file is cleaned up once the supervisor exits, and the
    # password never reaches the logs (it travels in the 0600 file, not argv).
    assert not Path(captured_argv.read_text(encoding="utf-8")).exists()
    assert "s3cret-pw" not in caplog.text


# ---------------------------------------------------------------------------
# pidfile handling
# ---------------------------------------------------------------------------


def test_read_pid_missing_pidfile_returns_none(fake_repo: Path) -> None:
    assert osm_mod._read_pid(load_settings()) is None


def test_read_pid_garbage_pidfile_returns_none(fake_repo: Path) -> None:
    settings = load_settings()
    pidfile = _pidfile(settings)
    pidfile.parent.mkdir(parents=True, exist_ok=True)
    pidfile.write_text("not-a-pid", encoding="utf-8")
    assert osm_mod._read_pid(settings) is None


def test_read_pid_stale_pid_removes_pidfile(fake_repo: Path) -> None:
    # Use the pid of a real child that has already exited and been reaped,
    # rather than guessing at an unused pid.
    child = subprocess.Popen([sys.executable, "-c", "pass"])  # noqa: S603
    child.wait()

    settings = load_settings()
    pidfile = _pidfile(settings)
    pidfile.parent.mkdir(parents=True, exist_ok=True)
    pidfile.write_text(str(child.pid), encoding="utf-8")

    assert osm_mod._read_pid(settings) is None
    assert not pidfile.exists()


def test_run_updates_refuses_when_pid_is_live(fake_repo: Path) -> None:
    settings = load_settings()
    pidfile = _pidfile(settings)
    pidfile.parent.mkdir(parents=True, exist_ok=True)
    pidfile.write_text(str(os.getpid()), encoding="utf-8")

    with pytest.raises(RuntimeError, match="already active"):
        osm_mod.run_updates(settings)
    assert pidfile.exists()


def test_stop_updates_returns_1_when_idle(fake_repo: Path) -> None:
    assert osm_mod.stop_updates(load_settings()) == 1


class _StatusCursor:
    def __init__(self, row: object) -> None:
        self._row = row

    def fetchone(self) -> object:
        return self._row


class _StatusConnection:
    def __init__(self, row: object) -> None:
        self._row = row

    def __enter__(self) -> _StatusConnection:
        return self

    def __exit__(self, *exc_info: object) -> None:
        return None

    def execute(self, *args: object, **kwargs: object) -> _StatusCursor:
        return _StatusCursor(self._row)


def test_update_status_running_reports_last_update(
    fake_repo: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(osm_mod, "_read_pid", lambda settings: 4321)
    monkeypatch.setattr(
        psycopg, "connect", lambda *a, **k: _StatusConnection(("2026-07-02T00:00:00",))
    )

    # A live supervisor pid means status 0 (running).
    assert osm_mod.update_status(load_settings()) == 0


def test_update_status_not_running_returns_1(
    fake_repo: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(osm_mod, "_read_pid", lambda settings: None)
    monkeypatch.setattr(psycopg, "connect", lambda *a, **k: _StatusConnection(None))

    assert osm_mod.update_status(load_settings()) == 1


# ---------------------------------------------------------------------------
# full signal path with a real child process
# ---------------------------------------------------------------------------


class _SignalShim:
    """Stand-in for the ``signal`` module inside ``rbt.importers.osm``.

    ``signal.signal`` only works in the main thread, but this test runs the
    supervisor in a worker thread; the constants stay real so ``os.kill``
    still sends genuine signals.
    """

    SIGTERM = signal.SIGTERM
    SIGINT = signal.SIGINT
    SIGKILL = signal.SIGKILL

    @staticmethod
    def signal(signum: int, handler: object) -> object:
        return signal.SIG_DFL


def test_stop_updates_terminates_running_supervisor(
    fake_repo: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    bindir = fake_repo / "fakebin"
    bindir.mkdir()
    shim = bindir / "imposm"
    # ``exec`` so SIGTERM hits the sleeping process directly and the stdout
    # pipe closes as soon as it dies (no orphan keeping the supervisor alive).
    shim.write_text("#!/bin/sh\nexec sleep 30\n", encoding="utf-8")
    shim.chmod(0o755)
    monkeypatch.setenv("PATH", f"{bindir}{os.pathsep}{os.environ['PATH']}")

    monkeypatch.setattr(osm_mod, "signal", _SignalShim)
    settings = load_settings()
    pidfile = _pidfile(settings)

    outcome: list[Exception | None] = []

    def _supervise() -> None:
        try:
            osm_mod.run_updates(settings)
            outcome.append(None)
        except Exception as exc:  # noqa: BLE001 - recorded for assertion
            outcome.append(exc)

    worker = threading.Thread(target=_supervise, daemon=True)
    worker.start()

    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline and not pidfile.exists():
        time.sleep(0.02)
    assert pidfile.exists(), "supervisor never wrote its pidfile"

    assert osm_mod.stop_updates(settings) == 0

    worker.join(timeout=5.0)
    assert not worker.is_alive(), "supervisor did not exit after stop_updates"
    assert not pidfile.exists(), "pidfile was not cleaned up"

    # `rbt osm stop` SIGTERMs the child recorded in the pidfile. run_updates
    # treats a SIGTERM/SIGINT child exit as a clean stop (not CommandFailed),
    # so the supervisor returns normally.
    assert outcome == [None]
