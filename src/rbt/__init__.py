"""RBT Vector Tiles — Python CLI."""

from __future__ import annotations

from importlib import metadata

try:
    __version__ = metadata.version("rbt")
except metadata.PackageNotFoundError:  # pragma: no cover
    __version__ = "0.0.0+dev"

__all__ = ["__version__"]
