"""Tests for rbt.conf parsing and environment handling in ``rbt.config``.

Complements ``test_config.py`` (defaults + env overrides) with shell-style
expansion, quoting, precedence, and the no-mutation guarantee.
"""

from __future__ import annotations

import os
from pathlib import Path

from rbt.config import load_settings


def _write_conf(root: Path, content: str) -> None:
    (root / "config" / "rbt.conf").write_text(content, encoding="utf-8")


def test_fallback_expansion_uses_default_when_unset(fake_repo: Path) -> None:
    _write_conf(fake_repo, "DATABASE_NAME=${MY_DB:-fallbackdb}\n")
    assert load_settings().database_name == "fallbackdb"


def test_fallback_expansion_prefers_environment(fake_repo: Path, monkeypatch) -> None:
    _write_conf(fake_repo, "DATABASE_NAME=${MY_DB:-fallbackdb}\n")
    monkeypatch.setenv("MY_DB", "envdb")
    assert load_settings().database_name == "envdb"


def test_assign_expansion_visible_to_later_lines(fake_repo: Path) -> None:
    _write_conf(
        fake_repo,
        "DATABASE_USER=${SEED_USER:=seeded}\nDATABASE_NAME=${SEED_USER}\n",
    )
    settings = load_settings()
    assert settings.database_user == "seeded"
    assert settings.database_name == "seeded"
    # ``:=`` assigns into the local expansion mapping, never the process env.
    assert "SEED_USER" not in os.environ


def test_surrounding_quotes_are_stripped(fake_repo: Path) -> None:
    _write_conf(fake_repo, "DATABASE_HOST=\"quoted.example.com\"\nLOG_LEVEL='DEBUG'\n")
    settings = load_settings()
    assert settings.database_host == "quoted.example.com"
    assert settings.log_level == "DEBUG"


def test_inline_comments_are_stripped(fake_repo: Path) -> None:
    _write_conf(fake_repo, "DATABASE_PORT=6543  # custom port\n")
    assert load_settings().database_port == 6543


def test_quoted_value_preserves_hash(fake_repo: Path) -> None:
    # A '#' inside quotes is part of the value, not the start of a comment.
    _write_conf(fake_repo, "DATABASE_PASSWORD='p@ss#word'\n")
    assert load_settings().database_password == "p@ss#word"


def test_env_legacy_alias_beats_conf_canonical(fake_repo: Path, monkeypatch) -> None:
    # Documented precedence is env > conf, and it must hold across aliases:
    # PG_HOST (legacy) in the environment beats DATABASE_HOST (canonical) in conf.
    _write_conf(fake_repo, "DATABASE_HOST=confhost\n")
    monkeypatch.setenv("PG_HOST", "envlegacy")
    assert load_settings().database_host == "envlegacy"


def test_precedence_overrides_env_conf_default(fake_repo: Path, monkeypatch) -> None:
    _write_conf(fake_repo, "DATABASE_HOST=confhost\n")
    # conf beats the built-in default ("localhost").
    assert load_settings().database_host == "confhost"
    # env beats conf.
    monkeypatch.setenv("DATABASE_HOST", "envhost")
    assert load_settings().database_host == "envhost"
    # explicit overrides beat env.
    assert load_settings({"DATABASE_HOST": "overridehost"}).database_host == "overridehost"


def test_load_settings_does_not_mutate_environ(fake_repo: Path, monkeypatch) -> None:
    _write_conf(
        fake_repo,
        "DATABASE_USER=${SEED_USER:=seeded}\nDATABASE_HOST=${PG_HOST:-localhost}\n",
    )
    monkeypatch.setenv("PG_PORT", "5599")
    before = dict(os.environ)
    load_settings({"DATABASE_NAME": "override"})
    assert dict(os.environ) == before


def test_subprocess_env_bundles_connection_vars(fake_repo: Path, monkeypatch) -> None:
    monkeypatch.setenv("DATABASE_HOST", "db.internal")
    env = load_settings().subprocess_env()
    assert env["PGHOST"] == "db.internal"
    assert env["PG_HOST"] == "db.internal"
    assert env["DATABASE_HOST"] == "db.internal"
    assert env["RBT_PROJECT_ROOT"] == str(fake_repo.resolve())


def test_extensions_and_schemas_parsed_from_conf(fake_repo: Path) -> None:
    _write_conf(
        fake_repo,
        "DATABASE_EXTENSIONS=postgis hstore\nDATABASE_SCHEMAS=rbt geonames overture\n",
    )
    settings = load_settings()
    assert settings.database_extensions == ("postgis", "hstore")
    assert settings.database_schemas == ("rbt", "geonames", "overture")


def test_nested_fallback_expansion(fake_repo: Path) -> None:
    _write_conf(
        fake_repo,
        "DATABASE_NAME=${MY_DB:-${MY_FALLBACK:-innerdb}}\n",
    )
    assert load_settings().database_name == "innerdb"


def test_nested_fallback_with_suffix_inside_default(fake_repo: Path) -> None:
    # The OSM_LOG_FILE idiom: a nested expression plus literal text, all
    # inside the outer default.
    _write_conf(
        fake_repo,
        "DATABASE_HOST=${UNSET_HOST:-${INNER_HOST:-fallback.host}.suffix}\n",
    )
    assert load_settings().database_host == "fallback.host.suffix"


def test_osm_connection_template_expands_like_bash(fake_repo: Path) -> None:
    # The rbt.conf OSM_CONNECTION idiom: nested ${...} references inside the
    # outer ${OSM_CONNECTION:-...} default must each expand (regression: a
    # first-} regex scan leaked literal "${DATABASE_USER" into the URL).
    _write_conf(
        fake_repo,
        "DATABASE_USER=alice\n"
        "DATABASE_PASSWORD=secret\n"
        "DATABASE_HOST=db.internal\n"
        "DATABASE_PORT=5433\n"
        "DATABASE_NAME=rbt\n"
        "OSM_CONNECTION=${OSM_CONNECTION:-postgis://${DATABASE_USER}:${DATABASE_PASSWORD}@${DATABASE_HOST}:${DATABASE_PORT}/${DATABASE_NAME}?prefix=NONE}\n",
    )
    settings = load_settings()
    assert settings.imposm_connection() == "postgis://alice:secret@db.internal:5433/rbt?prefix=NONE"
