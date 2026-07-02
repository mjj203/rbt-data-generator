"""Shared enums and context helpers used by two or more command modules."""

from __future__ import annotations

from enum import Enum

import typer

from ..config import Settings


class LayerType(str, Enum):
    physical = "physical"
    cultural = "cultural"
    all = "all"


def settings_from_ctx(ctx: typer.Context) -> Settings:
    settings: Settings = ctx.obj["settings"]
    return settings


__all__ = ["LayerType", "settings_from_ctx"]
