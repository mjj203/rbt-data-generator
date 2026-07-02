"""Unit tests for the tippecanoe argv parser used by the parity tests.

Pure Python, no bash or database involved — split out from
``test_parity_commands.py`` (see ``docs/parity-runbook.md`` for why the
parity layer exists). ``test_parity_bash_native.py`` and
``test_parity_golden.py`` both rely on :func:`parse_tippecanoe_argv` being
correct; this module tests the parser itself directly.
"""

from __future__ import annotations

from rbt.commands.tiles import CULTURAL_CATEGORY_FLAGS, PHYSICAL_CATEGORY_FLAGS
from tests.parity_support import parse_tippecanoe_argv, registry


def test_category_flag_tuples_match_live_registry() -> None:
    """The hardcoded ``rbt tiles`` category flags must equal the categories in
    ``config/layers.yml``.

    The bash guardrail only compares these tuples against the bash script, so a
    category added straight to the YAML (without updating the Python constants)
    would slip through. Cross-checking against the live registry closes that gap:
    the tuples and the registry categories must stay in exact lockstep.
    """
    reg = registry()
    assert set(PHYSICAL_CATEGORY_FLAGS) == set(reg.categories_for("physical"))
    assert set(CULTURAL_CATEGORY_FLAGS) == set(reg.categories_for("cultural"))


def test_parses_flags_zooms_and_positional_input() -> None:
    argv = [
        "tippecanoe",
        "-t",
        "/tmp/tiles",
        "-o",
        "/out/water_3857.mbtiles",
        "-P",
        "-s",
        "EPSG:3857",
        "-Z",
        "2",
        "-z",
        "13",
        "-n",
        "water",
        "-l",
        "water",
        "--no-progress-indicator",
        "/tmp/water_3857.fgb",
    ]
    invocation = parse_tippecanoe_argv(argv)

    assert (invocation.min_zoom, invocation.max_zoom) == (2, 13)
    assert invocation.layer_name == invocation.display_name == "water"
    assert invocation.source_srs == "EPSG:3857"
    assert invocation.output_name == "water_3857.mbtiles"
    assert invocation.input_name == "water_3857.fgb"
    assert "-P" in invocation.options
    assert "--no-progress-indicator" in invocation.options


def test_absent_zoom_flag_defaults_to_zero() -> None:
    argv = [
        "tippecanoe",
        "-o",
        "out.mbtiles",
        "-z",
        "13",
        "-n",
        "x",
        "-l",
        "x",
        "-s",
        "EPSG:3857",
        "in.fgb",
    ]
    assert parse_tippecanoe_argv(argv).min_zoom == 0


def test_option_value_flags_fold_into_a_single_option_token() -> None:
    argv = [
        "tippecanoe",
        "-o",
        "out.mbtiles",
        "-z",
        "13",
        "-n",
        "x",
        "-l",
        "x",
        "-s",
        "EPSG:3857",
        "-M",
        "200000",
        "in.fgb",
    ]
    invocation = parse_tippecanoe_argv(argv)
    assert "-M 200000" in invocation.options
    assert "-M" not in invocation.options


def test_attr_casts_are_collected_separately_from_options() -> None:
    argv = [
        "tippecanoe",
        "-o",
        "out.mbtiles",
        "-z",
        "13",
        "-n",
        "x",
        "-l",
        "x",
        "-s",
        "EPSG:3857",
        "-T",
        "height:float",
        "-T",
        "levels:int",
        "in.fgb",
    ]
    invocation = parse_tippecanoe_argv(argv)
    assert invocation.attr_casts == frozenset({"height:float", "levels:int"})
    assert not any("height" in opt for opt in invocation.options)


def test_filter_json_is_parsed_not_left_as_a_string() -> None:
    argv = [
        "tippecanoe",
        "-o",
        "out.mbtiles",
        "-z",
        "13",
        "-n",
        "x",
        "-l",
        "x",
        "-s",
        "EPSG:3857",
        "-j",
        '{"*": ["any", true]}',
        "in.fgb",
    ]
    invocation = parse_tippecanoe_argv(argv)
    assert invocation.filter_expr == {"*": ["any", True]}


def test_missing_positional_input_raises() -> None:
    argv = ["tippecanoe", "-o", "out.mbtiles", "-z", "13", "-n", "x", "-l", "x", "-s", "EPSG:3857"]
    try:
        parse_tippecanoe_argv(argv)
    except AssertionError as exc:
        assert "expected exactly one input file" in str(exc)
    else:
        raise AssertionError("expected AssertionError for missing positional input")
