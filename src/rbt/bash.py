"""Helpers for delegating to Bash leaf scripts.

The architecture rule (see CONTRIBUTING.md): only the ``rbt`` CLI dispatches —
no bash calls Python, no bash calls bash. The scripts reached through
:func:`delegate` are leaf tasks:

- the four data importers under ``setup/data-sources/`` (download + load
  external datasets), which remain bash by design, and
- the deprecated tile generators under ``production/`` (``--mode bash``
  escape hatch, kept until a real-data parity check retires them).
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


def generate_tiles_bash(settings: Settings, args: list[str], *, dry_run: bool = False) -> None:
    """Escape hatch: run the deprecated bash tile generators (``--mode bash``)."""
    delegate("production/generate-tiles.sh", args, settings, dry_run=dry_run)


__all__ = ["delegate", "generate_tiles_bash"]
