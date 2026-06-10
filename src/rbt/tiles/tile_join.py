"""tile-join helpers for consolidating per-layer MBTiles."""

from __future__ import annotations

from collections.abc import Iterable
from pathlib import Path

from ..logging import get_logger
from ..process import run

log = get_logger(__name__)


def join_layers(
    mbtiles: Iterable[Path],
    output: Path,
    *,
    dry_run: bool = False,
    log_file: Path | None = None,
) -> Path:
    """Run ``tile-join -f -pk`` into *output*.

    In a dry run the per-layer MBTiles were never written, so the existence
    filter is skipped and the would-be command is printed instead.
    """
    mbtiles_list = [p for p in mbtiles if dry_run or p.is_file()]
    if not mbtiles_list:
        raise ValueError("No MBTiles files provided to tile-join")

    output.parent.mkdir(parents=True, exist_ok=True)
    cmd = ["tile-join", "-f", "-pk", "-o", str(output), *[str(p) for p in mbtiles_list]]
    run(cmd, log_file=log_file, dry_run=dry_run)
    log.info("Merged %d layers into %s", len(mbtiles_list), output.name)
    return output


__all__ = ["join_layers"]
