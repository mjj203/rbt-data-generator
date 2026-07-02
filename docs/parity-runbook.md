# Tile Output Parity Runbook

The Python tile engine (`rbt tiles`, the default) replaces the deprecated bash
generators under `production/tile-generation/`. Before the bash scripts are
deleted, run this one-time comparison **against a populated database** to
confirm the native output matches. CI already verifies command-level parity on
every PR; this runbook verifies the actual tile output, which requires real
data.

!!! note "Why not byte-for-byte hashes?"
    Tippecanoe output is not byte-stable across runs (internal ordering and
    timestamps vary), so this runbook compares *content*: metadata rows,
    per-zoom tile counts, and decoded layer statistics.

## Prerequisites

- A database populated via `rbt setup --all` (or the legacy
  bash setup) with the `rbt.*` views in place.
- `tippecanoe-decode` and `sqlite3` on PATH.
- Roughly 30–60 minutes and a few GB of scratch space.

## 1. Generate both outputs

Pick the representative subset below (covers polygons, points, zoom-variant
blends, and every projection backend):

```bash
# Native engine → output/tiles/...
rbt tiles --layer-type physical --projection 3857 --water --no-tile-join
rbt tiles --layer-type physical --projection 3395 --water --no-tile-join
rbt tiles --layer-type cultural --projection 3857 --building --aeroway --no-tile-join
rbt tiles --layer-type physical --projection 4326 --water

# Deprecated bash path → same layout, separate directory
TILE_CACHE_DIR=./output/tiles-bash rbt tiles --mode bash \
  --layer-type physical --projection 3857 --water --no-tile-join
TILE_CACHE_DIR=./output/tiles-bash rbt tiles --mode bash \
  --layer-type physical --projection 3395 --water --no-tile-join
TILE_CACHE_DIR=./output/tiles-bash rbt tiles --mode bash \
  --layer-type cultural --projection 3857 --building --aeroway --no-tile-join
TILE_CACHE_DIR=./output/tiles-bash rbt tiles --mode bash \
  --layer-type physical --projection 4326 --water
```

## 2. Compare MBTiles (3857 / 3395)

For each pair of `.mbtiles` files (e.g. `water_3857.mbtiles`):

```bash
NATIVE=output/tiles/physical/3857/water_3857.mbtiles
BASH=output/tiles-bash/physical/3857/water_3857.mbtiles

# a) Metadata — should match except generator/timestamps
sqlite3 "$NATIVE" "SELECT name, value FROM metadata WHERE name NOT IN
  ('generator', 'generator_options') ORDER BY name" > /tmp/native-meta.txt
sqlite3 "$BASH"   "SELECT name, value FROM metadata WHERE name NOT IN
  ('generator', 'generator_options') ORDER BY name" > /tmp/bash-meta.txt
diff /tmp/native-meta.txt /tmp/bash-meta.txt

# b) Tile counts per zoom — should match exactly
sqlite3 "$NATIVE" "SELECT zoom_level, COUNT(*) FROM tiles GROUP BY 1 ORDER BY 1" \
  > /tmp/native-counts.txt
sqlite3 "$BASH"   "SELECT zoom_level, COUNT(*) FROM tiles GROUP BY 1 ORDER BY 1" \
  > /tmp/bash-counts.txt
diff /tmp/native-counts.txt /tmp/bash-counts.txt

# c) Layer statistics — layer names, feature counts, attribute lists
tippecanoe-decode --stats "$NATIVE" | python3 -m json.tool > /tmp/native-stats.json
tippecanoe-decode --stats "$BASH"   | python3 -m json.tool > /tmp/bash-stats.json
diff /tmp/native-stats.json /tmp/bash-stats.json
```

**Pass criteria:** (a) and (b) identical; (c) identical except floating-point
jitter in simplification statistics.

## 3. Compare 4326 tile directories

```bash
NATIVE=output/tiles/physical/4326/physical_tiles
BASH=output/tiles-bash/physical/4326/physical_tiles

# Tile counts per zoom level
for d in "$NATIVE" "$BASH"; do
  echo "== $d"; find "$d" -name '*.pbf' | awk -F/ '{print $(NF-2)}' | sort | uniq -c
done

# Metadata (ignore the created timestamp)
python3 - "$NATIVE/metadata.json" "$BASH/metadata.json" <<'EOF'
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3])
for d in (a, b): d.pop("created", None)
print("MATCH" if a == b else "DIFF")
EOF
```

**Pass criteria:** per-zoom `.pbf` counts match; metadata matches modulo the
`created` timestamp. Note the bash cultural 4326 script had a table-selection
bug (undefined `*_TABLES` variables), so cultural 4326 differences where the
*native* output contains **more** layers are expected and correct.

## 4. After the runbook passes

Open a follow-up PR that removes the bash tile-generation path end to end.
Work through this checklist in order — each group depends on the previous
one still compiling/passing, so remove code before docs, and docs before
closing this runbook out.

### 4.1 Bash scripts

- [ ] `production/generate-tiles.sh`
- [ ] `production/tile-generation/` (all four generators: physical/cultural x
      3857-3395/4326)
- [ ] `production/README.md` (the script-level docs for what's being deleted)

### 4.2 Python: the `--mode bash` escape hatch

- [ ] `src/rbt/commands/tiles.py`: remove the `Mode` enum, the `--mode`
      option on `tiles_entry`, `_dispatch_bash`, and the
      `TileRequest.mode`/`.all_` fields once nothing branches on them.
- [ ] `src/rbt/bash.py`: remove `generate_tiles_bash` (and `delegate`/
      `_script_path` too, if the four data importers are the only remaining
      callers — check first, they are expected to survive this cleanup).
- [ ] `tests/test_cli_commands.py`: remove
      `test_cli_tiles_mode_bash_delegates_to_generate_tiles_sh`.
- [ ] `tests/test_bash_delegate.py`: remove or narrow to the surviving
      importer-delegation tests only.

### 4.3 Parity test suite (this module retires itself)

- [ ] `tests/test_parity_bash_native.py` — delete entirely (bash-vs-native
      command comparison no longer has a bash side to compare against).
- [ ] `tests/test_parity_golden.py` — delete, **or** keep the golden pin as a
      plain regression test for `build_tippecanoe_command` if that value is
      still wanted once bash is gone (decide at removal time).
- [ ] `tests/test_parity_parsing.py` — delete only if nothing else needs
      `parse_tippecanoe_argv`; otherwise fold into whichever file replaces
      the golden test.
- [ ] `tests/parity_support.py` — delete (shared helpers for the above).

### 4.4 CI

- [ ] `.github/workflows/ci.yml`: remove the `smoke-test` job's "Dry-run
      validation (deprecated bash path)" step and the `shell-lint` job's
      `production` entry in the `find` invocation.

### 4.5 Docs

- [ ] This runbook (`docs/parity-runbook.md`) — replace with a short note
      that the migration is complete, or delete and unlink it from
      `docs/architecture.md` / `mkdocs.yml`.
- [ ] `docs/architecture.md`, `docs/project-structure.md`: drop the "hybrid
      rule" language about `production/` being a deprecated escape hatch;
      the orchestration rule becomes simply "no bash calls Python, no bash
      calls bash" for the four remaining importers.
- [ ] `docs/cli.md` — regenerates automatically from the CLI at the next
      `mkdocs build` once `--mode`/`Mode` are gone; no manual edit needed.
- [ ] `docs/configuration.md`, `docs/operations.md`, `docs/troubleshooting.md`,
      `docs/getting-started.md`, `docs/index.md`, `docs/production-readme.md`
      — grep for `--mode bash` / `generate-tiles.sh` and remove the
      escape-hatch mentions.
- [ ] `README.md`, `CONTRIBUTING.md`, `CHANGELOG.md` — same grep; add a
      `CHANGELOG.md` entry noting the removal.

### 4.6 Registry-to-bash flag coverage guardrail

`tests/test_parity_bash_native.py::test_bash_generator_accepts_every_registry_category_flag`
(added alongside this checklist) fails loudly if a new `config/layers.yml`
category is added without a matching `--<category>` case in
`generate-tiles.sh`. It naturally disappears with the rest of §4.3 — no
separate action needed.

Record the parity results (the diff outputs above) in the PR description.
