"""Tests for bash leaf-script delegation (``rbt.bash``)."""

from __future__ import annotations

from pathlib import Path

import pytest

from rbt.bash import delegate
from rbt.config import load_settings


def _make_script(root: Path, relative: str) -> Path:
    script = root / relative
    script.parent.mkdir(parents=True, exist_ok=True)
    script.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    return script


def test_missing_script_raises_file_not_found(fake_repo: Path) -> None:
    settings = load_settings()
    with pytest.raises(FileNotFoundError) as excinfo:
        delegate("setup/data-sources/osm/missing.sh", [], settings)
    assert "setup/data-sources/osm/missing.sh" in str(excinfo.value)


def test_delegate_builds_bash_command_with_cwd_and_env(fake_repo: Path, recorded_run) -> None:
    relative = "setup/data-sources/osm/import-osm-data.sh"
    _make_script(fake_repo, relative)
    settings = load_settings()

    delegate(relative, ["--region", "us"], settings)

    assert len(recorded_run.calls) == 1
    call = recorded_run.calls[0]
    script = fake_repo.resolve() / relative
    assert call["cmd"] == ["bash", str(script), "--region", "us"]
    assert call["cwd"] == script.parent

    env = call["env"]
    assert env["PGHOST"] == settings.database_host
    assert env["PG_HOST"] == settings.database_host
    assert env["DATABASE_HOST"] == settings.database_host
    assert env["RBT_PROJECT_ROOT"] == str(settings.project_root)


def test_delegate_forwards_dry_run_and_log_file(fake_repo: Path, recorded_run) -> None:
    relative = "setup/data-sources/reference-data/import-geonames.sh"
    _make_script(fake_repo, relative)
    settings = load_settings()
    log_file = fake_repo / "output" / "logs" / "geonames.log"

    delegate(relative, [], settings, dry_run=True, log_file=log_file)

    call = recorded_run.calls[0]
    assert call["dry_run"] is True
    assert call["log_file"] == log_file
