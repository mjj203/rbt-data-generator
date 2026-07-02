# Security Policy

## Supported versions

The `main` branch is the supported release stream. Older tags receive fixes on a best-effort basis.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for suspected vulnerabilities. Instead:

1. Report privately via GitHub's vulnerability reporting:
   <https://github.com/MJJ203/rbt-data-generator/security/advisories/new>
   (include a detailed description, reproduction steps, and impact assessment).
2. Allow up to 14 days for an initial response.
3. Coordinate disclosure timing before making details public.

## Known exceptions

- The MIRTA download in `setup/data-sources/reference-data/import-reference-data.sh`
  uses `--no-check-certificate` because the upstream DoD endpoint's certificate
  chain is not in standard trust stores. This is tracked as a known exception;
  the file's contents are validated by size and by the PostGIS import step.

## Hardening recommendations

- Run `postgres` with TLS enabled. The Dockerfiles install `postgresql-client-18` which negotiates TLS automatically.
- Never commit `.env` files. The `.gitignore` already excludes them; double-check before force-pushing.
- Rotate `DATABASE_PASSWORD` on a schedule; use `docker compose` secrets or a secrets manager rather than inline env vars in production.
- Restrict network access to the `postgres` service; the default compose file exposes port 5432 to localhost only — do not widen without a firewall in front.
- Pin base images and tool binaries (already done for `imposm3`; tippecanoe pins live in `Dockerfile.production`).

## Dependency provenance

- **imposm3 0.14.2** — downloaded from `github.com/omniscale/imposm3`; checksum verified in the Dockerfile.
- **tippecanoe** — built from `felt/tippecanoe` (maintained fork); pinned to a release tag.
- **GDAL / Python** — installed via micromamba from the `conda-forge` channel, pinned to exact versions in `Dockerfile.production`.
- **PostGIS** — installed from the official `postgis/postgis` image and distribution apt repositories with signed metadata.
