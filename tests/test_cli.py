"""Smoke tests for the Typer CLI."""

from __future__ import annotations

from typer.testing import CliRunner

from rbt.cli import app

runner = CliRunner()


def test_version() -> None:
    result = runner.invoke(app, ["--version"])
    assert result.exit_code == 0
    assert "rbt" in result.stdout


def test_help() -> None:
    result = runner.invoke(app, ["--help"])
    assert result.exit_code == 0
    assert "tiles" in result.stdout


def test_layers_list() -> None:
    result = runner.invoke(app, ["layers", "list", "--layer-type", "physical"])
    assert result.exit_code == 0
    assert "water" in result.stdout


def test_layers_show() -> None:
    result = runner.invoke(app, ["layers", "show", "building"])
    assert result.exit_code == 0
    assert "building" in result.stdout
