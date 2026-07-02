"""Reference-data importer (FieldMaps, Natural Earth, OurAirports, etc.)."""

from __future__ import annotations

from ..bash import delegate
from ..config import Settings


def import_reference(settings: Settings, args: list[str], *, dry_run: bool = False) -> None:
    delegate(
        "setup/data-sources/reference-data/import-reference-data.sh",
        args,
        settings,
        dry_run=dry_run,
    )


__all__ = ["import_reference"]
