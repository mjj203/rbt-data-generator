"""OSM data import and continuous updates.

- :func:`import_osm` delegates to the bash leaf script
  ``setup/data-sources/osm/import-osm-data.sh`` (planet download + imposm
  import — see the contract header in that script).
- :func:`run_updates` / :func:`update_status` / :func:`stop_updates` natively
  supervise ``imposm run`` (replacing ``production/update-osm.sh``). The
  supervisor often runs as container PID 1, so it forwards SIGTERM/SIGINT to
  the child and escalates to SIGKILL after a grace period — unlike the old
  bash ``pkill -f "imposm.*run"``, which could match unrelated processes.
"""

from __future__ import annotations

import contextlib
import os
import signal
import subprocess
import time
from pathlib import Path
from types import FrameType

import psycopg

from ..bash import delegate
from ..config import Settings
from ..logging import get_logger
from ..process import CommandFailed

log = get_logger(__name__)

_TERMINATE_GRACE_SECONDS = 30.0


def import_osm(settings: Settings, args: list[str], *, dry_run: bool = False) -> None:
    delegate(
        "setup/data-sources/osm/import-osm-data.sh",
        args,
        settings,
        dry_run=dry_run,
    )


def _pidfile(settings: Settings) -> Path:
    return settings.shared_temp_dir / "imposm-run.pid"


def _read_pid(settings: Settings) -> int | None:
    pidfile = _pidfile(settings)
    try:
        pid = int(pidfile.read_text(encoding="utf-8").strip())
    except (FileNotFoundError, ValueError):
        return None
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, PermissionError):
        pidfile.unlink(missing_ok=True)
        return None
    return pid


def run_updates(settings: Settings, *, dry_run: bool = False) -> None:
    """Run ``imposm run`` in the foreground, supervising until stopped.

    Blocks indefinitely (this is the ``rbt-osm-updates`` container's main
    process). SIGTERM/SIGINT terminate the child gracefully; a non-zero child
    exit that wasn't signal-initiated raises :class:`CommandFailed`.
    """
    config_path = settings.osm_config_file
    if not config_path.is_absolute():
        config_path = settings.project_root / config_path
    cmd = ["imposm", "run", "-config", str(config_path)]

    if dry_run:
        log.info("[dry-run] %s", " ".join(cmd))
        return

    existing = _read_pid(settings)
    if existing is not None:
        raise RuntimeError(f"imposm run already active (pid {existing}); use `rbt osm stop` first")

    settings.shared_temp_dir.mkdir(parents=True, exist_ok=True)
    log.info("starting continuous OSM updates: %s", " ".join(cmd))

    process = subprocess.Popen(  # noqa: S603 - fixed command list
        cmd,
        cwd=config_path.parent,
        env={**os.environ, **settings.subprocess_env()},
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    pidfile = _pidfile(settings)
    pidfile.write_text(str(process.pid), encoding="utf-8")

    stopping = False

    def _shutdown(signum: int, _frame: FrameType | None) -> None:
        nonlocal stopping
        stopping = True
        log.info("received signal %d, stopping imposm (pid %d)", signum, process.pid)
        process.terminate()

    previous_handlers = {
        signal.SIGTERM: signal.signal(signal.SIGTERM, _shutdown),
        signal.SIGINT: signal.signal(signal.SIGINT, _shutdown),
    }
    try:
        assert process.stdout is not None
        for line in process.stdout:
            log.info("[imposm] %s", line.rstrip())
        returncode = process.wait(timeout=_TERMINATE_GRACE_SECONDS if stopping else None)
    except subprocess.TimeoutExpired:
        log.warning("imposm did not exit within %.0fs; killing", _TERMINATE_GRACE_SECONDS)
        process.kill()
        returncode = process.wait()
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
        pidfile.unlink(missing_ok=True)
        if process.stdout is not None:
            process.stdout.close()

    # A negative return code means the child was killed by a signal. Terminating
    # via SIGTERM/SIGINT is a clean stop whether it came from this supervisor's
    # own handler (`stopping`) or directly from `rbt osm stop`, which signals the
    # child recorded in the pidfile. Only an unexpected non-zero exit is a failure.
    if stopping or returncode in (-signal.SIGTERM, -signal.SIGINT):
        log.info("OSM updates stopped (exit %d)", returncode)
        return
    if returncode != 0:
        raise CommandFailed(cmd, returncode)


def update_status(settings: Settings) -> int:
    """Report whether imposm is running and the last applied update."""
    pid = _read_pid(settings)
    if pid is not None:
        log.info("✅ OSM updates are running (pid %d)", pid)
    else:
        log.info("❌ OSM updates are not running")

    try:
        with psycopg.connect(settings.psql_conn_string(), connect_timeout=10) as conn:
            row = conn.execute("SELECT MAX(last_modified) FROM imposm3_log").fetchone()
            last_update = row[0] if row else None
    except psycopg.Error as exc:
        log.warning("could not query imposm3_log: %s", exc)
        last_update = None
    log.info("Last OSM update: %s", last_update or "unknown")
    return 0 if pid is not None else 1


def stop_updates(settings: Settings) -> int:
    """Signal a running ``rbt osm run`` supervisor via its pidfile."""
    pid = _read_pid(settings)
    if pid is None:
        log.warning("no running imposm supervisor found")
        return 1

    log.info("stopping OSM updates (pid %d)", pid)
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + _TERMINATE_GRACE_SECONDS
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            log.info("OSM updates stopped")
            return 0
        time.sleep(0.5)

    log.warning("pid %d did not exit within grace period; sending SIGKILL", pid)
    with contextlib.suppress(ProcessLookupError):
        os.kill(pid, signal.SIGKILL)
    return 0


__all__ = ["import_osm", "run_updates", "stop_updates", "update_status"]
