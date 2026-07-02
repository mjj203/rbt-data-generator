"""Database schema dispatch (``rbt schema``).

Runs the PL/pgSQL files registered under ``schemas:`` in ``config/layers.yml``
through ``psql``. The SQL files are thousands of lines of PL/pgSQL that psql
executes statement-by-statement — deliberately NOT reimplemented over a
driver connection. Replaces ``setup/data-sources/schemas/*/process-*-schemas.sh``.
"""

from __future__ import annotations

from datetime import datetime
from pathlib import Path

from .config import Settings
from .layers import LayerRegistry, SchemaFile
from .logging import get_logger
from .process import run

log = get_logger(__name__)


def resolve_schema_files(
    registry: LayerRegistry,
    keys: list[str] | None = None,
    layer_type: str | None = None,
) -> list[SchemaFile]:
    """Select schema units by key and/or layer type.

    *keys* and *layer_type* combine as a **union** (OR), not an intersection:
    passing both runs every unit matching either. Passing neither selects all
    (used by ``rbt setup`` / ``rbt smoke``; the ``rbt schema run`` CLI requires
    an explicit selection instead).
    """
    if not registry.schemas:
        raise KeyError("No 'schemas:' section found in config/layers.yml")

    selected: dict[str, SchemaFile] = {}
    if keys:
        for key in keys:
            if key not in registry.schemas:
                raise KeyError(f"Unknown schema {key!r} (available: {sorted(registry.schemas)})")
            selected[key] = registry.schemas[key]
    if layer_type:
        for schema in registry.schemas_for_type(layer_type):
            selected[schema.key] = schema
    if not keys and not layer_type:
        selected = dict(registry.schemas)
    return list(selected.values())


def run_schemas(
    settings: Settings,
    registry: LayerRegistry,
    *,
    keys: list[str] | None = None,
    layer_type: str | None = None,
    dry_run: bool = False,
) -> list[SchemaFile]:
    """Execute the selected schema SQL files via psql.

    Each file runs with ``ON_ERROR_STOP=1`` so a failing statement aborts that
    unit (the bash dispatchers continued past errors — this is intentionally
    stricter). The working directory is the SQL file's directory to preserve
    any relative ``\\i`` includes.
    """
    schemas = resolve_schema_files(registry, keys, layer_type)
    settings.shared_log_dir.mkdir(parents=True, exist_ok=True)

    for schema in schemas:
        sql_path = (settings.project_root / schema.sql).resolve()
        if not sql_path.is_file():
            raise FileNotFoundError(f"Schema SQL not found: {sql_path}")

        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        log_file: Path = settings.shared_log_dir / f"schema_{schema.key}_{timestamp}.log"
        log.info("processing schema %s (%s)", schema.key, schema.sql)
        run(
            ["psql", "-v", "ON_ERROR_STOP=1", "-f", sql_path.name],
            cwd=sql_path.parent,
            env=settings.libpq_env(),
            log_file=log_file,
            dry_run=dry_run,
        )
        log.info("schema %s completed", schema.key)

    return schemas


__all__ = ["resolve_schema_files", "run_schemas"]
