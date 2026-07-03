"""OSM data import and continuous updates.

- The native import stages (:func:`download_planet`, :func:`download_diffs`,
  :func:`merge_diffs`, :func:`apply_changes`, :func:`import_planet`,
  :func:`import_diffs`) port ``setup/data-sources/osm/import-osm-data.sh``:
  aria2c multi-mirror planet download → daily replication diffs → osmium
  merge → osmosis apply → imposm import. :func:`run_import` sequences them by
  :class:`OsmStage`; ``OsmStage.all`` deliberately stops after the initial
  imposm import (continuous updates are ``rbt osm run``, not part of the
  import). Intermediates (``osm.osc.gz``, ``planet.osm.pbf``) are removed
  only after a *successful* full run — unlike the bash EXIT trap, which also
  deleted them when a single stage was run in isolation.
- :func:`run_updates` / :func:`update_status` / :func:`stop_updates` natively
  supervise ``imposm run`` (replacing ``production/update-osm.sh``). The
  supervisor often runs as container PID 1, so it forwards SIGTERM/SIGINT to
  the child and escalates to SIGKILL after a grace period — unlike the old
  bash ``pkill -f "imposm.*run"``, which could match unrelated processes.
"""

from __future__ import annotations

import contextlib
import json
import os
import re
import signal
import subprocess
import tempfile
import time
from collections.abc import Callable
from enum import Enum
from pathlib import Path
from types import FrameType

import psycopg

from .. import process
from ..config import Settings
from ..logging import get_logger
from ..process import CommandFailed
from . import _support

log = get_logger(__name__)

_TERMINATE_GRACE_SECONDS = 30.0

# ---------------------------------------------------------------------------
# Import pipeline constants (ported verbatim from import-osm-data.sh)
# ---------------------------------------------------------------------------

_PLANET_FILENAME = "planet-latest-v2.osm.pbf"
_MERGED_CHANGES_FILENAME = "osm.osc.gz"
_UPDATED_PLANET_FILENAME = "planet.osm.pbf"

_USER_AGENT = "OpenMapTiles download-osm 7.1.1 (https://github.com/openmaptiles/openmaptiles-tools)"

#: Planet PBF mirrors, in the bash script's order; aria2c races segments
#: across all of them.
PLANET_MIRRORS: tuple[str, ...] = (
    "https://ftp.spline.de/pub/openstreetmap/pbf/planet-latest.osm.pbf",
    "https://ftp5.gwdg.de/pub/misc/openstreetmap/planet.openstreetmap.org/pbf/planet-latest.osm.pbf",
    "https://ftp.fau.de/osm-planet/pbf/planet-latest.osm.pbf",
    "https://ftpmirror.your.org/pub/openstreetmap/pbf/planet-latest.osm.pbf",
    "https://download.bbbike.org/osm/planet/planet-latest.osm.pbf",
    "https://ftp.nluug.nl/maps/planet.openstreetmap.org/pbf/planet-latest.osm.pbf",
    "https://ftp.osuosl.org/pub/openstreetmap/pbf/planet-latest.osm.pbf",
    "https://ftp.snt.utwente.nl/pub/misc/openstreetmap/planet-latest.osm.pbf",
    "https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf",
)

# Daily replication diffs live under a fixed 000/004/ prefix for the sequence
# range this pipeline supports (seq -f "%03g" in the bash script).
_DIFF_URL_TEMPLATE = "https://planet.openstreetmap.org/replication/day/000/004/{seq:03d}.osc.gz"
_DIFF_MIN_BYTES = 1_048_576  # bash validated each diff at >= 1 MB
_MERGED_MIN_MB = 10
_APPLY_PLANET_MIN_MB = 50_000  # planet-sized floor used by apply-changes

_NUMERIC_OSC_RE = re.compile(r"^(\d+)\.osc\.gz$")


class OsmStage(str, Enum):
    """OSM import pipeline stages (values mirror the bash script's flags)."""

    all = "all"
    download_planet = "download-planet"
    download_diffs = "download-diffs"
    merge_diffs = "merge-diffs"
    apply_changes = "apply-changes"
    import_ = "import"
    import_diff = "import-diff"


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------


def _resolve_path(settings: Settings, path: Path) -> Path:
    return path if path.is_absolute() else settings.project_root / path


def _require_file(path: Path, min_mb: int) -> None:
    if not _support.validate_min_size(path, min_mb):
        raise FileNotFoundError(f"{path} is missing or smaller than {min_mb}MB")


def _numeric_diff_files(settings: Settings) -> list[Path]:
    """Numerically sorted ``NNN.osc.gz`` files in the data dir.

    Excludes the merged ``osm.osc.gz`` on purpose, and sorts numerically so
    sequence 1000 follows 999 (the bash glob sorted lexically and broke
    past three digits).
    """
    matched: list[tuple[int, Path]] = []
    for path in settings.osm_data_dir.glob("*.osc.gz"):
        match = _NUMERIC_OSC_RE.match(path.name)
        if match:
            matched.append((int(match.group(1)), path))
    return [path for _, path in sorted(matched)]


# ---------------------------------------------------------------------------
# Stage 1: planet download
# ---------------------------------------------------------------------------


def download_planet(settings: Settings, *, dry_run: bool = False) -> None:
    """Download the planet PBF via aria2c racing all mirrors."""
    planet = settings.osm_data_dir / _PLANET_FILENAME
    if _support.validate_min_size(planet, settings.osm_min_pbf_size_mb):
        log.info("planet file already exists and is valid — skipping download: %s", planet)
        return

    cmd = [
        "aria2c",
        "--file-allocation=falloc",
        f"--max-concurrent-downloads={settings.aria2c_max_downloads}",
        f"--max-connection-per-server={settings.aria2c_max_connections}",
        f"--split={settings.aria2c_splits}",
        "--http-accept-gzip=true",
        f"--user-agent={_USER_AGENT}",
        f"--dir={settings.osm_data_dir}",
        f"--out={_PLANET_FILENAME}",
        "--auto-file-renaming=false",
        "--continue=true",
        "--max-tries=3",
        "--retry-wait=10",
        "--timeout=300",
        "--summary-interval=60",
        *PLANET_MIRRORS,
    ]
    if not dry_run:
        settings.osm_data_dir.mkdir(parents=True, exist_ok=True)
    process.run_with_retry(
        cmd,
        retries=settings.retry_count,
        delay=settings.retry_delay,
        log_file=_support.job_log_file(settings, "osm", "download_planet"),
        dry_run=dry_run,
    )
    if dry_run:
        return
    if settings.osm_validate_downloads and not _support.validate_min_size(
        planet, settings.osm_min_pbf_size_mb
    ):
        raise _support.ImportFailed([f"planet download validation: {planet}"])


# ---------------------------------------------------------------------------
# Stage 2: replication diffs
# ---------------------------------------------------------------------------


def _download_diff_job(url: str, dest: Path, *, dry_run: bool) -> Callable[[], None]:
    def action() -> None:
        # Existing files >= 1 MB are skipped inside download() (resume
        # semantics, matching the bash validate_file <file> 1 short-circuit).
        _support.download(url, dest, min_bytes=_DIFF_MIN_BYTES, dry_run=dry_run)

    return action


def download_diffs(
    settings: Settings,
    start_seq: int | None = None,
    end_seq: int | None = None,
    *,
    dry_run: bool = False,
) -> None:
    """Download daily replication diffs for the given sequence range."""
    start = int(settings.osm_diff_start_seq if start_seq is None else start_seq)
    end = int(settings.osm_diff_end_seq if end_seq is None else end_seq)
    if start < 0 or end < 0:
        raise ValueError(f"diff sequence numbers must be non-negative (got {start}..{end})")
    if start > end:
        raise ValueError(f"START_SEQ ({start}) must be less than or equal to END_SEQ ({end})")

    log.info("downloading OSM diff sequences %03d..%03d", start, end)
    jobs = [
        _support.Job(
            name=f"{seq:03d}.osc.gz",
            action=_download_diff_job(
                _DIFF_URL_TEMPLATE.format(seq=seq),
                settings.osm_data_dir / f"{seq:03d}.osc.gz",
                dry_run=dry_run,
            ),
        )
        for seq in range(start, end + 1)
    ]
    failed = _support.run_jobs(
        jobs, settings, max_workers=settings.download_parallel_jobs, dry_run=dry_run
    )
    if failed:
        raise _support.ImportFailed(failed)


# ---------------------------------------------------------------------------
# Stage 3: merge diffs
# ---------------------------------------------------------------------------


def merge_diffs(settings: Settings, *, dry_run: bool = False) -> None:
    """Merge the downloaded diffs into a single ``osm.osc.gz`` change file."""
    diff_files = _numeric_diff_files(settings)
    if not diff_files and not dry_run:
        raise FileNotFoundError(f"no numeric .osc.gz diff files found in {settings.osm_data_dir}")

    cmd = [
        "osmium",
        "merge-changes",
        "-o",
        _MERGED_CHANGES_FILENAME,
        "-s",
        *[path.name for path in diff_files],
    ]
    process.run_with_retry(
        cmd,
        retries=settings.retry_count,
        delay=settings.retry_delay,
        cwd=settings.osm_data_dir,
        log_file=_support.job_log_file(settings, "osm", "merge_diffs"),
        dry_run=dry_run,
    )
    if dry_run:
        return
    merged = settings.osm_data_dir / _MERGED_CHANGES_FILENAME
    if settings.osm_validate_downloads and not _support.validate_min_size(merged, _MERGED_MIN_MB):
        raise _support.ImportFailed([f"merged change file validation: {merged}"])


# ---------------------------------------------------------------------------
# Stage 4: apply changes
# ---------------------------------------------------------------------------


def apply_changes(settings: Settings, *, dry_run: bool = False) -> None:
    """Apply the merged change file to the planet PBF via osmosis."""
    data_dir = settings.osm_data_dir
    if not dry_run:
        _require_file(data_dir / _MERGED_CHANGES_FILENAME, _MERGED_MIN_MB)
        _require_file(data_dir / _PLANET_FILENAME, _APPLY_PLANET_MIN_MB)

    cmd = [
        "osmosis",
        "--read-xml-change",
        f"file={_MERGED_CHANGES_FILENAME}",
        "--read-pbf",
        f"file={_PLANET_FILENAME}",
        "--apply-change",
        "--write-pbf",
        f"file={_UPDATED_PLANET_FILENAME}",
    ]
    process.run_with_retry(
        cmd,
        retries=settings.retry_count,
        delay=settings.retry_delay,
        cwd=data_dir,
        log_file=_support.job_log_file(settings, "osm", "apply_changes"),
        dry_run=dry_run,
    )
    if dry_run:
        return
    updated = data_dir / _UPDATED_PLANET_FILENAME
    if settings.osm_validate_downloads and not _support.validate_min_size(
        updated, _APPLY_PLANET_MIN_MB
    ):
        raise _support.ImportFailed([f"updated planet file validation: {updated}"])


# ---------------------------------------------------------------------------
# Stage 5: imposm import
# ---------------------------------------------------------------------------


def import_planet(settings: Settings, *, dry_run: bool = False) -> None:
    """Import the updated planet PBF into PostGIS with imposm."""
    planet = settings.osm_data_dir / _UPDATED_PLANET_FILENAME
    if not dry_run:
        _require_file(planet, settings.osm_min_pbf_size_mb)

    cmd = [
        "imposm",
        "import",
        "-config",
        str(_resolve_path(settings, settings.osm_config_file)),
        "-mapping",
        str(_resolve_path(settings, settings.osm_mapping_file)),
        "-cachedir",
        str(settings.osm_cache_dir),
        "-diffdir",
        str(settings.osm_diff_dir),
        "-srid",
        str(settings.osm_srid),
        # imposm parses a postgis:// URL and does not read PGPASSWORD, so the
        # password must travel in argv; process.run() redacts it from logs.
        "-connection",
        settings.imposm_connection(),
        "-read",
        str(planet),
        "-write",
        "-diff",
        "-optimize",
    ]
    process.run_with_retry(
        cmd,
        retries=settings.retry_count,
        delay=settings.retry_delay,
        log_file=_support.job_log_file(settings, "osm", "import"),
        dry_run=dry_run,
    )


# ---------------------------------------------------------------------------
# Stage 6: imposm diff (one-time changeset update)
# ---------------------------------------------------------------------------


def import_diffs(settings: Settings, *, dry_run: bool = False) -> None:
    """Apply downloaded ``NNN.osc.gz`` changesets to the database via imposm diff."""
    changesets: list[Path] = []
    for path in _numeric_diff_files(settings):
        if dry_run or _support.validate_min_size(path, 1):
            changesets.append(path)
        else:
            log.warning("invalid changeset file: %s (skipping)", path)
    if not changesets and not dry_run:
        raise FileNotFoundError(f"no valid changeset files found in {settings.osm_data_dir}")

    cmd = [
        "imposm",
        "diff",
        "-config",
        str(_resolve_path(settings, settings.osm_config_file)),
        "-connection",
        settings.imposm_connection(),
        "-diffdir",
        str(settings.osm_diff_dir),
        "-srid",
        str(settings.osm_srid),
        "-mapping",
        str(_resolve_path(settings, settings.osm_mapping_file)),
        "-cachedir",
        str(settings.osm_cache_dir),
        *[str(path) for path in changesets],
    ]
    process.run_with_retry(
        cmd,
        retries=settings.retry_count,
        delay=settings.retry_delay,
        log_file=_support.job_log_file(settings, "osm", "import_diff"),
        dry_run=dry_run,
    )


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------


def _cleanup_intermediates(settings: Settings, *, dry_run: bool) -> None:
    """Remove the merged/updated intermediates after a successful full run.

    Only ``run_import(all)`` cleans up (and only when the whole pipeline
    succeeded); single-stage runs never delete their outputs. This fixes the
    bash script's EXIT trap, which removed the intermediates even when a lone
    ``--merge-diffs`` / ``--apply-changes`` invocation had just produced them.
    """
    if dry_run or not settings.osm_cleanup_on_exit:
        return
    for name in (_MERGED_CHANGES_FILENAME, _UPDATED_PLANET_FILENAME):
        path = settings.osm_data_dir / name
        if path.is_file():
            log.info("cleanup: removing intermediate file %s", path)
            path.unlink()


def run_import(
    settings: Settings,
    stage: OsmStage | str,
    *,
    start_seq: int | None = None,
    end_seq: int | None = None,
    dry_run: bool = False,
) -> None:
    """Run one OSM import stage (or the full ``all`` pipeline).

    ``all`` = planet download → diff download → merge → apply → imposm
    import. It does *not* start ``imposm run`` afterwards — continuous
    updates are owned by ``rbt osm run`` (:func:`run_updates`).
    """
    stage = OsmStage(stage)
    log.info("running OSM import stage: %s", stage.value)
    if stage is OsmStage.all:
        download_planet(settings, dry_run=dry_run)
        download_diffs(settings, start_seq, end_seq, dry_run=dry_run)
        merge_diffs(settings, dry_run=dry_run)
        apply_changes(settings, dry_run=dry_run)
        import_planet(settings, dry_run=dry_run)
        _cleanup_intermediates(settings, dry_run=dry_run)
    elif stage is OsmStage.download_planet:
        download_planet(settings, dry_run=dry_run)
    elif stage is OsmStage.download_diffs:
        download_diffs(settings, start_seq, end_seq, dry_run=dry_run)
    elif stage is OsmStage.merge_diffs:
        merge_diffs(settings, dry_run=dry_run)
    elif stage is OsmStage.apply_changes:
        apply_changes(settings, dry_run=dry_run)
    elif stage is OsmStage.import_:
        import_planet(settings, dry_run=dry_run)
    elif stage is OsmStage.import_diff:
        import_diffs(settings, dry_run=dry_run)


def import_osm(
    settings: Settings,
    *,
    stage: OsmStage | str = OsmStage.all,
    start_seq: int | None = None,
    end_seq: int | None = None,
    dry_run: bool = False,
) -> None:
    """Back-compat entry point; thin alias for :func:`run_import`."""
    run_import(settings, stage, start_seq=start_seq, end_seq=end_seq, dry_run=dry_run)


# ---------------------------------------------------------------------------
# Continuous-update supervisor (imposm run)
# ---------------------------------------------------------------------------


def _build_run_config(settings: Settings) -> dict[str, object]:
    """Merged imposm config for ``imposm run``.

    The committed imposm-config.json carries only the replication settings;
    the connection URL, mapping file, state directories, and SRID live in
    :class:`Settings` (the import stages pass them as CLI flags). ``imposm
    run`` is long-lived, so flags would leave the database password visible
    in ``/proc/<pid>/cmdline`` for the container's entire life — instead the
    full config is merged here and written to a private temp file.
    """
    base_path = _resolve_path(settings, settings.osm_config_file)
    config: dict[str, object] = json.loads(base_path.read_text(encoding="utf-8"))
    config.update(
        {
            "connection": settings.imposm_connection(),
            "mapping": str(_resolve_path(settings, settings.osm_mapping_file)),
            "cachedir": str(settings.osm_cache_dir),
            "diffdir": str(settings.osm_diff_dir),
            "srid": settings.osm_srid,
        }
    )
    return config


def _write_run_config(settings: Settings) -> Path:
    """Write the merged run config to a private (0600) temp file."""
    fd, name = tempfile.mkstemp(prefix="imposm-run-", suffix=".json")
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(_build_run_config(settings), handle)
    return Path(name)


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

    imposm's connection/mapping/cachedir/diffdir/srid are merged into a
    generated runtime config (:func:`_build_run_config`) rather than passed
    as flags, keeping the database password out of the process argv.
    """
    base_config = _resolve_path(settings, settings.osm_config_file)

    if dry_run:
        redacted = {**_build_run_config(settings), "connection": "<redacted>"}
        log.info(
            "[dry-run] imposm run -config <generated>: %s",
            json.dumps(redacted, sort_keys=True),
        )
        return

    existing = _read_pid(settings)
    if existing is not None:
        raise RuntimeError(f"imposm run already active (pid {existing}); use `rbt osm stop` first")

    settings.shared_temp_dir.mkdir(parents=True, exist_ok=True)
    run_config_path = _write_run_config(settings)
    cmd = ["imposm", "run", "-config", str(run_config_path)]
    log.info("starting continuous OSM updates: %s", " ".join(cmd))

    try:
        process = subprocess.Popen(  # noqa: S603 - fixed command list
            cmd,
            cwd=base_config.parent,
            env={**os.environ, **settings.subprocess_env()},
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
    except Exception:
        run_config_path.unlink(missing_ok=True)
        raise
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
        run_config_path.unlink(missing_ok=True)
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


__all__ = [
    "OsmStage",
    "apply_changes",
    "download_diffs",
    "download_planet",
    "import_diffs",
    "import_osm",
    "import_planet",
    "merge_diffs",
    "run_import",
    "run_updates",
    "stop_updates",
    "update_status",
]
