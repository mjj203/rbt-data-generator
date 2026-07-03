"""Direct unit tests for the rbt.conf ``${...}`` expansion internals.

``tests/test_config_env.py`` exercises these through ``load_settings()``; the
tests here pin down the low-level contract of ``_expand_shell_vars`` /
``_matching_brace`` / ``_resolve_expr`` so a regression in brace matching or
operator handling fails loudly instead of surfacing as a corrupted connection
string at runtime.
"""

from __future__ import annotations

from rbt.config import _expand_shell_vars, _matching_brace, _resolve_expr

# ---------------------------------------------------------------------------
# _expand_shell_vars
# ---------------------------------------------------------------------------


def test_plain_variable_expands() -> None:
    assert _expand_shell_vars("${A}", {"A": "x"}) == "x"


def test_missing_variable_expands_to_empty() -> None:
    assert _expand_shell_vars("${MISSING}", {}) == ""


def test_text_around_expression_is_preserved() -> None:
    assert _expand_shell_vars("pre-${A}-post", {"A": "mid"}) == "pre-mid-post"


def test_multiple_expressions_in_one_value() -> None:
    env = {"A": "1", "B": "2"}
    assert _expand_shell_vars("${A}:${B}", env) == "1:2"


def test_unclosed_brace_passes_through_literally() -> None:
    assert _expand_shell_vars("${A", {"A": "x"}) == "${A"
    assert _expand_shell_vars("${A:-x", {}) == "${A:-x"


def test_dollar_without_brace_passes_through() -> None:
    assert _expand_shell_vars("$A and $$", {"A": "x"}) == "$A and $$"


def test_default_used_when_unset_or_empty() -> None:
    assert _expand_shell_vars("${A:-fallback}", {}) == "fallback"
    # bash's :- treats empty as unset; the parser matches that.
    assert _expand_shell_vars("${A:-fallback}", {"A": ""}) == "fallback"
    assert _expand_shell_vars("${A:-fallback}", {"A": "set"}) == "set"


def test_nested_default_two_levels_deep() -> None:
    # rbt.conf's OSM_CONNECTION shape: ${A:-${B:-${C}}}
    assert _expand_shell_vars("${A:-${B:-${C}}}", {"C": "deep"}) == "deep"
    assert _expand_shell_vars("${A:-${B:-${C}}}", {"B": "mid", "C": "deep"}) == "mid"
    assert _expand_shell_vars("${A:-${B:-${C}}}", {"A": "top"}) == "top"


def test_nested_default_with_literal_suffix() -> None:
    env = {"B": "/base"}
    assert _expand_shell_vars("${A:-${B}/logs/${C:-run}.log}", env) == "/base/logs/run.log"


def test_literal_brace_after_expression() -> None:
    assert _expand_shell_vars("${A:-x}}", {}) == "x}"


# ---------------------------------------------------------------------------
# _matching_brace
# ---------------------------------------------------------------------------


def test_matching_brace_flat() -> None:
    #  ${A}  → scan starts after "${" (index 2), closer at index 3
    assert _matching_brace("${A}", 2) == 3


def test_matching_brace_skips_nested_expressions() -> None:
    value = "${A:-${B:-${C}}}"
    assert _matching_brace(value, 2) == len(value) - 1


def test_matching_brace_unclosed_returns_minus_one() -> None:
    assert _matching_brace("${A:-${B}", 2) == -1


# ---------------------------------------------------------------------------
# _resolve_expr
# ---------------------------------------------------------------------------


def test_resolve_expr_first_operator_wins() -> None:
    # ":-" before ":=" → the whole tail is the :- default, not an assignment.
    env: dict[str, str] = {}
    assert _resolve_expr("A:-b:=c", env) == "b:=c"
    assert env == {}


def test_assign_operator_sets_local_env_only() -> None:
    env: dict[str, str] = {"B": "seed"}
    assert _resolve_expr("A:=${B}-grown", env) == "seed-grown"
    assert env["A"] == "seed-grown"
    # subsequent lookups see the assignment
    assert _expand_shell_vars("${A}", env) == "seed-grown"


def test_assign_operator_keeps_existing_nonempty_value() -> None:
    env = {"A": "kept"}
    assert _resolve_expr("A:=ignored", env) == "kept"
    assert env["A"] == "kept"


def test_assign_operator_overwrites_empty_value() -> None:
    env = {"A": ""}
    assert _resolve_expr("A:=filled", env) == "filled"
    assert env["A"] == "filled"
