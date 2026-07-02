"""``rbt validate`` / ``rbt smoke`` / ``rbt health`` — top-level operational checks.

Unlike the other command modules, these mount directly on the root ``app``
(not a sub-``Typer``) since they are single top-level verbs, not a group.
"""

from __future__ import annotations

import typer

from .. import checks as checks_mod
from ._common import settings_from_ctx


def register(app: typer.Typer) -> None:
    """Attach ``validate``/``smoke``/``health`` to the root Typer app."""

    @app.command("validate")
    def validate(ctx: typer.Context) -> None:
        """Pre-flight validation: config, tools, database, disk, and memory."""
        raise typer.Exit(checks_mod.validate(settings_from_ctx(ctx)))

    @app.command("smoke")
    def smoke(ctx: typer.Context) -> None:
        """End-to-end sanity check (validate, bootstrap, schemas, tile dry-runs)."""
        raise typer.Exit(checks_mod.smoke(settings_from_ctx(ctx)))

    @app.command("health")
    def health(ctx: typer.Context) -> None:
        """Fast liveness probe used by the Docker HEALTHCHECK."""
        raise typer.Exit(checks_mod.health(settings_from_ctx(ctx)))


__all__ = ["register"]
