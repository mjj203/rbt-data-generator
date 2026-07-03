"""Helpers for delegating to Bash leaf scripts.

The architecture rule (see CONTRIBUTING.md): only the ``rbt`` CLI dispatches —
no bash calls Python, no bash calls bash. The scripts reached through
:func:`delegate` are the four data-importer leaf tasks under
``setup/data-sources/`` (download + load external datasets).
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


__all__ = ["delegate"]
