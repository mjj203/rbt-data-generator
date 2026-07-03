"""Database bootstrap and setup orchestration (``rbt setup``).

Replaces ``setup/init-database.sh``: creates the database and extensions via
psycopg, then sequences the data importers (which remain bash leaf scripts,
called through :mod:`rbt.importers`) and schema processing.
"""

from __future__ import annotations

from dataclasses import dataclass

import psycopg
from psycopg import sql

from .config import Settings
from .importers import buildings as buildings_importer
from .importers import geonames as geonames_importer
from .importers import osm as osm_importer
from .importers.osm import OsmStage
from .importers import reference as reference_importer
from .layers import LayerRegistry
from .logging import get_logger
from .schema import run_schemas

log = get_logger(__name__)


@dataclass(slots=True)
class SetupSteps:
    """Which initialization steps to run (mirrors the legacy CLI flags)."""

    bootstrap: bool = False
    import_osm: bool = False
    import_reference: bool = False
    import_geonames: bool = False
    import_buildings: bool = False
    process_schemas: bool = False

    @classmethod
    def all(cls) -> SetupSteps:
        return cls(
            bootstrap=True,
            import_osm=True,
            import_reference=True,
            import_geonames=True,
            import_buildings=True,
            process_schemas=True,
        )

    def any_selected(self) -> bool:
        return any(
            (
                self.bootstrap,
                self.import_osm,
                self.import_reference,
                self.import_geonames,
                self.import_buildings,
                self.process_schemas,
            )
        )


def database_exists(conn: psycopg.Connection, name: str) -> bool:
    """Shared by ``rbt setup`` (create-if-missing) and ``rbt validate`` (report-only)."""
    return (
        conn.execute("SELECT 1 FROM pg_database WHERE datname = %s", (name,)).fetchone() is not None
    )


def bootstrap(settings: Settings, *, dry_run: bool = False) -> None:
    """Create the database (if missing) and required extensions."""
    if dry_run:
        log.info(
            "[dry-run] would create database %r and extensions %s",
            settings.database_name,
            ", ".join(settings.database_extensions),
        )
        return

    admin_conninfo = settings.psql_conn_string("postgres")
    with psycopg.connect(admin_conninfo, autocommit=True) as conn:
        if not database_exists(conn, settings.database_name):
            log.info("creating database %r", settings.database_name)
            conn.execute(
                sql.SQL("CREATE DATABASE {}").format(sql.Identifier(settings.database_name))
            )

    with psycopg.connect(settings.psql_conn_string(), autocommit=True) as conn:
        for extension in settings.database_extensions:
            log.info("ensuring extension %s", extension)
            conn.execute(
                sql.SQL("CREATE EXTENSION IF NOT EXISTS {}").format(sql.Identifier(extension))
            )

    log.info("database bootstrap completed")


def run_setup(
    settings: Settings,
    registry: LayerRegistry,
    steps: SetupSteps,
    *,
    osm_stage: OsmStage = OsmStage.all,
    dry_run: bool = False,
) -> None:
    """Run the selected initialization steps in dependency order.

    *osm_stage* selects which part of the OSM workflow the import step runs
    (default: the complete download → import pipeline).
    """
    if steps.bootstrap:
        bootstrap(settings, dry_run=dry_run)
    if steps.import_osm:
        log.info("importing OSM data (this may take several hours)")
        osm_importer.run_import(settings, osm_stage, dry_run=dry_run)
    if steps.import_reference:
        log.info("importing reference datasets")
        reference_importer.import_reference(settings, dry_run=dry_run)
    if steps.import_geonames:
        log.info("importing GeoNames (NGA GNS) data")
        geonames_importer.import_geonames(settings, dry_run=dry_run)
    if steps.import_buildings:
        log.info("importing Overture buildings")
        buildings_importer.import_buildings(settings, dry_run=dry_run)
    if steps.process_schemas:
        log.info("processing database schemas")
        run_schemas(settings, registry, dry_run=dry_run)
    log.info("setup completed")


__all__ = ["SetupSteps", "bootstrap", "database_exists", "run_setup"]
