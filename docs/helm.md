# Helm deployment

The [`charts/rbt-data-generator`](https://github.com/MJJ203/rbt-data-generator/tree/main/charts/rbt-data-generator)
chart deploys RBT Vector Tiles to Kubernetes. It is a translation of the Docker
Compose profiles: PostGIS, the `rbt` setup/tiles/smoke jobs, the OSM update
daemon, and optional TileServer-GL and Prometheus.

## Prerequisites

- Kubernetes 1.25+ and Helm 3.8+.
- The rbt image published to a registry (defaults to
  `ghcr.io/mjj203/rbt-data-generator`; Helm does not build images).
- A **ReadWriteMany** StorageClass for the shared output volume, which the
  setup, osm-updates, tiles, smoke, and tile-server workloads all mount.
- amd64 worker nodes for the rbt workloads (the image ships an x86-64 imposm3).

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
