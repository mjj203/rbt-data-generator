# Helm deployment

The [`charts/rbt-data-generator`](https://github.com/MJJ203/rbt-data-generator/tree/main/charts/rbt-data-generator)
chart deploys RBT Vector Tiles to Kubernetes. It is a translation of the Docker
Compose profiles: PostGIS, the `rbt` setup/tiles/smoke jobs, the OSM update
daemon, and optional TileServer-GL and Prometheus.

## Prerequisites

- Kubernetes 1.25+ and Helm 3.8+.
- The rbt image published to a registry (defaults to
  `ghcr.io/mjj203/rbt-data-generator`; Helm does not build images).
- A **ReadWriteMany** StorageClass for the shared output volume (tiles, logs,
  and OSM state), which the setup, osm-updates, tiles, smoke, and tile-server
  workloads all mount.
- amd64 worker nodes for the rbt workloads (the image ships an x86-64 imposm3).

## Storage and OSM state

OSM state — the planet PBF, imposm's cache, and replication/diff state — lives
on the shared output volume under `config.osmDataDir` / `config.osmCacheDir` /
`config.osmDiffDir` (defaults: `/app/output/osm/{data,cache,diff}`). It must
stay on a persistent mount shared by the setup job and the OSM updater:
`rbt osm run` applies diffs against the imposm cache produced by
`rbt setup --all`. Size `output.persistence.size` accordingly — a full planet
needs roughly 500Gi–1Ti of headroom on top of tile output. If your RWX backend
(e.g. NFS) is slow for imposm's LevelDB cache, point `config.osmCacheDir` at
faster storage.

!!! note "Upgrading from chart 0.1.x"
    The unused `cache.*` values and the `-setup-cache` / `-osm-cache` PVCs were
    removed in chart 0.2.0. No workload ever wrote to those volumes; delete any
    leftover PVCs after upgrading.

## Component toggles

| Component        | Value                            | Default |
| ---------------- | -------------------------------- | ------- |
| PostGIS          | `postgres.enabled`               | `true`  |
| Setup job        | `setup.enabled`                  | `false` |
| OSM updater      | `production.osmUpdates.enabled`  | `false` |
| Tiles job        | `production.tiles.enabled`       | `false` |
| Smoke job        | `smoke.enabled`                  | `false` |
| TileServer-GL    | `tileServer.enabled`             | `false` |
| Prometheus       | `prometheus.enabled`             | `false` |

Two ready-made value files ship with the chart:

- `values-dev-smoke.yaml` - small storage/resources, runs setup + smoke.
- `values-production.yaml` - continuous OSM updates + tile generation, larger
  storage/resources, tile server and monitoring enabled, amd64 node selectors.

## Install

```bash
# Dev / smoke
helm install rbt charts/rbt-data-generator \
  -f charts/rbt-data-generator/values-dev-smoke.yaml \
  --set auth.password=<db-password> \
  --set output.persistence.storageClassName=<rwx-storageclass>

# Production
helm install rbt charts/rbt-data-generator \
  -f charts/rbt-data-generator/values-production.yaml \
  --set auth.password=<db-password> \
  --set output.persistence.storageClassName=<rwx-storageclass>
```

## Common operations

Follow the one-time setup job:

```bash
kubectl logs -f job/rbt-rbt-data-generator-setup
```

Re-run tile generation (Jobs are immutable, so delete then upgrade):

```bash
kubectl delete job rbt-rbt-data-generator-tiles --ignore-not-found
helm upgrade rbt charts/rbt-data-generator -f charts/rbt-data-generator/values-production.yaml
```

Reach the tile server or Prometheus locally:

```bash
kubectl port-forward svc/rbt-rbt-data-generator-tile-server 8080:8080
kubectl port-forward svc/rbt-rbt-data-generator-prometheus 9090:9090
```

## External database

```bash
helm install rbt charts/rbt-data-generator \
  --set postgres.enabled=false \
  --set postgres.external.host=my-postgres.example.com \
  --set postgres.external.port=5432 \
  --set auth.existingSecret=my-db-secret
```

The referenced Secret must contain `PG_PASS` and `DATABASE_PASSWORD` keys.

## Validate the chart

```bash
helm lint charts/rbt-data-generator
helm template rbt charts/rbt-data-generator -f charts/rbt-data-generator/values-production.yaml
helm template rbt charts/rbt-data-generator -f charts/rbt-data-generator/values-dev-smoke.yaml
```
