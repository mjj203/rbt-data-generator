# Contributing to RBT Vector Tiles

Thanks for your interest in improving the project.

## Development setup

```bash
git clone https://github.com/MJJ203/rbt-data-generator.git
cd rbt-data-generator

# Python (the rbt CLI and tests) — uv recommended
uv sync --extra dev
uv run pytest
uv run ruff check src tests
uv run mypy src

# Bash leaf scripts: lint locally
brew install shellcheck hadolint   # or apt-get install
find setup production scripts tools -name "*.sh" -print0 \
  | xargs -0 shellcheck -x

# SQL: lint with sqlfluff
uv run --with "sqlfluff>=3.0" sqlfluff lint setup/data-sources/schemas --dialect postgres

# Docs site
pip install -r requirements-docs.txt && pip install -e .
mkdocs serve
```

## Documentation

`docs/cli.md` is **regenerated at every `mkdocs build`** by
[`docs/_hooks/gen_cli_reference.py`](https://github.com/MJJ203/rbt-data-generator/blob/main/docs/_hooks/gen_cli_reference.py),
which shells out to `python -m typer rbt.cli utils docs` against the live
Typer app. Edit CLI help text in `src/rbt/cli.py` / `src/rbt/commands/*.py`
— never edit `docs/cli.md` directly, since `mkdocs build` (and CI) will
overwrite it.

## Architecture rule

**Only the `rbt` CLI dispatches.** No bash script calls Python; no bash script
calls another bash script. The bash that remains is leaf-only:

- the four data importers under `setup/data-sources/` (reached via
  `rbt import ...` / `rbt setup`), and
- the deprecated tile generators under `production/` (reached via
  `rbt tiles --mode bash`, pending removal per
  [docs/parity-runbook.md](https://mjj203.github.io/rbt-data-generator/parity-runbook/)).

New orchestration logic belongs in `src/rbt/`; new layer definitions belong in
[`config/layers.yml`](https://github.com/MJJ203/rbt-data-generator/blob/main/config/layers.yml), never in bash.

## Branching and commits

- Branch off `main`; use short, hyphen-separated names (`fix/docker-pg-version`).
- Keep commits focused. Prefer conventional-commit-style prefixes (`fix:`,
  `feat:`, `docs:`, `refactor:`, `chore:`).
- Run `rbt smoke` (or `docker compose --profile smoke up rbt-smoke`) before
  opening a PR.

## Pull requests

Before requesting review:

- [ ] `uv run ruff check src tests`, `uv run mypy src`, and `uv run pytest` pass
- [ ] `shellcheck` clean on any touched `.sh` file
- [ ] `sqlfluff lint` clean on any touched `.sql` file
- [ ] `hadolint` clean on any touched Dockerfile
- [ ] Docs updated (README, `docs/*.md`) for any user-visible change
- [ ] New configuration keys documented in [`docs/configuration.md`](https://mjj203.github.io/rbt-data-generator/configuration/)

CI runs the same checks — you can preview them in `.github/workflows/ci.yml`.

Testing happens at three tiers:

1. **Per-PR unit + dry-run** — the `python` job (ruff, mypy, pytest with a
   92% coverage floor) and the `smoke-test` job (CLI dry-runs against a
   PostGIS service container).
2. **Per-PR seeded integration** — the `integration-tiles` job generates real
   tiles in every projection from small synthetic seed tables
   (`tests/fixtures/seed_water.sql`, `seed_building.sql`).
3. **Nightly OSM fixture** — `.github/workflows/nightly.yml` runs the real
   import → schema → tiles pipeline on a committed Liechtenstein extract,
   plus a probe of small live upstream data sources. Trigger it manually
   with `gh workflow run nightly.yml`; see the
   [Operations Guide](https://mjj203.github.io/rbt-data-generator/operations/)
   for what a red run means.

## Adding a new tile layer

The generators are data-driven; adding a layer means:

1. Add the view / SQL to the appropriate schema file under
   `setup/data-sources/schemas/` and register it in the `schemas:` block of
   `config/layers.yml` if it's a new file.
2. Add an entry to `config/layers.yml`: tippecanoe options and target
   projections for the Mercator backends, and (if the layer should exist in
   EPSG:4326) the source tables and zoom windows under `gdal_mvt:`.
3. Verify with `rbt schema run <unit>` and
   `rbt tiles --layer-type <type> --layer <key> --dry-run`.

## Reporting bugs

Use the issue templates. Include:

- Your deployment mode (bare metal vs `docker compose` vs Kubernetes)
- The output of `rbt validate`
- Relevant lines from `output/logs/`
- Steps to reproduce

## Code of conduct

This project follows the [Contributor Covenant](https://github.com/MJJ203/rbt-data-generator/blob/main/CODE_OF_CONDUCT.md).
