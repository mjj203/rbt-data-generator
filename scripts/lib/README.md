# scripts/lib/

Shared Bash helpers sourced by every Bash script in this repository — the
four data importer leaf scripts under `setup/data-sources/` (invoked via
`rbt import` / `rbt setup`). Sourcing these files is the way scripts should
acquire logging, configuration, and database connection helpers — do not
reimplement them locally.

## Files

### `logging.sh`

Structured logging with colorized terminal output and plain-text file duplication. Key functions:

- `rbt_log_init <file>` — redirect structured logs to `<file>` (also streams to stdout/stderr with colors preserved when writing to a terminal).
- `rbt_log <LEVEL> <message...>` — emit one log line. Levels: `ERROR`, `WARN`, `INFO`, `STEP`, `DEBUG`, `JOB`, `SUCCESS`.
- `rbt_log_progress <current> <total> <description>` — progress bar that gracefully degrades for non-tty output.

### `config.sh`

Single-place resolution of `DATABASE_*` / `PG_*` environment variables. Call `rbt_config_load` once at the top of any script:

```bash
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${PROJECT_ROOT}/scripts/lib/logging.sh"
source "${PROJECT_ROOT}/scripts/lib/config.sh"
rbt_config_load
```

After `rbt_config_load` returns:

- `config/rbt.conf` has been sourced.
- `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_NAME`, `DATABASE_USER`, `DATABASE_PASSWORD` are populated (defaulting to legacy `PG_*` values, falling back to sensible defaults).
- Legacy `PG_HOST`/`PG_PORT`/`PG_USR`/`PG_PASS`/`PG_DATABASE` are exported for downstream tools that still expect them.
- Helpers `rbt_psql_conn_string <dbname?>` and `rbt_psql_env_exports` are available.

## Conventions

- Scripts must not mutate these helpers — source-and-use only.
- All new Bash scripts must source both helpers (enforced lightly via `shellcheck` in CI).
- Python code should not call into these helpers; it has its own equivalent at `src/rbt/config.py` and `src/rbt/logging.py`.
- Bash scripts are leaf tasks: only the `rbt` CLI dispatches them (no bash calls bash, no bash calls Python — see `CONTRIBUTING.md`). When the CLI invokes a script it exports the resolved `DATABASE_*`/`PG*` environment, so `rbt_config_load` sees consistent values either way.
