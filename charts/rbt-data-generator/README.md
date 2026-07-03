# rbt-data-generator Helm chart

A Kubernetes translation of the project's [`docker-compose.yml`](../../docker-compose.yml).
Compose profiles (`setup`, `production`, `serve`, `smoke`, `monitoring`) become
value-driven component toggles.

## What it deploys

| Compose service   | Kubernetes resource                     | Toggle                         |
| ----------------- | --------------------------------------- | ------------------------------ |
| `postgres`        | StatefulSet + headless Service          | `postgres.enabled`             |
| `rbt-setup`       | Job (`rbt setup --all`)                 | `setup.enabled`                |
| `rbt-osm-updates` | Deployment (`rbt osm run`)              | `production.osmUpdates.enabled`|
| `rbt-tiles`       | Job (`rbt tiles --all`)                 | `production.tiles.enabled`     |
| `rbt-smoke`       | Job (`rbt smoke`)                       | `smoke.enabled`                |
| `tile-server`     | Deployment + Service                    | `tileServer.enabled`           |
| `prometheus`      | Deployment + Service + PVC              | `prometheus.enabled`           |

## Prerequisites

- Kubernetes 1.25+ and Helm 3.8+.
- The rbt image published to a registry (defaults to
  `ghcr.io/mjj203/rbt-data-generator`). Helm does not build images.
- A **ReadWriteMany** StorageClass for the shared output volume (tiles + logs +
  OSM state), which `setup`, `osm-updates`, `tiles`, `smoke`, and `tile-server`
  all mount.

## OSM state layout

OSM state — the planet PBF, imposm's LevelDB cache, and replication/diff
state — lives on the shared output volume under `config.osmDataDir` /
`config.osmCacheDir` / `config.osmDiffDir` (defaults:
`/app/output/osm/{data,cache,diff}`). It must stay on a persistent mount
shared by the setup Job and the osm-updates Deployment: `rbt osm run` applies
diffs against the imposm cache produced by `rbt setup --all`, and the code's
built-in `/mnt/*` defaults are ephemeral container paths. Size
`output.persistence.size` accordingly (a full planet needs ~500Gi–1Ti+ on top
of tile output), and consider pointing `config.osmCacheDir` at faster storage
if your RWX backend (e.g. NFS) is slow for LevelDB workloads.

**Upgrading from chart 0.1.x:** the unused `cache.*` values and the
`-setup-cache` / `-osm-cache` PVCs were removed. This is safe — no workload
ever wrote to those volumes (they were mounted at `/app/cache`, which nothing
in the application references); delete any leftover PVCs after upgrading.

## Quick start

```bash
# Dev / smoke (small footprint, runs setup + smoke)
helm install rbt charts/rbt-data-generator \
  -f charts/rbt-data-generator/values-dev-smoke.yaml \
  --set auth.password=<db-password> \
  --set output.persistence.storageClassName=<rwx-storageclass>

# Production (continuous OSM updates + tiles + tile server + monitoring)
helm install rbt charts/rbt-data-generator \
  -f charts/rbt-data-generator/values-production.yaml \
  --set auth.password=<db-password> \
  --set output.persistence.storageClassName=<rwx-storageclass>
```

## External database

Set `postgres.enabled=false` and point at your database:

```bash
--set postgres.enabled=false \
--set postgres.external.host=my-postgres.example.com \
--set postgres.external.port=5432
```

Provide credentials via `auth.existingSecret` (the Secret must contain
`PG_PASS` and `DATABASE_PASSWORD` keys) or `--set auth.password=...`.

## Notes and constraints

- `rbt-tiles` is a Job, not a Deployment, so it does not restart-loop after a
  batch run completes. Re-run it with `helm upgrade` or by recreating the Job.
- `rbt-osm-updates` runs a single replica (`strategy: Recreate`); the supervisor
  uses a pidfile and manages one imposm child.
- The image ships an x86-64 imposm3 binary; schedule rbt workloads on amd64
  nodes (`values-production.yaml` sets `nodeSelector: kubernetes.io/arch: amd64`).
- The rbt image runs as the non-root `rbt` user. `podSecurityContext.fsGroup`
  makes the RWX output volume group-writable for it.
- Prometheus only scrapes the long-running `osm-updates` Deployment; the tiles
  Job is not a stable scrape target.
- `files/postgresql.conf` and `files/tile-server.json` mirror the repo-root
  `config/` files (Helm cannot read files outside the chart directory); keep them
  in sync.

## Validate

```bash
helm lint charts/rbt-data-generator
helm template rbt charts/rbt-data-generator -f charts/rbt-data-generator/values-production.yaml
helm template rbt charts/rbt-data-generator -f charts/rbt-data-generator/values-dev-smoke.yaml
```
