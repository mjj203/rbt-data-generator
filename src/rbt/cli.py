"""Top-level Typer application for ``rbt``.

Usage:

    rbt --help
    rbt tiles --help
    rbt tiles --layer-type physical --projection 3857 --water
    rbt osm run
    rbt setup --all
    rbt validate

This module is a thin assembler: it owns the global options (logging,
version) and mounts one sub-``Typer`` per command group from
:mod:`rbt.commands`. Each group's own options, dispatch logic, and helpers
live in its own module under ``src/rbt/commands/``.
"""

from __future__ import annotations

import sys
from datetime import datetime
from pathlib import Path

import typer
from rich.console import Console

from . import __version__
from .commands import checks as checks_commands
from .commands.importers import importers_app
from .commands.layers import layers_app
from .commands.osm import osm_app
from .commands.schema import schema_app
from .commands.setup import setup_app
from .commands.tiles import tiles_app
from .config import load_settings
from .logging import configure_logging, get_logger
from .process import CommandFailed

console = Console()
err_console = Console(stderr=True)

app = typer.Typer(
    name="rbt",
    help="RBT Vector Tiles CLI — tile generation, OSM updates, and database setup.",
    no_args_is_help=True,
    add_completion=False,
)

app.add_typer(tiles_app, name="tiles")
app.add_typer(osm_app, name="osm")
app.add_typer(setup_app, name="setup")
app.add_typer(importers_app, name="import")
app.add_typer(layers_app, name="layers")
app.add_typer(schema_app, name="schema")
checks_commands.register(app)


def _version_callback(value: bool) -> None:
    if value:
        console.print(f"rbt {__version__}")
        raise typer.Exit()


_READ_ONLY_COMMANDS = {"layers", "validate", "health"}


def _is_read_only_invocation(ctx: typer.Context) -> bool:
    invoked = ctx.invoked_subcommand
    return invoked is None or invoked in _READ_ONLY_COMMANDS


@app.callback()
def _main(
    ctx: typer.Context,
    verbose: bool = typer.Option(False, "--verbose", "-v", help="Verbose logging."),
    debug: bool = typer.Option(False, "--debug", help="Debug-level logging."),
    log_file: Path | None = typer.Option(
        None,
        "--log-file",
        help="Duplicate logs to this file (defaults to $SHARED_LOG_DIR/rbt_<ts>.log for mutating commands).",
    ),
    no_log_file: bool = typer.Option(
        False,
        "--no-log-file",
        help="Disable file logging entirely (useful for tests and short read-only commands).",
    ),
    version: bool = typer.Option(
        False,
        "--version",
        callback=_version_callback,
        is_eager=True,
        help="Show version and exit.",
    ),
) -> None:
    """Entry-point configuration (logging, settings)."""
    settings = load_settings()
    if debug or settings.debug:
        log_level = "DEBUG"
    elif verbose or settings.verbose:
        log_level = "INFO"
    else:
        log_level = settings.log_level

    resolved_log_file: Path | None
    if no_log_file:
        resolved_log_file = None
    elif log_file is not None:
        resolved_log_file = log_file
    elif _is_read_only_invocation(ctx):
        resolved_log_file = None
    else:
        resolved_log_file = settings.shared_log_dir / f"rbt_{datetime.now():%Y%m%d_%H%M%S}.log"

    configure_logging(level=log_level, log_file=resolved_log_file, console=err_console)
    ctx.ensure_object(dict)
    ctx.obj["settings"] = settings
    ctx.obj["log"] = get_logger("rbt.cli")


# Click object exposed for the docs build (mkdocs-click renders docs/cli.md
# from this at every `mkdocs build`, so the CLI reference can never drift).
click_app = typer.main.get_command(app)


def main() -> None:  # pragma: no cover - CLI entry
    try:
        app()
    except CommandFailed as exc:
        # Preserve the underlying process exit code instead of collapsing to 1.
        err_console.print(f"[red]error:[/red] {exc}")
        get_logger("rbt").debug("command failed in CLI", exc_info=exc)
        sys.exit(exc.returncode or 1)
    except Exception as exc:  # noqa: BLE001 - top-level CLI safety net
        err_console.print(f"[red]error:[/red] {type(exc).__name__}: {exc}")
        get_logger("rbt").debug("unhandled exception in CLI", exc_info=exc)
        sys.exit(1)


if __name__ == "__main__":  # pragma: no cover
    main()
