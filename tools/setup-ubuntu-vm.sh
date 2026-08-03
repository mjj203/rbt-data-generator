#!/usr/bin/env bash
#
# tools/setup-ubuntu-vm.sh
#
# Bootstraps a bare-metal (or VM) Ubuntu 26.04 host with the same toolchain
# `Dockerfile.production` builds into the container image, so `rbt`
# processing (OSM import/diffs, tile generation, the DuckDB buildings export)
# can run directly on the host without Docker. See docs/installation.md for
# the manual, step-by-step version of what this script automates.
#
# Usage:
#   sudo ./setup-ubuntu-vm.sh [--with-postgres-server] [--with-rbt-cli] [--repo-dir DIR]
#
# Flags (env var equivalents in parentheses; flags win if both are set):
#   --with-postgres-server (INSTALL_POSTGRES_SERVER=1)
#       Also install a local PostgreSQL + PostGIS server and apply
#       config/postgresql.conf tuning. Client-only otherwise, matching
#       Dockerfile.production, which never runs Postgres itself.
#   --with-rbt-cli (INSTALL_RBT_CLI=1)
#       Also clone rbt-data-generator (skipped if this script is already
#       running from inside a checkout) and install the `rbt` CLI via uv.
#   --repo-dir DIR (REPO_DIR=DIR)
#       Where to clone/find the repo when --with-rbt-cli is set.
#       Default: the checkout this script lives in, or
#       $HOME/rbt-data-generator if run standalone.
#
# All version pins below default to the same values as Dockerfile.production's
# build ARGs -- override via env var to test a bump before touching the
# Dockerfile, e.g. `TIPPECANOE_REF=2.80.0 sudo -E ./setup-ubuntu-vm.sh`.
#
# Safe to re-run: existing installs are detected and skipped where cheap to
# check, but this is not exhaustively idempotent (e.g. it will not downgrade
# an already-newer tool).
set -euo pipefail

# -----------------------------------------------------------------------------
# Version pins (keep in sync with Dockerfile.production's ARGs)
# -----------------------------------------------------------------------------
POSTGRES_CLIENT_VERSION="${POSTGRES_CLIENT_VERSION:-18}"
IMPOSM_VERSION="${IMPOSM_VERSION:-0.14.2}"
# Set to the actual sha256 of the imposm release tarball to enforce verification.
# Pass `SKIP` to bypass the check (useful for local development only).
IMPOSM_SHA256="${IMPOSM_SHA256:-SKIP}"
TIPPECANOE_REF="${TIPPECANOE_REF:-2.79.0}"
MICROMAMBA_VERSION="${MICROMAMBA_VERSION:-2.8.1-0}"
PYTHON_VERSION="${PYTHON_VERSION:-3.13}"
GDAL_VERSION="${GDAL_VERSION:-3.13.1}"
DUCKDB_VERSION="${DUCKDB_VERSION:-1.5.4}"
# sha256 of the official duckdb_cli-linux-{amd64,arm64}.zip release assets for
# DUCKDB_VERSION above -- bump both together when bumping the version. Pass
# `SKIP` to bypass the check (useful for local development only).
DUCKDB_SHA256_AMD64="${DUCKDB_SHA256_AMD64:-1f2fa724fb054b3dbe1a9cbd13de5b76997d850e7087ec762ba88db04e0180cf}"
DUCKDB_SHA256_ARM64="${DUCKDB_SHA256_ARM64:-377f03fb9f17ab5a78f28f829cbfcb5333da8ab3c2d0788f27694f81df77ed29}"

INSTALL_POSTGRES_SERVER="${INSTALL_POSTGRES_SERVER:-0}"
INSTALL_RBT_CLI="${INSTALL_RBT_CLI:-0}"
REPO_DIR="${REPO_DIR:-}"
REPO_URL="${REPO_URL:-https://github.com/MJJ203/rbt-data-generator.git}"
MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-/opt/conda}"
MICROMAMBA_ENV_NAME="geo"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-postgres-server) INSTALL_POSTGRES_SERVER=1; shift ;;
    --with-rbt-cli) INSTALL_RBT_CLI=1; shift ;;
    --repo-dir)
      REPO_DIR="${2:?--repo-dir requires a value}"
      shift 2
      ;;
    --repo-dir=*)
      REPO_DIR="${1#*=}"
      shift
      ;;
    -h|--help)
      sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33mwarning: %s\033[0m\n' "$1" >&2; }

if [[ "$(id -u)" -ne 0 ]]; then
  echo "This script must be run as root, e.g.: sudo ./setup-ubuntu-vm.sh" >&2
  exit 1
fi

# The real (non-root) invoking user, so the repo clone / uv install / conda
# env end up owned by a normal user instead of root when run via sudo.
TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_HOME="${TARGET_HOME:-/root}"
run_as_target() { sudo -u "$TARGET_USER" -H bash -lc "$1"; }

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then
    warn "This script targets Ubuntu 26.04; detected ID=${ID:-unknown}. Continuing anyway."
  elif [[ "${VERSION_ID:-}" != "26.04" ]]; then
    warn "This script targets Ubuntu 26.04; detected VERSION_ID=${VERSION_ID:-unknown}. Continuing anyway."
  fi
else
  warn "Could not read /etc/os-release; assuming Ubuntu 26.04 and continuing."
fi

ARCH="$(uname -m)"

# If this script is being run from inside a checkout, default REPO_DIR to it
# and skip re-cloning, whether or not --with-rbt-cli set REPO_DIR explicitly.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "$REPO_DIR" ]]; then
  if [[ -f "$SCRIPT_DIR/../pyproject.toml" ]] && grep -q '^name = "rbt"' "$SCRIPT_DIR/../pyproject.toml" 2>/dev/null; then
    REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  else
    REPO_DIR="$TARGET_HOME/rbt-data-generator"
  fi
fi

# -----------------------------------------------------------------------------
# 1. Base prerequisites
# -----------------------------------------------------------------------------
install_prereqs() {
  log "Installing base prerequisites"
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg lsb-release unzip git \
    build-essential libsqlite3-dev zlib1g-dev
}

# -----------------------------------------------------------------------------
# 2. PGDG repo + PostgreSQL client + importer dependencies
# -----------------------------------------------------------------------------
install_pgdg_and_client() {
  log "Adding the PGDG apt repository"
  install -d /usr/share/postgresql-common/pgdg
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list
  apt-get update

  log "Installing PostgreSQL client + importer dependencies"
  apt-get install -y --no-install-recommends \
    "postgresql-client-${POSTGRES_CLIENT_VERSION}" \
    sqlite3 aria2 p7zip-full osmctools osmium-tool osmosis
}

# -----------------------------------------------------------------------------
# 2b. (optional) local PostgreSQL + PostGIS server
# -----------------------------------------------------------------------------
install_postgres_server() {
  log "Installing local PostgreSQL ${POSTGRES_CLIENT_VERSION} + PostGIS server"
  apt-get install -y --no-install-recommends \
    "postgresql-${POSTGRES_CLIENT_VERSION}" "postgresql-${POSTGRES_CLIENT_VERSION}-postgis-3"
  systemctl enable --now postgresql

  local tuned_conf="$REPO_DIR/config/postgresql.conf"
  local live_conf="/etc/postgresql/${POSTGRES_CLIENT_VERSION}/main/postgresql.conf"
  if [[ -f "$tuned_conf" && -f "$live_conf" ]]; then
    log "Applying config/postgresql.conf tuning to ${live_conf}"
    cp "$live_conf" "${live_conf}.orig-$(date +%Y%m%d%H%M%S)"
    cp "$tuned_conf" "$live_conf"
    systemctl restart postgresql
  else
    warn "config/postgresql.conf not found next to this script (pass --with-rbt-cli, or clone the repo yourself) -- skipping Postgres tuning. See docs/installation.md."
  fi
}

# -----------------------------------------------------------------------------
# 3. AWS CLI v2 (Ubuntu dropped the legacy `awscli` apt package)
# -----------------------------------------------------------------------------
install_awscli() {
  if command -v aws &>/dev/null; then
    log "AWS CLI already installed ($(aws --version)), skipping"
    return
  fi
  log "Installing AWS CLI v2"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
  rm -rf /tmp/awscliv2.zip /tmp/aws
}

# -----------------------------------------------------------------------------
# 4. Python + GDAL via micromamba/conda-forge
# -----------------------------------------------------------------------------
install_micromamba_geo_env() {
  log "Installing micromamba + the '${MICROMAMBA_ENV_NAME}' conda-forge env (Python ${PYTHON_VERSION}, GDAL ${GDAL_VERSION})"

  local mamba_arch
  case "$ARCH" in
    x86_64) mamba_arch=linux-64 ;;
    aarch64) mamba_arch=linux-aarch64 ;;
    *) echo "unsupported architecture for micromamba: ${ARCH}" >&2; exit 1 ;;
  esac

  if [[ ! -x /usr/local/bin/micromamba ]]; then
    curl -fsSL "https://github.com/mamba-org/micromamba-releases/releases/download/${MICROMAMBA_VERSION}/micromamba-${mamba_arch}" \
      -o /usr/local/bin/micromamba
    chmod +x /usr/local/bin/micromamba
  fi

  export MAMBA_ROOT_PREFIX
  if [[ ! -d "${MAMBA_ROOT_PREFIX}/envs/${MICROMAMBA_ENV_NAME}" ]]; then
    # Same package set as Dockerfile.production: libgdal-pg for `ogr2ogr PG:`
    # reads/writes, libgdal-arrow-parquet for the FieldMaps GeoParquet imports.
    micromamba create -y -n "$MICROMAMBA_ENV_NAME" -c conda-forge \
      "python=${PYTHON_VERSION}" "gdal=${GDAL_VERSION}" \
      "libgdal-pg=${GDAL_VERSION}" "libgdal-arrow-parquet=${GDAL_VERSION}" pip
    micromamba clean --all --yes
  else
    log "micromamba env '${MICROMAMBA_ENV_NAME}' already exists, skipping creation"
  fi
  chown -R "${TARGET_USER}:${TARGET_USER}" "$MAMBA_ROOT_PREFIX" 2>/dev/null || true

  local profile_snippet="/etc/profile.d/rbt-geo-env.sh"
  if [[ ! -f "$profile_snippet" ]]; then
    cat > "$profile_snippet" <<EOF
# Added by tools/setup-ubuntu-vm.sh -- puts the rbt-data-generator geo env
# (Python + GDAL) on PATH for all users.
export PATH="${MAMBA_ROOT_PREFIX}/envs/${MICROMAMBA_ENV_NAME}/bin:\$PATH"
EOF
    log "Wrote ${profile_snippet} -- start a new shell (or 'source' it) to pick up PATH"
  fi
}

# -----------------------------------------------------------------------------
# 5. tippecanoe (felt fork, built from source)
# -----------------------------------------------------------------------------
install_tippecanoe() {
  if command -v tippecanoe &>/dev/null; then
    log "tippecanoe already installed ($(tippecanoe --version 2>&1 | head -n1)), skipping"
    return
  fi
  log "Building tippecanoe ${TIPPECANOE_REF} (felt fork) from source"
  local build_dir
  build_dir="$(mktemp -d)"
  git clone --depth=1 --branch "$TIPPECANOE_REF" https://github.com/felt/tippecanoe.git "$build_dir"
  make -C "$build_dir" -j"$(nproc)"
  make -C "$build_dir" install PREFIX=/usr/local
  rm -rf "$build_dir"
}

# -----------------------------------------------------------------------------
# 6. imposm3
# -----------------------------------------------------------------------------
install_imposm() {
  if command -v imposm &>/dev/null; then
    log "imposm already installed ($(imposm version 2>&1 | head -n1)), skipping"
    return
  fi
  if [[ "$ARCH" != "x86_64" ]]; then
    warn "imposm3 only publishes Linux x86-64 binaries; skipping on ${ARCH}. OSM import/diffs must run via Docker on this host."
    return
  fi
  log "Installing imposm3 ${IMPOSM_VERSION}"
  local tmp_tar
  tmp_tar="$(mktemp --suffix=.tar.gz)"
  wget -nv -O "$tmp_tar" \
    "https://github.com/omniscale/imposm3/releases/download/v${IMPOSM_VERSION}/imposm-${IMPOSM_VERSION}-linux-x86-64.tar.gz"
  if [[ -n "$IMPOSM_SHA256" && "$IMPOSM_SHA256" != "SKIP" ]]; then
    echo "${IMPOSM_SHA256}  ${tmp_tar}" | sha256sum -c -
  fi
  local extract_dir
  extract_dir="$(mktemp -d)"
  tar -xzf "$tmp_tar" -C "$extract_dir" --strip-components=1
  install -m 0755 "$extract_dir/imposm" /usr/local/bin/imposm
  rm -rf "$tmp_tar" "$extract_dir"
}

# -----------------------------------------------------------------------------
# 7. DuckDB CLI (used by `rbt export buildings`)
# -----------------------------------------------------------------------------
install_duckdb() {
  if command -v duckdb &>/dev/null; then
    log "DuckDB already installed ($(duckdb --version)), skipping"
    return
  fi
  log "Installing DuckDB CLI ${DUCKDB_VERSION}"
  local duckdb_arch duckdb_sha256
  case "$ARCH" in
    x86_64)  duckdb_arch=amd64; duckdb_sha256="$DUCKDB_SHA256_AMD64" ;;
    aarch64) duckdb_arch=arm64; duckdb_sha256="$DUCKDB_SHA256_ARM64" ;;
    *) echo "unsupported architecture for duckdb: ${ARCH}" >&2; exit 1 ;;
  esac
  local tmp_zip
  tmp_zip="$(mktemp --suffix=.zip)"
  curl -fsSL -o "$tmp_zip" \
    "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb_cli-linux-${duckdb_arch}.zip"
  if [[ -n "$duckdb_sha256" && "$duckdb_sha256" != "SKIP" ]]; then
    echo "${duckdb_sha256}  ${tmp_zip}" | sha256sum -c -
  fi
  unzip -q -o "$tmp_zip" -d /usr/local/bin
  chmod +x /usr/local/bin/duckdb
  rm -f "$tmp_zip"
  duckdb --version
}

# -----------------------------------------------------------------------------
# 8. (optional) rbt CLI, via uv
# -----------------------------------------------------------------------------
install_rbt_cli() {
  log "Installing the rbt CLI into ${REPO_DIR}"
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    run_as_target "git clone '$REPO_URL' '$REPO_DIR'"
  else
    log "Repo already present at ${REPO_DIR}, skipping clone"
  fi
  run_as_target "command -v uv &>/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh"
  run_as_target "cd '$REPO_DIR' && \$HOME/.local/bin/uv sync"
  log "Run 'uv run rbt --help' from ${REPO_DIR} (as ${TARGET_USER}) to get started"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
install_prereqs
install_pgdg_and_client
if [[ "$INSTALL_POSTGRES_SERVER" == "1" ]]; then
  install_postgres_server
fi
install_awscli
install_micromamba_geo_env
install_tippecanoe
install_imposm
install_duckdb
if [[ "$INSTALL_RBT_CLI" == "1" ]]; then
  install_rbt_cli
fi

log "Done. Installed tool versions:"
"${MAMBA_ROOT_PREFIX}/envs/${MICROMAMBA_ENV_NAME}/bin/python" --version || true
"${MAMBA_ROOT_PREFIX}/envs/${MICROMAMBA_ENV_NAME}/bin/gdalinfo" --version || true
psql --version || true
tippecanoe --version || true
command -v imposm &>/dev/null && imposm version || true
duckdb --version || true
aws --version || true

echo
echo "Next steps:"
echo "  - Start a new shell (or 'source /etc/profile.d/rbt-geo-env.sh') to pick up PATH for python/gdal."
if [[ "$INSTALL_RBT_CLI" == "1" ]]; then
  echo "  - cd ${REPO_DIR} && uv run rbt validate"
else
  echo "  - Clone rbt-data-generator, install the CLI (uv sync), then run 'rbt validate'."
fi
