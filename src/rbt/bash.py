"""Helpers for delegating to legacy Bash scripts.

The Python CLI supports two execution modes:

- **native**: use :mod:`rbt.tiles` / :mod:`rbt.importers` to run ogr2ogr and
  tippecanoe directly. Fastest and most readable.
- **bash-delegate**: shell out to the original scripts under
  ``setup/`` / ``production/``. Useful during the migration period so that
  the Python CLI is a drop-in replacement.

Callers pick mode via the ``--mode`` CLI option (default: ``native``).
"""

from __future__ import annotations

from collections.abc import Iterable
from pathlib import Path

from .config import Settings
from .paths import project_root
from .process import run


def _script_path(relative: str) -> Path:
    path = project_root() / relative
    if not path.is_file():
        raise FileNotFoundError(f"Expected bash script at {path}")
    return path


def delegate(
    relative: str,
    args: Iterable[str],
    settings: Settings,
    *,
    dry_run: bool = False,
    log_file: Path | None = None,
) -> None:
    script = _script_path(relative)
    env = settings.subprocess_env()
    run(
        ["bash", str(script), *list(args)],
        cwd=script.parent,
        env=env,
        dry_run=dry_run,
        log_file=log_file,
    )


def init_database(settings: Settings, args: list[str], *, dry_run: bool = False) -> None:
    delegate("setup/init-database.sh", args, settings, dry_run=dry_run)


def generate_tiles_bash(settings: Settings, args: list[str], *, dry_run: bool = False) -> None:
    delegate("production/generate-tiles.sh", args, settings, dry_run=dry_run)


def update_osm(settings: Settings, args: list[str], *, dry_run: bool = False) -> None:
    delegate("production/update-osm.sh", args, settings, dry_run=dry_run)


__all__ = ["delegate", "generate_tiles_bash", "init_database", "update_osm"]
