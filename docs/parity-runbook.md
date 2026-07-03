# Parity Runbook — Completed

The deprecated bash tile generators (`production/generate-tiles.sh` and the
four scripts under `production/tile-generation/`) have been **removed**. The
native Python engine (`rbt tiles`) is the only tile-generation path.

## How parity was verified

This runbook originally required a one-time bash-vs-native output comparison
against a populated database before removal. That comparison was executed
automatically by the temporary `parity-bridge` job in
`.github/workflows/nightly.yml`, which:

1. imported the committed Liechtenstein OSM fixture into a PostGIS service
   container and built the `water`/`landcover`/`highway`/`railway` schema
   units (plus the synthetic `rbt.building` seed),
2. generated the runbook's tile subset with **both** implementations —
   physical water in EPSG:3857/3395/4326 and cultural building in EPSG:3857,
3. compared per-zoom tile counts, core metadata (sans generator fields), and
   decoded layer sets — strictly for building; with relaxed criteria for
   water, whose bash/native option sets had documented, deliberate drift
   (bash passed `-X`/`--coalesce`/`--reorder`; native adds
   `--no-simplification-of-shared-nodes`).

The green verification run:
[nightly run 28636369605](https://github.com/mjj203/rbt-data-generator/actions/runs/28636369605)
(`nightly-osm-fixture` and `parity-bridge` both passed; all runbook
comparisons reported `PARITY BRIDGE: all comparisons passed`).

## What replaced the parity suite

- `tests/test_tippecanoe_golden.py` — unconditional golden pin of the
  registry→tippecanoe command for the water layer.
- `tests/test_layers.py::test_cli_category_flag_tuples_match_live_registry` —
  the registry↔CLI-flag consistency guardrail.
- The nightly `nightly-osm-fixture` job — continuous end-to-end verification
  of the native engine against real OSM data in all three projections.
