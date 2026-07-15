"""``rbt export`` — export standalone data artifacts (native Python)."""

from __future__ import annotations

from pathlib import Path

import typer

from ..importers import buildings_export
from ._common import settings_from_ctx

export_app = typer.Typer(help="Export standalone data artifacts (Overture buildings → FlatGeobuf).")


@export_app.command("buildings")
def export_buildings_cmd(
    ctx: typer.Context,
    output_dir: Path | None = typer.Option(
        None, "--output-dir", help="Directory for the .fgb outputs (default: $OVERTURE_EXPORT_DIR)."
    ),
    release: str | None = typer.Option(
        None, "--release", help="Overture release to read (default: pinned in Settings)."
    ),
    keep_db: bool = typer.Option(
        False, "--keep-db", help="Keep the temporary DuckDB database after a successful run."
    ),
    dry_run: bool = typer.Option(False, "--dry-run"),
) -> None:
    """Export Overture buildings directly to FlatGeobuf via DuckDB (no PostGIS)."""
    buildings_export.export_buildings(
        settings_from_ctx(ctx),
        output_dir=output_dir,
        release=release,
        keep_db=keep_db,
        dry_run=dry_run,
    )


__all__ = ["export_app"]
