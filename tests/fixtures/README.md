# Test fixtures

## `liechtenstein-20260702.osm.pbf`

A complete OpenStreetMap extract of Liechtenstein (~3.4 MB), used by the
nightly integration workflow (`.github/workflows/nightly.yml`) to exercise the
real import → schema → tiles pipeline end to end: imposm imports it into
PostGIS, `rbt schema run` builds the `rbt.*` views on top, and `rbt tiles`
generates output in all three projections.

- **Source:** <https://download.geofabrik.de/europe/liechtenstein-latest.osm.pbf>
- **Downloaded:** 2026-07-02
- **License:** [ODbL 1.0](https://opendatacommons.org/licenses/odbl/) —
  data © OpenStreetMap contributors; extract by
  [Geofabrik](https://download.geofabrik.de/). See also the repository-level
  [ATTRIBUTION.md](../../ATTRIBUTION.md).

Whole-country extract on purpose: clipping smaller bounding boxes introduces
sliced-geometry edge cases that muddy test failures. ~3.4 MB is committed as a
plain git blob (no LFS); refreshes are rare, so history growth is negligible.

### Refreshing the fixture

```bash
curl -fLO https://download.geofabrik.de/europe/liechtenstein-latest.osm.pbf
osmium fileinfo liechtenstein-latest.osm.pbf   # note the data timestamp
mv liechtenstein-latest.osm.pbf tests/fixtures/liechtenstein-<YYYYMMDD>.osm.pbf
git rm tests/fixtures/liechtenstein-<OLD>.osm.pbf
```

Update the date in this README and in `.github/workflows/nightly.yml`'s
fixture glob if the naming changes (the workflow copies
`tests/fixtures/liechtenstein-*.osm.pbf`).

## `seed_water.sql` / `seed_building.sql`

Minimal synthetic `rbt.water` / `rbt.building` tables used by the per-PR
`integration-tiles` CI job, which verifies the tile backends without running
any importer.

## `seed_reference_stubs.sql`

Empty reference tables with the column shapes the schema SQL expects
(`rbt.osm_ocean`, `rbt.osm_ocean_simplified`, `rbt.sound_ocean`,
`naturalearth.ne_10m_geography_marine_polys`, `fieldmap.usa`). The nightly
workflow seeds these before `rbt schema run water landcover highway railway`
so the OSM-only fixture database satisfies the units' non-OSM references.
Empty is safe by construction: every consumer LEFT-JOINs or filters these
tables, so zero rows simply yields zero contributed features.
