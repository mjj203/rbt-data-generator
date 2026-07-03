"""Pure-Python golden pin of the native tippecanoe command.

Successor to the retired bash-vs-native parity suite (the bash generators
were removed after the parity bridge in the nightly workflow confirmed output
parity on a fixture database — see docs/parity-runbook.md's completion note).
This canary needs neither bash nor a database, so it runs unconditionally and
freezes what the registry hands to tippecanoe.
"""

from __future__ import annotations

from pathlib import Path

from rbt.config import Settings
from rbt.layers import LayerRegistry, load_registry
from rbt.tiles.tippecanoe import build_tippecanoe_command

REPO_ROOT = Path(__file__).resolve().parents[1]


def real_registry() -> LayerRegistry:
    # Explicit path: independent of RBT_PROJECT_ROOT (scrubbed by the autouse
    # fixture) and of any fake_repo used elsewhere in the test session.
    return load_registry(REPO_ROOT / "config" / "layers.yml")


def test_native_water_command_matches_frozen_golden(tmp_path: Path) -> None:
    """Golden pin of the native water command from the REAL registry.

    If it fails, the water entry in config/layers.yml (or
    build_tippecanoe_command) changed: verify the change is intentional, then
    update this golden list.
    """
    reg = real_registry()
    layer = reg.layer("water")
    input_file = tmp_path / "water_3857.fgb"
    output_file = tmp_path / "water_3857.mbtiles"
    cmd = build_tippecanoe_command(
        layer=layer,
        settings=Settings(project_root=REPO_ROOT, tile_temp_dir=Path("/tmp/tiles")),
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
