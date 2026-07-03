"""Shared toolkit for the native data importers.

Everything the four importers have in common: the declarative
:class:`OgrDataset` record and its ogr2ogr command builder, psycopg helpers
for schema/table management, a retrying parallel job pool, and stdlib
replacements for the retired bash scripts' wget/7z/sed plumbing.

Design notes (mirroring the retired bash importers):

- ogr2ogr loads always use ``PG_USE_COPY YES`` and create UNLOGGED tables
  with a ``geometry`` column in 2D; the PG password travels via PGPASSWORD
  (``Settings.libpq_env()``), never argv.
- Jobs retry ``settings.retry_count`` times with ``settings.retry_delay``
  seconds between attempts, log to per-job files under
  ``settings.shared_log_dir``, and the pool always drains — failures are
  collected and raised at the end (:class:`ImportFailed`).
- Downloads stream to ``<dest>.partial`` and rename atomically; existing
  valid files are skipped (resume semantics).
"""

from __future__ import annotations

import csv
import shutil
import ssl
import time
import urllib.error
import urllib.request
import zipfile
from collections.abc import Callable, Iterable, Sequence
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import psycopg
from psycopg import sql

from ..config import Settings
from ..logging import get_logger

log = get_logger(__name__)

_DOWNLOAD_CHUNK = 1 << 20  # 1 MiB


class ImportFailed(RuntimeError):
    """One or more import jobs failed after exhausting retries."""

    def __init__(self, failed: Sequence[str]) -> None:
        self.failed = list(failed)
        super().__init__(f"{len(self.failed)} import job(s) failed: {', '.join(self.failed)}")


@dataclass(frozen=True, slots=True)
class OgrDataset:
    """One ogr2ogr-loadable dataset (declarative registry entry).

    ``source`` is a GDAL-readable path — usually a ``/vsicurl/`` or
    ``/vsizip//vsicurl/`` remote — or a callable returning a local path for
    sources that must be downloaded first (e.g. MIRTA's FileGDB zip).
    """

    name: str
    schema: str
    table: str
    source: str | Callable[[Settings], Path]
    src_layer: str | None = None
    nlt: str | None = None
    a_srs: str | None = None
    t_srs: str | None = None
    overwrite: bool = False
    schema_lco: str | None = None  # -lco SCHEMA= (multi-layer loads, e.g. Natural Earth)
    layer_creation: tuple[str, ...] = ()  # extra -lco options
    open_options: tuple[str, ...] = ()  # -oo options
    gdal_config: tuple[tuple[str, str], ...] = ()  # --config KEY VALUE pairs
    group: str = "independent"

    @property
    def qualified_table(self) -> str:
        return f"{self.schema}.{self.table}"


def build_ogr2ogr_cmd(dataset: OgrDataset, settings: Settings, source: str) -> list[str]:
    """The canonical importer ogr2ogr argv (password via PGPASSWORD, not argv)."""
    cmd: list[str] = ["ogr2ogr", "-progress"]
    for key, value in dataset.gdal_config:
        cmd += ["--config", key, value]
    cmd += ["--config", "PG_USE_COPY", "YES"]
    cmd += ["-f", "PostgreSQL", settings.ogr_pg_connection()]
    if dataset.a_srs:
        cmd += ["-a_srs", dataset.a_srs]
    if dataset.t_srs:
        cmd += ["-t_srs", dataset.t_srs]
    if dataset.overwrite:
        cmd.append("-overwrite")
    if dataset.schema_lco:
        cmd += ["-lco", f"SCHEMA={dataset.schema_lco}"]
    else:
        cmd += ["-nln", dataset.qualified_table]
    if dataset.nlt:
        cmd += ["-nlt", dataset.nlt]
    cmd += ["-lco", "GEOMETRY_NAME=geometry", "-lco", "DIM=2", "-lco", "UNLOGGED=ON"]
    for lco in dataset.layer_creation:
        cmd += ["-lco", lco]
    for oo in dataset.open_options:
        cmd += ["-oo", oo]
    cmd.append("-skipfailures")
    cmd.append(source)
    if dataset.src_layer:
        cmd.append(dataset.src_layer)
    return cmd


def table_exists(settings: Settings, schema: str, table: str) -> bool:
    with psycopg.connect(settings.psql_conn_string(), connect_timeout=30) as conn:
        row = conn.execute(
            "SELECT 1 FROM information_schema.tables"
            " WHERE table_schema = %s AND table_name = %s",
            (schema, table),
        ).fetchone()
    return row is not None


def ensure_schemas(settings: Settings, schemas: Iterable[str], *, dry_run: bool = False) -> None:
    names = list(schemas)
    if dry_run:
        log.info("[dry-run] would ensure schemas exist: %s", ", ".join(names))
        return
    with psycopg.connect(settings.psql_conn_string(), autocommit=True) as conn:
        for name in names:
            conn.execute(
                sql.SQL("CREATE SCHEMA IF NOT EXISTS {}").format(sql.Identifier(name))
            )
    log.info("schemas ensured: %s", ", ".join(names))


def execute_sql(
    settings: Settings, statement: str, description: str, *, dry_run: bool = False
) -> None:
    """Run one SQL statement with autocommit (needed for VACUUM/CLUSTER)."""
    if dry_run:
        log.info("[dry-run] SQL (%s): %s", description, " ".join(statement.split())[:200])
        return
    log.info("SQL: %s", description)
    with psycopg.connect(settings.psql_conn_string(), autocommit=True) as conn:
        conn.execute(statement)  # type: ignore[arg-type,unused-ignore]


@dataclass(slots=True)
class Job:
    """A named unit of work for :func:`run_jobs`."""

    name: str
    action: Callable[[], None]


@dataclass(slots=True)
class _JobOutcome:
    name: str
    error: BaseException | None = None
    attempts: int = 0


def run_jobs(
    jobs: Sequence[Job],
    settings: Settings,
    *,
    max_workers: int | None = None,
    dry_run: bool = False,
) -> list[str]:
    """Run jobs in a bounded thread pool with per-job retry.

    The pool always drains; the failed job names are returned (and logged).
    Callers decide whether to raise :class:`ImportFailed`. Thread-based on
    purpose — every job is subprocess- or network-bound.
    """
    if not jobs:
        return []
    if dry_run:
        # Dry-run sequentially so the logged commands interleave predictably.
        for job in jobs:
            job.action()
        return []

    workers = max_workers or settings.max_parallel_jobs

    def attempt(job: Job) -> _JobOutcome:
        outcome = _JobOutcome(name=job.name)
        for attempt_no in range(1, settings.retry_count + 1):
            outcome.attempts = attempt_no
            try:
                job.action()
                return outcome
            except Exception as exc:  # noqa: BLE001 - pool boundary
                outcome.error = exc
                if attempt_no < settings.retry_count:
                    log.warning(
                        "job %s attempt %d/%d failed (%s); retrying in %ds",
                        job.name,
                        attempt_no,
                        settings.retry_count,
                        exc,
                        settings.retry_delay,
                    )
                    time.sleep(settings.retry_delay)
        return outcome

    failed: list[str] = []
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for outcome in pool.map(attempt, jobs):
            if outcome.error is not None:
                log.error(
                    "job %s FAILED after %d attempt(s): %s",
                    outcome.name,
                    outcome.attempts,
                    outcome.error,
                )
                failed.append(outcome.name)
            else:
                log.info("job %s completed", outcome.name)
    return failed


def job_log_file(settings: Settings, prefix: str, name: str) -> Path:
    settings.shared_log_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    return settings.shared_log_dir / f"{prefix}_{name}_{timestamp}.log"


def download(
    url: str,
    dest: Path,
    *,
    min_bytes: int = 1,
    timeout: int = 600,
    retries: int = 3,
    delay: int = 10,
    insecure_tls: bool = False,
    dry_run: bool = False,
) -> Path:
    """Stream *url* to *dest* (atomic, resumable-by-skip, size-validated).

    ``insecure_tls`` disables certificate verification — required only for
    the MIRTA endpoint, whose chain is absent from standard trust stores
    (the retired bash importer used ``wget --no-check-certificate``).
    """
    if dest.is_file() and dest.stat().st_size >= min_bytes:
        log.info("download skipped — %s already present (%d bytes)", dest.name, dest.stat().st_size)
        return dest
    if dry_run:
        log.info("[dry-run] would download %s -> %s", url, dest)
        return dest

    dest.parent.mkdir(parents=True, exist_ok=True)
    partial = dest.with_name(dest.name + ".partial")
    context = ssl._create_unverified_context() if insecure_tls else None  # noqa: S323

    last_error: Exception | None = None
    for attempt_no in range(1, retries + 1):
        try:
            log.info("downloading %s (attempt %d/%d)", url, attempt_no, retries)
            request = urllib.request.Request(url, headers={"User-Agent": "rbt-importer"})
            with (
                urllib.request.urlopen(request, timeout=timeout, context=context) as response,  # noqa: S310
                partial.open("wb") as out,
            ):
                shutil.copyfileobj(response, out, _DOWNLOAD_CHUNK)
            size = partial.stat().st_size
            if size < min_bytes:
                raise OSError(f"downloaded file too small: {size} bytes < {min_bytes} required")
            partial.replace(dest)
            log.info("downloaded %s (%d bytes)", dest.name, size)
            return dest
        except (urllib.error.URLError, OSError) as exc:
            last_error = exc
            partial.unlink(missing_ok=True)
            if attempt_no < retries:
                log.warning("download failed (%s); retrying in %ds", exc, delay)
                time.sleep(delay)
    raise OSError(f"failed to download {url} after {retries} attempts: {last_error}")


def extract_zip(archive: Path, dest_dir: Path, *, members: Iterable[str] | None = None) -> None:
    """Extract *archive* (replaces the bash importers' ``7z x`` / ``unzip``)."""
    dest_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as zf:
        zf.extractall(dest_dir, members=list(members) if members is not None else None)  # noqa: S202
    log.info("extracted %s -> %s", archive.name, dest_dir)


def tsv_to_csv(txt_path: Path, csv_path: Path) -> Path:
    """Convert a tab-separated GNS export to CSV.

    Strictly better than the bash ``sed 's/\\t/,/g'`` it replaces: the csv
    writer quotes fields containing commas instead of corrupting them.
    """
    with txt_path.open(newline="", encoding="utf-8", errors="replace") as src:
        reader = csv.reader(src, delimiter="\t")
        with csv_path.open("w", newline="", encoding="utf-8") as out:
            csv.writer(out).writerows(reader)
    return csv_path


def validate_min_lines(path: Path, min_lines: int = 10) -> bool:
    """True when *path* exists and has at least *min_lines* lines."""
    if not path.is_file():
        return False
    count = 0
    with path.open("rb") as handle:
        for count, _ in enumerate(handle, start=1):  # noqa: B007
            if count >= min_lines:
                return True
    return count >= min_lines


def validate_min_size(path: Path, min_mb: int) -> bool:
    """True when *path* exists and is at least *min_mb* MB."""
    return path.is_file() and path.stat().st_size >= min_mb * 1024 * 1024


__all__ = [
    "ImportFailed",
    "Job",
    "OgrDataset",
    "build_ogr2ogr_cmd",
    "download",
    "ensure_schemas",
    "execute_sql",
    "extract_zip",
    "job_log_file",
    "run_jobs",
    "table_exists",
    "tsv_to_csv",
    "validate_min_lines",
    "validate_min_size",
]
