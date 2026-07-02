"""Overture Buildings importer."""

from __future__ import annotations

from ..bash import delegate
from ..config import Settings


def import_buildings(settings: Settings, args: list[str], *, dry_run: bool = False) -> None:
    delegate(
        "setup/data-sources/reference-data/import-buildings.sh",
        args,
        settings,
        dry_run=dry_run,
    )


__all__ = ["import_buildings"]
