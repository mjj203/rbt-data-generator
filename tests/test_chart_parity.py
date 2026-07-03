"""Guard against drift between config/ and the Helm chart's files/ mirrors.

Helm cannot read files outside the chart directory, so the chart carries
copies of the repo-root config files (see charts/rbt-data-generator/README.md,
"keep them in sync"). These tests make that instruction enforceable.
"""

from __future__ import annotations

from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[1]
_CHART_FILES = _REPO_ROOT / "charts" / "rbt-data-generator" / "files"


@pytest.mark.parametrize("name", ["postgresql.conf", "tile-server.json"])
def test_chart_files_mirror_repo_config(name: str) -> None:
    canonical = (_REPO_ROOT / "config" / name).read_text(encoding="utf-8")
    mirrored = (_CHART_FILES / name).read_text(encoding="utf-8")
    assert mirrored == canonical, (
        f"charts/rbt-data-generator/files/{name} has drifted from config/{name}; "
        f"copy the config/ version over (it is the canonical one)"
    )
