"""Tests that ``rbt import …`` delegates to the bash leaf scripts."""

from __future__ import annotations

from pathlib import Path

import pytest
from typer.testing import CliRunner

from rbt.cli import app

runner = CliRunner()

# The four importers that remain bash leaf scripts (see src/rbt/bash.py).
LEAF_SCRIPTS = {
    "osm": "setup/data-sources/osm/import-osm-data.sh",
    "reference": "setup/data-sources/reference-data/import-reference-data.sh",
    "geonames": "setup/data-sources/reference-data/import-geonames.sh",
    "buildings": "setup/data-sources/reference-data/import-buildings.sh",
}


@pytest.fixture
def importer_repo(fake_repo: Path) -> Path:
    """fake_repo with dummy leaf scripts at the contracted relative paths."""
    for rel in LEAF_SCRIPTS.values():
        script = fake_repo / rel
        script.parent.mkdir(parents=True, exist_ok=True)
        script.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        script.chmod(0o755)
    return fake_repo


@pytest.mark.parametrize("command", sorted(LEAF_SCRIPTS))
def test_import_command_delegates_to_leaf_script(
    command: str, importer_repo: Path, recorded_run
) -> None:
    result = runner.invoke(app, ["--no-log-file", "import", command, "region-a", "region-b"])
    assert result.exit_code == 0, result.output

    root = importer_repo.resolve()
    script = root / LEAF_SCRIPTS[command]
    [call] = recorded_run.calls
    assert call["cmd"] == ["bash", str(script), "region-a", "region-b"]
    assert Path(call["cwd"]) == script.parent
    assert call["env"]["PGDATABASE"] == "rbt"
    assert call["env"]["RBT_PROJECT_ROOT"] == str(root)
    assert call["dry_run"] is False


@pytest.mark.parametrize("command", sorted(LEAF_SCRIPTS))
def test_import_command_without_passthrough_args(
    command: str, importer_repo: Path, recorded_run
) -> None:
    result = runner.invoke(app, ["--no-log-file", "import", command])
    assert result.exit_code == 0, result.output

    script = importer_repo.resolve() / LEAF_SCRIPTS[command]
    [call] = recorded_run.calls
    assert call["cmd"] == ["bash", str(script)]


def test_import_dry_run_threads_through(importer_repo: Path, recorded_run) -> None:
    result = runner.invoke(app, ["--no-log-file", "import", "reference", "--dry-run"])
    assert result.exit_code == 0, result.output
    [call] = recorded_run.calls
    assert call["dry_run"] is True


def test_import_missing_script_errors(fake_repo: Path, recorded_run) -> None:
    # No leaf scripts created: delegate() must refuse before dispatch.
    result = runner.invoke(app, ["--no-log-file", "import", "geonames"])
    assert result.exit_code != 0
    assert isinstance(result.exception, FileNotFoundError)
    assert recorded_run.calls == []
