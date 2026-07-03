"""Typed settings for RBT Vector Tiles.

Reads values from:

1. Environment variables (highest precedence).
2. ``config/rbt.conf`` (Bash-style ``KEY=VALUE`` entries; the ``${X:-Y}``
   fallbacks in that file are collapsed using the current environment when
   the file is parsed).
3. Built-in defaults in this module.

The resulting :class:`Settings` object is immutable; mutate via overrides
passed to :func:`load_settings`.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote

from psycopg.conninfo import make_conninfo

from .paths import config_dir, project_root

_ASSIGNMENT_RE = re.compile(r"^([A-Z_][A-Z0-9_]*)=(.*)$")


@dataclass(frozen=True, slots=True)
class Settings:
    """Resolved configuration used throughout the CLI."""

    # Database connection
    database_host: str = "localhost"
    database_port: int = 5432
    database_name: str = "rbt"
    database_user: str = "postgres"
    database_password: str = ""

    # Processing
    max_parallel_jobs: int = 4
    retry_count: int = 3
    retry_delay: int = 30
    log_level: str = "INFO"

    # Tile generation
    tile_cache_dir: Path = Path("./output/tiles")
    tile_temp_dir: Path = Path("/tmp/tiles")
    tile_max_zoom: int = 13
    tile_min_zoom: int = 0
    default_projection: str = "3857"

    # Scripting flags
    debug: bool = False
    verbose: bool = False

    # Paths
    project_root: Path = Path(".")
    config_file: Path = Path("config/rbt.conf")
    shared_log_dir: Path = Path("./output/logs")
    shared_temp_dir: Path = Path("./output/temp")

    # Database provisioning + validation expectations
    database_extensions: tuple[str, ...] = ("postgis", "postgis_raster", "hstore", "pg_trgm")
    database_schemas: tuple[str, ...] = (
        "fieldmap",
        "mirta",
        "naturalearth",
        "ourairports",
        "rbt",
        "geonames",
        "overture",
    )
    disk_space_required_gb: int = 100
    memory_required_gb: int = 16

    # OSM continuous updates
    osm_config_file: Path = Path("setup/data-sources/osm/imposm-config.json")

    # OSM data import (planet download → diffs → imposm)
    osm_data_dir: Path = Path("/mnt/data")
    osm_cache_dir: Path = Path("/mnt/cache")
    osm_diff_dir: Path = Path("/mnt/diff")
    osm_mapping_file: Path = Path("setup/data-sources/osm/imposm-mapping.yaml")
    osm_srid: int = 4326
    osm_min_pbf_size_mb: int = 50000
    osm_diff_start_seq: int = 713
    osm_diff_end_seq: int = 730
    osm_connection_override: str = ""  # OSM_CONNECTION; else derived from database_*
    osm_validate_downloads: bool = True
    osm_cleanup_on_exit: bool = True
    aria2c_max_downloads: int = 12
    aria2c_max_connections: int = 16
    aria2c_splits: int = 9
    # Parallel single-URL downloads (env key WGET_PARALLEL_JOBS for
    # backwards compatibility with the retired wget-based importer).
    download_parallel_jobs: int = 8
    clean_temp_files: bool = False

    # Overture buildings import
    overture_release: str = "2026-06-17.0"
    overture_s3_bucket: str = "s3://overturemaps-us-west-2/"

    def imposm_connection(self) -> str:
        """imposm's postgis:// connection URL (OSM_CONNECTION override wins).

        imposm parses a URL, not a libpq conninfo, and does not read
        PGPASSWORD — the password must be embedded. process.run() redacts
        URL userinfo before logging.
        """
        if self.osm_connection_override:
            return self.osm_connection_override
        auth = quote(self.database_user, safe="")
        if self.database_password:
            auth += ":" + quote(self.database_password, safe="")
        return (
            f"postgis://{auth}@{self.database_host}:{self.database_port}"
            f"/{self.database_name}?prefix=NONE"
        )

    def psql_conn_string(self, dbname: str | None = None) -> str:
        # make_conninfo escapes values (quoting spaces, backslashes, quotes), so
        # a password like ``p'ss word`` produces a valid libpq conninfo string
        # instead of a misparsed one.
        params: dict[str, str] = {
            "host": self.database_host,
            "port": str(self.database_port),
            "dbname": dbname or self.database_name,
            "user": self.database_user,
        }
        if self.database_password:
            params["password"] = self.database_password
        return make_conninfo(**params)

    def ogr_pg_connection(self, dbname: str | None = None) -> str:
        # No password here on purpose: OGR/GDAL reads it from PGPASSWORD (supplied
        # via libpq_env()), which keeps the secret out of argv and the per-layer
        # log files written by process.run().
        conninfo = make_conninfo(
            dbname=dbname or self.database_name,
            host=self.database_host,
            port=str(self.database_port),
            user=self.database_user,
        )
        return "PG:" + conninfo

    def libpq_env(self) -> dict[str, str]:
        env = {
            "PGHOST": self.database_host,
            "PGPORT": str(self.database_port),
            "PGDATABASE": self.database_name,
            "PGUSER": self.database_user,
        }
        if self.database_password:
            env["PGPASSWORD"] = self.database_password
        return env

    def legacy_pg_env(self) -> dict[str, str]:
        env = {
            "PG_HOST": self.database_host,
            "PG_PORT": str(self.database_port),
            "PG_DATABASE": self.database_name,
            "PG_USR": self.database_user,
        }
        if self.database_password:
            env["PG_PASS"] = self.database_password
        return env

    def database_env(self) -> dict[str, str]:
        env = {
            "DATABASE_HOST": self.database_host,
            "DATABASE_PORT": str(self.database_port),
            "DATABASE_NAME": self.database_name,
            "DATABASE_USER": self.database_user,
        }
        if self.database_password:
            env["DATABASE_PASSWORD"] = self.database_password
        return env

    def subprocess_env(self) -> dict[str, str]:
        """Environment for child processes (bash scripts, psql, ogr2ogr).

        Combines libpq (``PG*``), legacy (``PG_*``), and ``DATABASE_*``
        variables so every consumer sees the same resolved connection.
        """
        return {
            **self.libpq_env(),
            **self.legacy_pg_env(),
            **self.database_env(),
            "RBT_PROJECT_ROOT": str(self.project_root),
        }


def _parse_conf_line(line: str, env: dict[str, str]) -> tuple[str, str] | None:
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        return None
    match = _ASSIGNMENT_RE.match(stripped)
    if not match:
        return None
    key, raw_value = match.group(1), match.group(2).strip()
    if not raw_value:
        return key, ""
    # Quote-aware parsing must run before comment stripping: a quoted value may
    # legitimately contain '#' (common in passwords, e.g. "pass#word"). Only an
    # unquoted '#' introduces an inline comment.
    if raw_value[0] in ("'", '"'):
        quote = raw_value[0]
        close = raw_value.find(quote, 1)
        if close != -1:
            return key, _expand_shell_vars(raw_value[1:close], env)
        # Unterminated quote: fall through to unquoted handling.
    raw_value = raw_value.split("#", 1)[0].rstrip()
    return key, _expand_shell_vars(raw_value, env)


def _expand_shell_vars(value: str, env: dict[str, str]) -> str:
    """Evaluate ``${VAR}``, ``${VAR:-default}``, ``${VAR:=default}`` expressions.

    Defaults may nest further ``${...}`` expressions (bash allows
    ``${A:-${B}/x}``; rbt.conf uses this for OSM_CONNECTION and
    OSM_LOG_FILE), so the expression is located with a brace-matching scan
    rather than a regex, which would stop at the first ``}``.

    Lookups and ``:=`` assignments operate on *env* (a local mapping), never on
    ``os.environ`` — parsing a config file must not mutate process state.
    """
    result: list[str] = []
    i = 0
    while i < len(value):
        if value.startswith("${", i):
            end = _matching_brace(value, i + 2)
            if end != -1:
                result.append(_resolve_expr(value[i + 2 : end], env))
                i = end + 1
                continue
        result.append(value[i])
        i += 1
    return "".join(result)


def _matching_brace(value: str, start: int) -> int:
    """Index of the ``}`` closing the ``${`` just before *start*, or -1."""
    depth = 1
    i = start
    while i < len(value):
        if value.startswith("${", i):
            depth += 1
            i += 2
            continue
        if value[i] == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def _resolve_expr(inner: str, env: dict[str, str]) -> str:
    # The operator is whichever of :- / := appears first (the variable name
    # itself cannot contain a colon).
    dash, assign = inner.find(":-"), inner.find(":=")
    if dash != -1 and (assign == -1 or dash < assign):
        name, default = inner[:dash], inner[dash + 2 :]
        return env.get(name) or _expand_shell_vars(default, env)
    if assign != -1:
        name, default = inner[:assign], inner[assign + 2 :]
        existing = env.get(name)
        if existing is not None and existing != "":
            return existing
        expanded = _expand_shell_vars(default, env)
        env[name] = expanded
        return expanded
    return env.get(inner, "")


def _read_conf(path: Path, env: dict[str, str]) -> dict[str, str]:
    if not path.is_file():
        return {}
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        parsed = _parse_conf_line(line, env)
        if parsed is None:
            continue
        key, value = parsed
        values[key] = value
        # Make the value visible to subsequent ${...} expansions in the same file.
        env.setdefault(key, value)
    return values


def _coerce_bool(value: str | bool | None, default: bool) -> bool:
    # "" means "unset" (resolve() returns it when no source has the key), so it
    # must fall back to the default — treating it as False would silently
    # invert documented-True defaults like OSM_VALIDATE_DOWNLOADS.
    if value is None or value == "":
        return default
    if isinstance(value, bool):
        return value
    return value.strip().lower() in {"1", "true", "yes", "y", "on"}


def _coerce_int(value: str | int | None, default: int) -> int:
    if value is None or value == "":
        return default
    if isinstance(value, int):
        return value
    try:
        return int(str(value))
    except ValueError:
        return default


def load_settings(overrides: dict[str, str] | None = None) -> Settings:
    """Build a :class:`Settings` instance from overrides + env + config file.

    Precedence (highest first): *overrides* → process environment →
    ``config/rbt.conf`` → built-in defaults. Loading settings never mutates
    ``os.environ``; values destined for child processes are passed explicitly
    (see :meth:`Settings.subprocess_env`).
    """
    root = project_root()
    conf_path = root / "config" / "rbt.conf"
    overrides = dict(overrides or {})
    expansion_env = {**os.environ, **overrides}
    conf = _read_conf(conf_path, expansion_env)

    def resolve(*keys: str, default: str = "") -> str:
        # Sources are the outer loop so precedence (overrides > env > conf) holds
        # across aliases: a legacy alias set in a higher-priority source must beat
        # the canonical alias set in a lower-priority one. Within a single source,
        # the canonical alias (listed first) wins.
        for source in (overrides, os.environ, conf):
            for key in keys:
                value = source.get(key)
                if value:
                    return value
        return default

    settings = Settings(
        database_host=resolve("DATABASE_HOST", "PG_HOST", default="localhost"),
        database_port=_coerce_int(resolve("DATABASE_PORT", "PG_PORT"), 5432),
        database_name=resolve("DATABASE_NAME", "PG_DATABASE", default="rbt"),
        database_user=resolve("DATABASE_USER", "PG_USR", default="postgres"),
        database_password=resolve("DATABASE_PASSWORD", "PG_PASS", default=""),
        max_parallel_jobs=_coerce_int(resolve("MAX_PARALLEL_JOBS"), 4),
        retry_count=_coerce_int(resolve("RETRY_COUNT"), 3),
        retry_delay=_coerce_int(resolve("RETRY_DELAY"), 30),
        log_level=resolve("LOG_LEVEL", default="INFO"),
        tile_cache_dir=Path(resolve("TILE_CACHE_DIR", default=str(root / "output" / "tiles"))),
        tile_temp_dir=Path(resolve("TILE_TEMP_DIR", default="/tmp/tiles")),
        tile_max_zoom=_coerce_int(resolve("TILE_MAX_ZOOM"), 13),
        tile_min_zoom=_coerce_int(resolve("TILE_MIN_ZOOM"), 0),
        default_projection=resolve("DEFAULT_PROJECTION", default="3857"),
        debug=_coerce_bool(resolve("DEBUG", "SCRIPT_DEBUG"), False),
        verbose=_coerce_bool(resolve("VERBOSE", "SCRIPT_VERBOSE"), False),
        project_root=root,
        config_file=conf_path,
        shared_log_dir=Path(resolve("SHARED_LOG_DIR", default=str(root / "output" / "logs"))),
        shared_temp_dir=Path(resolve("SHARED_TEMP_DIR", default=str(root / "output" / "temp"))),
        database_extensions=tuple(
            resolve("DATABASE_EXTENSIONS", default="postgis postgis_raster hstore pg_trgm").split()
        ),
        database_schemas=tuple(
            resolve(
                "DATABASE_SCHEMAS",
                default="fieldmap mirta naturalearth ourairports rbt geonames overture",
            ).split()
        ),
        disk_space_required_gb=_coerce_int(resolve("DISK_SPACE_REQUIRED_GB"), 100),
        memory_required_gb=_coerce_int(resolve("MEMORY_REQUIRED_GB"), 16),
        osm_config_file=Path(
            resolve(
                "OSM_CONFIG_FILE",
                default=str(root / "setup" / "data-sources" / "osm" / "imposm-config.json"),
            )
        ),
        osm_data_dir=Path(resolve("OSM_DATA_DIR", default="/mnt/data")),
        osm_cache_dir=Path(resolve("OSM_CACHE_DIR", default="/mnt/cache")),
        osm_diff_dir=Path(resolve("OSM_DIFF_DIR", default="/mnt/diff")),
        osm_mapping_file=Path(
            resolve(
                "OSM_MAPPING_FILE",
                default=str(root / "setup" / "data-sources" / "osm" / "imposm-mapping.yaml"),
            )
        ),
        osm_srid=_coerce_int(resolve("OSM_SRID"), 4326),
        osm_min_pbf_size_mb=_coerce_int(resolve("OSM_MIN_PBF_SIZE_MB"), 50000),
        osm_diff_start_seq=_coerce_int(resolve("DIFF_START_SEQ"), 713),
        osm_diff_end_seq=_coerce_int(resolve("DIFF_END_SEQ"), 730),
        osm_connection_override=resolve("OSM_CONNECTION", default=""),
        osm_validate_downloads=_coerce_bool(
            resolve("OSM_VALIDATE_DOWNLOADS", "VALIDATE_DOWNLOADS"), True
        ),
        osm_cleanup_on_exit=_coerce_bool(resolve("OSM_CLEANUP_ON_EXIT", "CLEANUP_ON_EXIT"), True),
        aria2c_max_downloads=_coerce_int(resolve("ARIA2C_MAX_DOWNLOADS"), 12),
        aria2c_max_connections=_coerce_int(resolve("ARIA2C_MAX_CONNECTIONS"), 16),
        aria2c_splits=_coerce_int(resolve("ARIA2C_SPLITS"), 9),
        download_parallel_jobs=_coerce_int(resolve("WGET_PARALLEL_JOBS"), 8),
        clean_temp_files=_coerce_bool(resolve("CLEAN_TEMP_FILES"), False),
        overture_release=resolve("OVERTURE_RELEASE", default="2026-06-17.0"),
        overture_s3_bucket=resolve("OVERTURE_S3_BUCKET", default="s3://overturemaps-us-west-2/"),
    )

    return settings


__all__ = ["Settings", "load_settings", "config_dir"]
