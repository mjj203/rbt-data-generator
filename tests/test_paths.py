"""Tests for repository-root discovery (``rbt.paths``)."""

from __future__ import annotations

from pathlib import Path

from rbt import paths


def test_env_override_wins(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("RBT_PROJECT_ROOT", str(tmp_path))
    paths.project_root.cache_clear()
    assert paths.project_root() == tmp_path.resolve()


def test_walk_up_discovery_finds_config_dir() -> None:
    # The autouse fixture scrubbed RBT_PROJECT_ROOT, so discovery walks up
    # from src/rbt/paths.py and stops at the directory holding config/rbt.conf.
    expected = Path(paths.__file__).resolve().parents[2]
    root = paths.project_root()
    assert root == expected
    assert (root / "config" / "rbt.conf").is_file()


def test_project_root_is_cached_until_cleared(tmp_path: Path, monkeypatch) -> None:
    first = tmp_path / "first"
    second = tmp_path / "second"
    first.mkdir()
    second.mkdir()

    monkeypatch.setenv("RBT_PROJECT_ROOT", str(first))
    paths.project_root.cache_clear()
    assert paths.project_root() == first.resolve()

    # lru_cache holds the first answer even after the env var changes...
    monkeypatch.setenv("RBT_PROJECT_ROOT", str(second))
    assert paths.project_root() == first.resolve()

    # ...until the cache is cleared.
    paths.project_root.cache_clear()
    assert paths.project_root() == second.resolve()


def test_config_dir_derives_from_root(fake_repo: Path) -> None:
    root = fake_repo.resolve()
    assert paths.config_dir() == root / "config"
