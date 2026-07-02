"""Pure-Python golden pin of the native tippecanoe command.

Split out from ``test_parity_commands.py``: unlike ``test_parity_bash_native.py``,
this canary needs neither bash nor a database, so it runs unconditionally in
every environment (see that module's docstring for the bash-dependent parity
checks this complements).
"""

from __future__ import annotations

from pathlib import Path

from rbt.tiles.tippecanoe import build_tippecanoe_command
from tests.parity_support import registry, settings


def test_native_water_command_matches_frozen_golden(tmp_path: Path) -> None:
    """Golden pin of the native water command from the REAL registry.

    Purpose: the bash-vs-native tests need bash; this pure-Python canary
    runs everywhere and freezes what `rbt tiles --water` would hand to
    tippecanoe for EPSG:3857. If it fails, the water entry in config/layers.yml
    (or build_tippecanoe_command) changed: verify the change is intentional,
    update this golden list, and keep BASH_ONLY/NATIVE_ONLY_WATER_OPTIONS in
    ``tests/parity_support.py`` in sync with the new reality.
    """
    reg = registry()
    layer = reg.layer("water")
    input_file = tmp_path / "water_3857.fgb"
    output_file = tmp_path / "water_3857.mbtiles"
    cmd = build_tippecanoe_command(
        layer=layer,
        settings=settings(tile_temp_dir=Path("/tmp/tiles")),
        input_file=input_file,
        output_file=output_file,
        registry=reg,
    )

    golden = [
        "tippecanoe",
        "-t",
        "/tmp/tiles",
        "-o",
        str(output_file),
        "-P",
        "-s",
        "EPSG:3857",
        "-Z",
        "0",
        "-z",
        "13",
        "-n",
        "water",
        "-l",
        "water",
        "--no-progress-indicator",
        "--single-precision",
        "--extra-detail=13",
        "--drop-smallest-as-needed",
        "--simplify-only-low-zooms",
        "--no-simplification-of-shared-nodes",
        "--no-tiny-polygon-reduction-at-maximum-zoom",
        str(input_file),
    ]
    assert cmd == golden
