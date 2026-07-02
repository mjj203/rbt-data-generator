"""``rbt schema`` — run database schema SQL (rbt.* views)."""

from __future__ import annotations

import typer
from rich.console import Console
from rich.table import Table

from .. import schema as schema_mod
from ..layers import load_registry
from ._common import LayerType, settings_from_ctx

schema_app = typer.Typer(help="Run database schema SQL (rbt.* views).")
console = Console()


@schema_app.command("list")
def schema_list() -> None:
    """List the registered schema SQL units."""
    registry = load_registry()
    table = Table(title="RBT Schema Units")
    table.add_column("Key", style="cyan")
    table.add_column("Type", style="green")
    table.add_column("SQL file")
    table.add_column("Description")
    for unit in registry.schemas.values():
        table.add_row(unit.key, unit.layer_type, unit.sql, unit.description)
    console.print(table)


@schema_app.command("run")
def schema_run(
    ctx: typer.Context,
    keys: list[str] = typer.Argument(None, help="Schema keys (see `rbt schema list`)."),
    layer_type: LayerType | None = typer.Option(
        None, "--type", help="Run every schema of this layer type."
    ),
    all_: bool = typer.Option(False, "--all", help="Run every registered schema."),
    dry_run: bool = typer.Option(False, "--dry-run"),
) -> None:
    """Execute schema SQL files via psql (creates/refreshes the rbt.* views)."""
    run_all = all_ or layer_type is LayerType.all
    selected_keys = list(keys or [])
    selected_type = (
        layer_type.value if layer_type is not None and layer_type is not LayerType.all else None
    )
    if run_all:
        selected_keys, selected_type = [], None
    elif not selected_keys and not selected_type:
        # Refuse a bare `rbt schema run`: running every schema is a mutating,
        # maximal action and must be requested explicitly.
        raise typer.BadParameter(
            "specify schema key(s), --type <physical|cultural>, or --all; "
            "a bare `rbt schema run` no longer runs every schema."
        )
    schema_mod.run_schemas(
        settings_from_ctx(ctx),
        load_registry(),
        keys=selected_keys or None,
        layer_type=selected_type,
        dry_run=dry_run,
    )


__all__ = ["schema_app"]
