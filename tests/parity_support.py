"""Shared helpers for the ``test_parity_*`` modules.

Not a test module itself (no ``test_`` prefix, so pytest never collects it):
just the argv-parsing, bash-capture, and settings/registry plumbing shared by
``test_parity_parsing.py``, ``test_parity_bash_native.py``, and
``test_parity_golden.py``. See those modules' docstrings for what each one
covers; see ``docs/parity-runbook.md`` for why this parity layer exists at
all — it retires along with the deprecated bash tile generators.
"""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Any

from rbt.config import Settings
from rbt.layers import LayerRegistry, load_registry
from rbt.tiles.tippecanoe import build_tippecanoe_command

REPO_ROOT = Path(__file__).resolve().parents[1]
GENERATE_TILES = REPO_ROOT / "production" / "generate-tiles.sh"
PHYSICAL_GENERATOR = (
    REPO_ROOT / "production" / "tile-generation" / "physical" / "generate-physical-3857-3395.sh"
)
CULTURAL_GENERATOR = (
    REPO_ROOT / "production" / "tile-generation" / "cultural" / "generate-cultural-3857-3395.sh"
)

# Connection env captured at import time: the autouse ``_clean_env_and_caches``
# fixture scrubs PG*/DATABASE_* from os.environ before each test, but the bash
# scripts must see the real credentials (e.g. the CI job env) to reach a DB.
_ORIG_DB_ENV: dict[str, str] = {
    key: value for key, value in os.environ.items() if key.startswith(("PG", "DATABASE_"))
}


def settings(**overrides: Any) -> Settings:
    """Settings for a dummy DB: real credentials when present, localhost defaults."""
    return Settings(
        database_host=_ORIG_DB_ENV.get("PG_HOST", "localhost"),
        database_port=int(_ORIG_DB_ENV.get("PG_PORT", "5432")),
        database_name=_ORIG_DB_ENV.get("PG_DATABASE", "rbt"),
        database_user=_ORIG_DB_ENV.get("PG_USR", "postgres"),
        database_password=_ORIG_DB_ENV.get("PG_PASS", ""),
        project_root=REPO_ROOT,
        **overrides,
    )


def registry() -> LayerRegistry:
    # Explicit path: independent of RBT_PROJECT_ROOT (scrubbed by the autouse
    # fixture) and of any fake_repo used elsewhere in the test session.
    return load_registry(REPO_ROOT / "config" / "layers.yml")


@lru_cache(maxsize=1)
def database_reachable() -> bool:
    """Mirror generate-tiles.sh's pre-flight: ``psql <conn> -c 'SELECT 1'``."""
    conn = settings().psql_conn_string() + " connect_timeout=5"
    try:
        result = subprocess.run(
            ["psql", conn, "-X", "-c", "SELECT 1"],
            capture_output=True,
            timeout=15,
            check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


# ---------------------------------------------------------------------------
# tippecanoe argv parsing
# ---------------------------------------------------------------------------

# Short flags that consume the next token. Everything else is a standalone
# option; value-carrying flags that are pure tuning knobs (-M, -r) are folded
# into the option set as a single "flag value" token.
_VALUE_FLAGS = frozenset({"-t", "-o", "-Z", "-z", "-n", "-l", "-s", "-j", "-T", "-M", "-r"})
_OPTION_VALUE_FLAGS = frozenset({"-M", "-r"})
# Long options that take a separate-token value in some generators (e.g. bash's
# `--extra-detail 13`) but the attached form elsewhere (`--extra-detail=13`).
# Normalize the space form to the attached form so both compare equal.
_LONG_VALUE_FLAGS = frozenset({"--extra-detail"})


@dataclass(frozen=True)
class TippecanoeInvocation:
    """The comparable surface of one tippecanoe command line."""

    min_zoom: int
    max_zoom: int
    layer_name: str
    display_name: str
    source_srs: str
    filter_expr: Any  # parsed -j JSON, or None
    attr_casts: frozenset[str]  # -T column:type pairs
    options: frozenset[str]
    output_name: str  # basename only — directories are environment-specific
    input_name: str


def parse_tippecanoe_argv(argv: list[str]) -> TippecanoeInvocation:
    assert argv and argv[0] == "tippecanoe", argv
    values: dict[str, str] = {}
    attr_casts: set[str] = set()
    options: set[str] = set()
    positional: list[str] = []

    i = 1
    while i < len(argv):
        token = argv[i]
        if token in _VALUE_FLAGS:
            value = argv[i + 1]
            i += 2
            if token == "-T":
                attr_casts.add(value)
            elif token in _OPTION_VALUE_FLAGS:
                options.add(f"{token} {value}")
            else:
                values[token] = value
        elif token in _LONG_VALUE_FLAGS:
            # Normalize `--extra-detail 13` to the attached `--extra-detail=13` form.
            options.add(f"{token}={argv[i + 1]}")
            i += 2
        elif token.startswith("-"):
            options.add(token)
            i += 1
        else:
            positional.append(token)
            i += 1

    assert len(positional) == 1, f"expected exactly one input file, got {positional}"
    filter_json = values.get("-j")
    return TippecanoeInvocation(
        # tippecanoe defaults -Z to 0, so an absent -Z and an explicit "-Z 0"
        # are the same command.
        min_zoom=int(values.get("-Z", "0")),
        max_zoom=int(values["-z"]),
        layer_name=values["-l"],
        display_name=values["-n"],
        source_srs=values["-s"],
        filter_expr=json.loads(filter_json) if filter_json else None,
        attr_casts=frozenset(attr_casts),
        options=frozenset(options),
        output_name=Path(values["-o"]).name,
        input_name=Path(positional[0]).name,
    )


# ---------------------------------------------------------------------------
# Bash ground truth capture
# ---------------------------------------------------------------------------

# The generator only runs main() when executed, so sourcing it gives direct
# access to generate_water() with its hardcoded tippecanoe invocation — the
# bash dry-run (generate-tiles.sh) never echoes tippecanoe lines, it only
# echoes the sub-script dispatch. Stubbing tippecanoe captures the exact argv
# the bash path would execute, one token per line (no shell re-quoting).
_CAPTURE_SCRIPT = """\
set -eo pipefail
cd "$RBT_PARITY_REPO_ROOT"
# shellcheck disable=SC1090
source "$RBT_PARITY_GENERATOR"
PROJECTION_CODE="$RBT_PARITY_PROJECTION"
configure_projection
OUTPUT_DIR="$RBT_PARITY_WORK_DIR/out"
TEMP_DIR="$RBT_PARITY_WORK_DIR/tmp"
mkdir -p "$OUTPUT_DIR"
# A pre-existing prepared input (NDJSON for water, FlatGeoBuf for building)
# short-circuits the ogr2ogr/json steps, so no database or GDAL is needed to
# reach the tippecanoe call.
touch "$OUTPUT_DIR/$RBT_PARITY_PREP_FILE"
tippecanoe() { printf '%s\\n' tippecanoe "$@" > "$RBT_PARITY_CAPTURE_FILE"; }
"$RBT_PARITY_GENERATE_FN"
"""


def _capture_bash_argv(
    tmp_path: Path,
    projection_code: str,
    *,
    generator: Path,
    generate_fn: str,
    prep_file: str,
) -> list[str]:
    capture_file = tmp_path / "tippecanoe-argv.txt"
    env = {
        **os.environ,
        **settings().subprocess_env(),
        "RBT_PARITY_REPO_ROOT": str(REPO_ROOT),
        "RBT_PARITY_PROJECTION": projection_code,
        "RBT_PARITY_WORK_DIR": str(tmp_path),
        "RBT_PARITY_CAPTURE_FILE": str(capture_file),
        "RBT_PARITY_GENERATOR": str(generator),
        "RBT_PARITY_GENERATE_FN": generate_fn,
        "RBT_PARITY_PREP_FILE": prep_file,
    }
    result = subprocess.run(
        ["bash", "-c", _CAPTURE_SCRIPT],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert result.returncode == 0, f"bash capture failed:\n{result.stdout}\n{result.stderr}"
    assert capture_file.is_file(), "stubbed tippecanoe was never invoked"
    return capture_file.read_text(encoding="utf-8").splitlines()


def capture_bash_water_argv(tmp_path: Path, projection_code: str) -> list[str]:
    return _capture_bash_argv(
        tmp_path,
        projection_code,
        generator=PHYSICAL_GENERATOR,
        generate_fn="generate_water",
        prep_file=f"water_{projection_code}.ndjson",
    )


def capture_bash_building_argv(tmp_path: Path, projection_code: str) -> list[str]:
    return _capture_bash_argv(
        tmp_path,
        projection_code,
        generator=CULTURAL_GENERATOR,
        generate_fn="generate_building",
        prep_file=f"building_{projection_code}.fgb",
    )


def native_layer_invocation(
    tmp_path: Path, projection_code: str, layer_key: str
) -> TippecanoeInvocation:
    reg = registry()
    layer = reg.layer(layer_key)
    projection = reg.projections[projection_code]
    basename = layer.output_basename(projection.code)
    cmd = build_tippecanoe_command(
        layer=layer,
        settings=settings(tile_temp_dir=tmp_path / "tmp"),
        input_file=tmp_path / "out" / f"{basename}.fgb",
        output_file=tmp_path / "out" / f"{basename}.mbtiles",
        registry=reg,
    )
    return parse_tippecanoe_argv(cmd)


def native_water_invocation(tmp_path: Path, projection_code: str) -> TippecanoeInvocation:
    return native_layer_invocation(tmp_path, projection_code, "water")


# ---------------------------------------------------------------------------
# Known divergence between config/layers.yml and the bash ground truth
# ---------------------------------------------------------------------------
# These two sets pin REAL, currently-shipping drift for the water layer; they
# are an exact symmetric difference, not an allowance. If either side changes
# — a flag is added to config/layers.yml or removed from generate_water() —
# the parity test fails and the change must be reconciled deliberately:
# shrink these sets toward empty (the goal before the bash path is deleted,
# see docs/parity-runbook.md) rather than growing them.
#
# Reported drift (bash generate_water() vs the water entry in layers.yml):
#   * bash passes feature/perf tuning the registry lacks:
#       -M 200000, -X, --detect-longitude-wraparound, --reorder, --coalesce
#   * the registry adds an option bash never passed for water:
#       --no-simplification-of-shared-nodes
BASH_ONLY_WATER_OPTIONS = frozenset(
    {
        "-M 200000",
        "-X",
        "--detect-longitude-wraparound",
        "--reorder",
        "--coalesce",
    }
)
NATIVE_ONLY_WATER_OPTIONS = frozenset({"--no-simplification-of-shared-nodes"})
