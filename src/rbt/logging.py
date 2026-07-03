"""Structured logging for the CLI.

Wraps :mod:`logging` with :class:`rich.logging.RichHandler` so that:

- TTYs get colored, level-tagged output.
- Non-TTYs (CI, Docker logs, files) emit plain timestamps.
- Each invocation can optionally duplicate to a log file.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Final

from rich.console import Console
from rich.logging import RichHandler

_LEVEL_MAP: Final[dict[str, int]] = {
    "DEBUG": logging.DEBUG,
    "INFO": logging.INFO,
    "WARN": logging.WARNING,
    "WARNING": logging.WARNING,
    "ERROR": logging.ERROR,
    "CRITICAL": logging.CRITICAL,
}


def configure_logging(
    level: str = "INFO",
    *,
    log_file: Path | None = None,
    console: Console | None = None,
) -> logging.Logger:
    """Install a :class:`RichHandler` on the root logger and return ``rbt``'s logger."""
    root = logging.getLogger()
    root.setLevel(_LEVEL_MAP.get(level.upper(), logging.INFO))

    # Close and drop any handlers from a previous configure_logging call so
    # repeated invocations (e.g. across tests) don't leak file descriptors.
    for handler in list(root.handlers):
        root.removeHandler(handler)
        handler.close()

    rich_handler = RichHandler(
        console=console or Console(stderr=True),
        rich_tracebacks=True,
        show_time=True,
        show_level=True,
        show_path=False,
        markup=False,
    )
    rich_handler.setFormatter(logging.Formatter("%(message)s", datefmt="%H:%M:%S"))
    root.addHandler(rich_handler)

    if log_file is not None:
        log_file.parent.mkdir(parents=True, exist_ok=True)
        file_handler = logging.FileHandler(log_file, encoding="utf-8", delay=True)
        file_handler.setFormatter(
            logging.Formatter(
                fmt="[%(asctime)s] [%(process)d] [%(levelname)s] %(message)s",
                datefmt="%Y-%m-%d %H:%M:%S",
            )
        )
        root.addHandler(file_handler)
        # No explicit atexit hook: the logging module already registers
        # logging.shutdown() atexit, which flushes and closes every handler.

    return logging.getLogger("rbt")


def get_logger(name: str = "rbt") -> logging.Logger:
    return logging.getLogger(name)


__all__ = ["configure_logging", "get_logger"]
