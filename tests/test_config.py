"""Tests for the typed settings loader."""

from __future__ import annotations

from rbt.config import Settings, load_settings


def test_load_settings_populates_defaults(monkeypatch) -> None:
    monkeypatch.delenv("DATABASE_HOST", raising=False)
    monkeypatch.delenv("PG_HOST", raising=False)
    monkeypatch.delenv("DATABASE_PORT", raising=False)
    monkeypatch.delenv("DATABASE_PASSWORD", raising=False)

    settings = load_settings()
    assert isinstance(settings, Settings)
    assert settings.database_port == 5432
    assert "dbname=" in settings.psql_conn_string()
    libpq = settings.libpq_env()
    assert libpq["PGHOST"] == settings.database_host


def test_env_vars_override_config(monkeypatch) -> None:
    monkeypatch.setenv("DATABASE_HOST", "db.example.com")
    monkeypatch.setenv("DATABASE_PORT", "5533")
    settings = load_settings()
    assert settings.database_host == "db.example.com"
    assert settings.database_port == 5533


def test_legacy_pg_env_used_when_database_unset(monkeypatch) -> None:
    monkeypatch.delenv("DATABASE_HOST", raising=False)
    monkeypatch.setenv("PG_HOST", "legacy.example.com")
    settings = load_settings()
    assert settings.database_host == "legacy.example.com"
