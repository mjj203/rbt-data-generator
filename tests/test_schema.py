"""Tests for schema selection and psql dispatch (``rbt.schema``)."""

from __future__ import annotations

from pathlib import Path

import pytest

from rbt.config import load_settings
from rbt.layers import load_registry
from rbt.schema import resolve_schema_files, run_schemas

# ---------------------------------------------------------------------------
# resolve_schema_files
# ---------------------------------------------------------------------------


def test_resolve_selects_everything_by_default(fake_repo: Path) -> None:
    files = resolve_schema_files(load_registry())
    assert {f.key for f in files} == {"physical", "cultural"}


def test_resolve_by_key(fake_repo: Path) -> None:
    files = resolve_schema_files(load_registry(), keys=["cultural"])
    assert [f.key for f in files] == ["cultural"]
    assert files[0].layer_type == "cultural"
    assert files[0].sql.endswith("cultural-core.sql")


def test_resolve_by_layer_type(fake_repo: Path) -> None:
    files = resolve_schema_files(load_registry(), layer_type="physical")
    assert [f.key for f in files] == ["physical"]


def test_resolve_key_and_type_union(fake_repo: Path) -> None:
    files = resolve_schema_files(load_registry(), keys=["cultural"], layer_type="physical")
    assert {f.key for f in files} == {"physical", "cultural"}


def test_resolve_unknown_key_raises_with_available_list(fake_repo: Path) -> None:
    with pytest.raises(KeyError, match="Unknown schema 'nope'") as excinfo:
        resolve_schema_files(load_registry(), keys=["nope"])
    message = str(excinfo.value)
    assert "available" in message
    assert "cultural" in message
    assert "physical" in message


# ---------------------------------------------------------------------------
# run_schemas
# ---------------------------------------------------------------------------


def test_run_schemas_dispatches_psql_with_on_error_stop(fake_repo: Path, recorded_run) -> None:
    settings = load_settings()
    done = run_schemas(settings, load_registry(), keys=["physical"])

    assert [s.key for s in done] == ["physical"]
    [call] = recorded_run.calls
    assert call["cmd"] == ["psql", "-v", "ON_ERROR_STOP=1", "-f", "physical-core.sql"]

    expected_dir = (settings.project_root / "setup/data-sources/schemas/physical").resolve()
    assert Path(call["cwd"]) == expected_dir
    assert call["env"]["PGDATABASE"] == "rbt"
    assert call["dry_run"] is False

    log_file: Path = call["log_file"]
    assert log_file.parent == settings.shared_log_dir
    assert log_file.name.startswith("schema_physical_")


def test_run_schemas_missing_sql_raises_before_dispatch(fake_repo: Path, recorded_run) -> None:
    (fake_repo / "setup/data-sources/schemas/cultural/cultural-core.sql").unlink()
    with pytest.raises(FileNotFoundError, match="cultural-core.sql"):
        run_schemas(load_settings(), load_registry(), keys=["cultural"])
    assert recorded_run.calls == []


def test_run_schemas_dry_run_threads_through(fake_repo: Path, recorded_run) -> None:
    done = run_schemas(load_settings(), load_registry(), dry_run=True)
    assert {s.key for s in done} == {"physical", "cultural"}
    assert len(recorded_run.calls) == 2
    assert all(call["dry_run"] is True for call in recorded_run.calls)
