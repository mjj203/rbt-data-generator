"""Typer sub-applications, one module per command group.

``src/rbt/cli.py`` stays a thin assembler: it creates the root ``app``,
mounts each sub-app from this package, and owns only the global
``--verbose``/``--debug``/``--log-file`` plumbing plus the top-level
``validate``/``smoke``/``health`` commands.
"""

from __future__ import annotations
