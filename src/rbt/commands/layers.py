"""``rbt layers`` — inspect the declarative layer registry."""

from __future__ import annotations

from dataclasses import asdict

import typer
from rich.console import Console
from rich.table import Table

from ..layers import load_registry
from ._common import LayerType

layers_app = typer.Typer(help="Inspect the declarative layer registry.")
console = Console()


@layers_app.command("list")
def layers_list(
    layer_type: LayerType = typer.Option(LayerType.all, "--layer-type"),
) -> None:
    """List every known layer and its tippecanoe configuration."""
    registry = load_registry()
    table = Table(title="RBT Layer Registry")
    table.add_column("Key", style="cyan")
    table.add_column("Type", style="green")
    table.add_column("Category", style="yellow")
    table.add_column("Source")
    table.add_column("Zoom")
    table.add_column("Projections")
    table.add_column("Filter")

    for layer in registry.layers.values():
        if layer_type is not LayerType.all and layer.layer_type != layer_type.value:
            continue
        table.add_row(
            layer.key,
            layer.layer_type,
            layer.category,
            layer.source_table,
            f"{layer.min_zoom}→{layer.max_zoom}",
            ",".join(layer.projections),
            layer.tippecanoe.filter_ref or "",
        )
    console.print(table)


@layers_app.command("show")
def layers_show(layer_key: str = typer.Argument(...)) -> None:
    """Print a single layer's full definition."""
    registry = load_registry()
    layer = registry.layer(layer_key)

    console.print_json(data=asdict(layer))
    filter_json = registry.filter_for(layer)
    if filter_json:
        console.rule("filter")
        console.print(filter_json)


__all__ = ["layers_app"]
