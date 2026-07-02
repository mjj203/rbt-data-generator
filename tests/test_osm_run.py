"""Tests for the imposm update supervisor (``rbt.importers.osm``)."""

from __future__ import annotations

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

    # Popen cwd is the imposm config directory.
    (fake_repo / "setup/data-sources/osm").mkdir(parents=True)

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
