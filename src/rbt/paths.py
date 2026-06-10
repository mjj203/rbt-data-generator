"""Repository-root path discovery."""

from __future__ import annotations

import os
from functools import lru_cache
from pathlib import Path


@lru_cache(maxsize=1)
def project_root() -> Path:
    """Return the repository root.

    Resolution order:

    1. ``RBT_PROJECT_ROOT`` env var if set.
    2. Walk upward from this file looking for ``config/rbt.conf``.
    3. Fall back to two levels above the package (``src/rbt`` → repo root).

    The result is cached for the lifetime of the process (``lru_cache``);
    tests that change ``RBT_PROJECT_ROOT`` must call
    ``project_root.cache_clear()`` (the shared ``fake_repo`` fixture does).
    """
    env = os.environ.get("RBT_PROJECT_ROOT")
    if env:
        return Path(env).resolve()

    here = Path(__file__).resolve()
    for parent in [here, *here.parents]:
        if (parent / "config" / "rbt.conf").is_file():
            return parent

    return here.parent.parent.parent


def config_dir() -> Path:
    return project_root() / "config"


def output_dir() -> Path:
    return project_root() / "output"
