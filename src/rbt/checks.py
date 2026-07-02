"""Operational checks: ``rbt health``, ``rbt validate``, ``rbt smoke``.

Replaces ``tools/health-check.sh``, ``tools/validate-environment.sh``, and
``tools/smoke-test.sh``. ``health`` is the Docker HEALTHCHECK command, so it
must stay fast and dependency-light.

``CheckReport`` prints directly to stdout (info/ok/warn) and stderr (error)
rather than routing through :mod:`rbt.logging`'s ``RichHandler`` (which
writes every level to one stream). That is a deliberate exception: these
functions are human-facing progress reports where the stdout/stderr split
lets ``rbt validate`` (etc.) be scripted — e.g. ``rbt validate 2>/tmp/errs``
— which a single combined log stream would not support.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from dataclasses import dataclass, field

import psycopg

from .config import Settings
from .layers import load_registry
from .logging import get_logger
from .schema import run_schemas
from .setup_db import bootstrap, database_exists
from .tiles.engine import TileEngine, TileJob

log = get_logger(__name__)

# Tools the pipeline shells out to, with the component that needs them.
REQUIRED_TOOLS: dict[str, str] = {
    "psql": "PostgreSQL client",
    "ogr2ogr": "GDAL/OGR spatial data tools",
    "imposm": "Imposm3 OSM import tool",
    "tippecanoe": "Mapbox vector tile generation",
    "tile-join": "Tippecanoe tile joining tool",
    "wget": "File download utility",
    "aws": "AWS CLI (for Overture data)",
}

OPTIONAL_TOOLS: dict[str, str] = {
    "7z": "7-Zip archive utility",
    "sqlite3": "SQLite database utility",
    "docker": "Docker containerization",
}

# Project-relative paths `_check_project_structure` expects to exist.
REQUIRED_PATHS: tuple[str, ...] = (
    "config/rbt.conf",
    "config/layers.yml",
    "setup/data-sources/osm/imposm-config.json",
    "setup/data-sources/osm/imposm-mapping.yaml",
    "setup/data-sources/osm/import-osm-data.sh",
    "setup/data-sources/reference-data/import-reference-data.sh",
    "setup/data-sources/schemas/cultural/cultural-core.sql",
    "setup/data-sources/schemas/physical/physical-core.sql",
)


@dataclass(slots=True)
class CheckReport:
    """Accumulated validation results."""

    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def error(self, message: str) -> None:
        self.errors.append(message)
        print(f"❌ {message}", file=sys.stderr)

    def warn(self, message: str) -> None:
        self.warnings.append(message)
        print(f"⚠️  {message}")

    def ok(self, message: str) -> None:
        print(f"✅ {message}")

    def info(self, message: str) -> None:
        print(f"ℹ️  {message}")

    @property
    def exit_code(self) -> int:
        return 1 if self.errors else 0


def _connect(settings: Settings, dbname: str | None = None) -> psycopg.Connection:
    return psycopg.connect(settings.psql_conn_string(dbname), connect_timeout=10)


def health(settings: Settings) -> int:
    """Fast liveness probe: database round-trip plus PATH warnings."""
    status = 0
    try:
        with _connect(settings) as conn:
            conn.execute("SELECT 1")
        print("OK: database reachable")
    except psycopg.Error as exc:
        print(
            f"ERROR: database round-trip failed "
            f"({settings.database_host}:{settings.database_port}/{settings.database_name}): "
            f"{exc}",
            file=sys.stderr,
        )
        status = 1

    for tool in ("tippecanoe", "imposm"):
        if shutil.which(tool) is None:
            print(f"WARN: {tool} not on PATH")

    return status


def _tool_version(tool: str) -> str:
    try:
        out = subprocess.run(  # noqa: S603 - fixed command list
            [tool, "--version"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        first_line = (out.stdout or out.stderr).strip().splitlines()
        return first_line[0] if first_line else "version unknown"
    except (OSError, subprocess.TimeoutExpired):
        return "version unknown"


def _total_memory_gb() -> int | None:
    if hasattr(os, "sysconf") and "SC_PHYS_PAGES" in os.sysconf_names:
        try:
            return int(os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE") / 1024**3)
        except (ValueError, OSError):
            return None
    return None


def _check_config(settings: Settings, report: CheckReport) -> None:
    print("🔍 Checking configuration...")
    for key, value in (
        ("DATABASE_HOST", settings.database_host),
        ("DATABASE_USER", settings.database_user),
        ("DATABASE_NAME", settings.database_name),
    ):
        if value:
            report.ok(f"{key}={value}")
        else:
            report.error(f"Required configuration value not set: {key}")
    if not settings.database_password:
        report.warn("DATABASE_PASSWORD not set; relying on passwordless/peer authentication")
    report.info(f"Tile cache directory: {settings.tile_cache_dir}")
    report.info(f"Max parallel jobs: {settings.max_parallel_jobs}")


def _check_tools(report: CheckReport) -> None:
    print("\n🔍 Checking system dependencies...")
    for tool, description in REQUIRED_TOOLS.items():
        if shutil.which(tool):
            report.ok(f"{description}: {tool} ({_tool_version(tool)})")
        else:
            report.error(f"{description}: {tool} not found")
    for tool, description in OPTIONAL_TOOLS.items():
        if shutil.which(tool):
            report.ok(f"{description}: {tool} (available)")
        else:
            report.warn(f"{description}: {tool} not found (optional)")


def _check_database(settings: Settings, report: CheckReport) -> None:
    print("\n🔍 Checking database connection...")
    try:
        with _connect(settings, "postgres") as conn:
            conn.execute("SELECT version()")
            report.ok("Database connection successful")
            exists = database_exists(conn, settings.database_name)
        if not exists:
            report.warn(f"{settings.database_name} database does not exist (run `rbt setup`)")
            return

        report.ok(f"{settings.database_name} database exists")
        with _connect(settings) as conn:
            for extension in settings.database_extensions:
                found = conn.execute(
                    "SELECT 1 FROM pg_extension WHERE extname = %s", (extension,)
                ).fetchone()
                if found:
                    report.ok(f"Extension '{extension}' is installed")
                else:
                    report.warn(f"Extension '{extension}' not found")
            for schema_name in settings.database_schemas:
                found = conn.execute(
                    "SELECT 1 FROM information_schema.schemata WHERE schema_name = %s",
                    (schema_name,),
                ).fetchone()
                if found:
                    report.ok(f"Schema '{schema_name}' exists")
                else:
                    report.warn(f"Schema '{schema_name}' not found (run `rbt setup`)")
    except psycopg.Error as exc:
        report.error(f"Cannot connect to database: {exc}")


def _check_disk_space(settings: Settings, report: CheckReport) -> None:
    print("\n🔍 Checking disk space...")
    usage = shutil.disk_usage(settings.project_root)
    available_gb = usage.free // 1024**3
    if available_gb >= settings.disk_space_required_gb:
        report.ok(
            f"Sufficient disk space: {available_gb}GB available "
            f"({settings.disk_space_required_gb}GB required)"
        )
    else:
        report.error(
            f"Insufficient disk space: {available_gb}GB available "
            f"({settings.disk_space_required_gb}GB required)"
        )


def _check_memory(settings: Settings, report: CheckReport) -> None:
    print("\n🔍 Checking system memory...")
    total_gb = _total_memory_gb()
    if total_gb is None:
        report.warn("Cannot determine system memory")
    elif total_gb >= settings.memory_required_gb:
        report.ok(
            f"Sufficient memory: {total_gb}GB total ({settings.memory_required_gb}GB recommended)"
        )
    else:
        report.warn(
            f"Limited memory: {total_gb}GB total ({settings.memory_required_gb}GB recommended)"
        )


def _check_project_structure(settings: Settings, report: CheckReport) -> None:
    print("\n🔍 Checking project structure...")
    for rel in REQUIRED_PATHS:
        if (settings.project_root / rel).exists():
            report.ok(f"Exists: {rel}")
        else:
            report.error(f"Required path missing: {rel}")


def _print_summary(report: CheckReport) -> None:
    print("\n📋 Validation Summary")
    if report.errors:
        print(f"❌ {len(report.errors)} error(s), {len(report.warnings)} warning(s)")
    elif report.warnings:
        print(f"⚠️  Passed with {len(report.warnings)} warning(s)")
    else:
        print("✅ All validations passed")


def validate(settings: Settings) -> int:
    """Pre-flight validation of configuration, tools, database, and resources."""
    report = CheckReport()
    _check_config(settings, report)
    _check_tools(report)
    _check_database(settings, report)
    _check_disk_space(settings, report)
    _check_memory(settings, report)
    _check_project_structure(settings, report)
    _print_summary(report)
    return report.exit_code


def smoke(settings: Settings) -> int:
    """End-to-end sanity check: validate -> bootstrap -> schema -> tile dry-runs -> DB.

    Unlike ``validate``/``health``, this is **not read-only**: steps 2 and 3
    create the database/extensions (if missing) and run real schema SQL
    against it. Treat it as a lightweight integration workflow, not a probe.
    """
    log.info("=== RBT smoke test starting ===")

    log.info("step 1/5: validating environment")
    if validate(settings) != 0:
        log.error("environment validation failed")
        return 1

    log.info("step 2/5: ensuring database and extensions exist")
    bootstrap(settings)

    registry = load_registry()

    log.info("step 3/5: schema processing sanity check (physical core)")
    run_schemas(settings, registry, keys=["physical"])

    log.info("step 4/5: tile generation dry-runs")
    engine = TileEngine(settings=settings, registry=registry, dry_run=True)
    for layer_type, code, category in (
        ("physical", "3857", "water"),
        ("cultural", "4326", "building"),
    ):
        projection = registry.projections[code]
        layers = engine.resolve_layers(layer_type, categories=[category])
        engine.generate(
            TileJob(
                layer_type=layer_type,
                projection=projection,
                layers=layers,
                output_dir=engine.output_dir_for(layer_type, projection),
                categories=[category],
            )
        )

    log.info("step 5/5: verifying database connectivity")
    with _connect(settings) as conn:
        conn.execute("SELECT NOW()")

    log.info("=== RBT smoke test completed successfully ===")
    return 0


__all__ = ["CheckReport", "health", "smoke", "validate"]
