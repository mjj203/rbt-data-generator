"""Command-level parity between the Python tile engine and the deprecated bash
generators.

The deprecated scripts under ``production/tile-generation/`` are the ground
truth until the real-data runbook (``docs/parity-runbook.md``) signs off the
native output. These tests catch *command* drift between ``config/layers.yml``
(what the Python engine dispatches) and the hardcoded tippecanoe invocations in
the bash scripts, without needing tile data:

1. The bash tippecanoe argv is captured by sourcing the generator and stubbing
   ``tippecanoe`` (the generator guards ``main`` behind a BASH_SOURCE check, so
   sourcing only defines its functions). This needs bash but no database.
2. ``production/generate-tiles.sh --dry-run`` is exercised for dispatch parity,
   but only when a database is reachable — the script runs ``psql SELECT 1``
   before honouring ``--dry-run``.

Tippecanoe options are compared as *sets*: every option here is an independent
flag (or a ``flag value`` pair normalized to one token), so ordering carries no
meaning and tippecanoe treats any order identically. What matters — and what
these tests assert — is which options are present and with which values.

See ``tests/test_parity_parsing.py`` for the argv-parser's own unit tests and
``tests/test_parity_golden.py`` for the pure-Python golden pin that runs
without bash.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

from rbt.commands.tiles import CULTURAL_CATEGORY_FLAGS, PHYSICAL_CATEGORY_FLAGS
from tests.parity_support import (
    BASH_ONLY_WATER_OPTIONS,
    GENERATE_TILES,
    NATIVE_ONLY_WATER_OPTIONS,
    REPO_ROOT,
    capture_bash_building_argv,
    capture_bash_water_argv,
    database_reachable,
    native_layer_invocation,
    native_water_invocation,
    parse_tippecanoe_argv,
    settings,
)

# The deprecated bash path is scheduled for deletion after the parity runbook
# passes (docs/parity-runbook.md §4); once it is gone this module self-retires.
pytestmark = pytest.mark.skipif(
    not GENERATE_TILES.is_file() or shutil.which("bash") is None,
    reason="deprecated bash generators removed or bash unavailable",
)


@pytest.mark.parametrize("projection_code", ["3857", "3395"])
def test_water_tippecanoe_invariants_match_bash(tmp_path: Path, projection_code: str) -> None:
    """Zooms, layer naming, source SRS, filter, and -T casts must agree."""
    bash = parse_tippecanoe_argv(capture_bash_water_argv(tmp_path, projection_code))
    native = native_water_invocation(tmp_path, projection_code)

    assert (bash.min_zoom, bash.max_zoom) == (native.min_zoom, native.max_zoom)
    assert bash.layer_name == native.layer_name == "water"
    assert bash.display_name == native.display_name == "water"
    # Both backends feed tippecanoe data already reprojected by ogr2ogr and
    # declare the source as EPSG:3857 (see the comment in build_tippecanoe_command).
    assert bash.source_srs == native.source_srs == "EPSG:3857"
    assert "-P" in bash.options and "-P" in native.options
    # -j filters compare as parsed JSON, not as strings (whitespace-insensitive).
    assert bash.filter_expr == native.filter_expr
    assert bash.attr_casts == native.attr_casts
    assert bash.output_name == native.output_name == f"water_{projection_code}.mbtiles"
    # Input basenames intentionally differ (bash: GeoJSON→NDJSON, native:
    # FlatGeoBuf) — that is a pipeline difference covered by the runbook's
    # real-data comparison, not an option drift.


@pytest.mark.parametrize("projection_code", ["3857", "3395"])
def test_water_option_set_drift_is_exactly_the_known_set(
    tmp_path: Path, projection_code: str
) -> None:
    """The option sets differ by EXACTLY the pinned, reported divergence.

    Asserting the symmetric difference (instead of ignoring the known flags)
    keeps the test honest: any new flag on either side, or any reconciliation
    of the existing drift, changes the difference and fails here.
    """
    bash = parse_tippecanoe_argv(capture_bash_water_argv(tmp_path, projection_code))
    native = native_water_invocation(tmp_path, projection_code)

    assert bash.options - native.options == BASH_ONLY_WATER_OPTIONS, (
        "bash-only tippecanoe options changed — update config/layers.yml (preferred) "
        "or the pinned drift set, and re-run docs/parity-runbook.md"
    )
    assert native.options - bash.options == NATIVE_ONLY_WATER_OPTIONS, (
        "native-only tippecanoe options changed — update config/layers.yml (preferred) "
        "or the pinned drift set, and re-run docs/parity-runbook.md"
    )


@pytest.mark.parametrize("projection_code", ["3857", "3395"])
def test_building_tippecanoe_invariants_match_bash(tmp_path: Path, projection_code: str) -> None:
    """A cultural layer (building) must match the bash generator on zooms, layer
    naming, source SRS, the -j filter, and -T casts.

    The other parity tests only exercised the physical water layer; this extends
    the bash-vs-native comparison to the cultural pipeline so a cultural registry
    change that diverges from the deprecated generator is caught.
    """
    bash = parse_tippecanoe_argv(capture_bash_building_argv(tmp_path, projection_code))
    native = native_layer_invocation(tmp_path, projection_code, "building")

    assert (bash.min_zoom, bash.max_zoom) == (native.min_zoom, native.max_zoom)
    assert bash.layer_name == native.layer_name == "building"
    assert bash.display_name == native.display_name == "building"
    assert bash.source_srs == native.source_srs == "EPSG:3857"
    # -j filters compare as parsed JSON (whitespace-insensitive); the registry
    # `filters.building` entry must match the bash BUILDING_FILTER.
    assert bash.filter_expr == native.filter_expr
    assert bash.attr_casts == native.attr_casts
    assert bash.output_name == native.output_name == f"building_{projection_code}.mbtiles"


def test_bash_generator_accepts_every_registry_category_flag() -> None:
    """Every category flag ``rbt tiles`` exposes must have a matching case-arm
    in ``generate-tiles.sh``'s argument parser, since ``--mode bash`` forwards
    them verbatim (see :mod:`rbt.commands.tiles`). Catches the exact
    hyphen/underscore drift bug this registry-backed flag design prevents on
    the Python side from silently reappearing on the bash side — e.g. a new
    ``config/layers.yml`` category added without updating the bash script.
    """
    script_text = GENERATE_TILES.read_text(encoding="utf-8")
    expected_flags = {
        f"--{category.replace('_', '-')}"
        for category in (*CULTURAL_CATEGORY_FLAGS, *PHYSICAL_CATEGORY_FLAGS)
    }
    missing = sorted(flag for flag in expected_flags if f"{flag})" not in script_text)
    assert not missing, (
        f"production/generate-tiles.sh has no case-arm for {missing}; "
        "the --mode bash escape hatch would silently ignore these flags "
        "(see docs/parity-runbook.md §4.6)"
    )


@pytest.mark.skipif(
    not database_reachable(),
    reason="generate-tiles.sh runs `psql SELECT 1` before honouring --dry-run; "
    "no database reachable with the current PG_* environment",
)
def test_generate_tiles_dry_run_dispatches_water(tmp_path: Path) -> None:
    """`generate-tiles.sh --dry-run` routes --water to the physical 3857 generator."""
    env = {
        **os.environ,
        **settings().subprocess_env(),
        # Keep the run from writing logs/tiles into the working tree.
        "SHARED_LOG_DIR": str(tmp_path / "logs"),
        "TILE_CACHE_DIR": str(tmp_path / "tiles"),
        "TILE_TEMP_DIR": str(tmp_path / "tmp"),
    }
    result = subprocess.run(
        [
            "bash",
            str(GENERATE_TILES),
            "--layer-type",
            "physical",
            "--projection",
            "3857",
            "--water",
            "--dry-run",
        ],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    output = result.stdout + result.stderr
    assert result.returncode == 0, output

    dry_run_lines = [line for line in output.splitlines() if "[DRY RUN] Would execute:" in line]
    assert len(dry_run_lines) == 1, output
    dispatch = dry_run_lines[0]
    assert "generate-physical-3857-3395.sh" in dispatch
    assert "--projection 3857" in dispatch
    assert "--water" in dispatch
    # tile-join/BTIS default on in both the bash wrapper and `rbt tiles`.
    assert "--tile-join" in dispatch
    assert "--add-btis" in dispatch
    assert "generate-cultural" not in output
