# Data Source Attribution

RBT Vector Tiles ingests third-party open data and turns it into Mapbox
Vector Tiles. The table below lists every dataset the importers download
(`rbt import osm|reference|geonames|buildings`), who provides it, the license
it carries, and what you must do when you distribute tiles built from it.

See [docs/data-sources.md](docs/data-sources.md) for per-source details
(which tile layers each dataset feeds, update cadence, and download
mechanism).

## Datasets

| Dataset | Provider | License | Attribution requirement | URL |
|---|---|---|---|---|
| OpenStreetMap planet + daily replication diffs | OpenStreetMap contributors | [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/) | **Mandatory:** "© OpenStreetMap contributors"; share-alike on derivative databases | <https://www.openstreetmap.org/copyright> |
| OSM water polygons, simplified water polygons, coastlines, Antarctica icesheet | osmdata.openstreetmap.de (derived from OSM) | ODbL 1.0 (inherits OSM) | Same as OpenStreetMap | <https://osmdata.openstreetmap.de/> |
| FieldMaps ADM0 boundaries (OSM edition, "all" worldview) | FieldMaps | ODbL 1.0 | "FieldMaps, U.S. Department of State, OpenStreetMap"; share-alike | <https://fieldmaps.io/data/adm0> |
| FieldMaps edge-matched ADM1/ADM2 (Humanitarian edition, "intl" worldview) | FieldMaps (UN OCHA CODs + geoBoundaries, edge-matched to OSM ADM0) | ODbL 1.0 (per FieldMaps; underlying CODs are CC BY 3.0 IGO, geoBoundaries is CC BY 4.0) | "FieldMaps, UN OCHA, geoBoundaries, U.S. Department of State, OpenStreetMap"; share-alike | <https://fieldmaps.io/data/edge-matched> |
| Natural Earth 10m vectors (`natural_earth_vector.gpkg`) | Natural Earth / NACIS | Public domain | None required (courtesy: "Made with Natural Earth") | <https://www.naturalearthdata.com/about/terms-of-use/> |
| OurAirports airports + runways CSV | OurAirports community (David Megginson) | Public domain dedication | None required (courtesy link to ourairports.com) | <https://ourairports.com/data/> |
| NGA GNS (GEOnet Names Server) feature classes | U.S. National Geospatial-Intelligence Agency | U.S. Government work — public domain; "no licensing requirements or restrictions" | None required | <https://geonames.nga.mil/> |
| USGS GNIS national files (PopulatedPlaces, HistoricalFeatures) | U.S. Geological Survey / U.S. Board on Geographic Names | U.S. Government work — public domain | None required (courtesy: "USGS GNIS") | <https://www.usgs.gov/tools/geographic-names-information-system-gnis> |
| Overture Maps buildings theme (`theme=buildings`, pinned release) | Overture Maps Foundation | ODbL 1.0 (buildings theme incorporates OSM) | "© OpenStreetMap contributors, Overture Maps Foundation"; share-alike | <https://docs.overturemaps.org/attribution/> |
| MIRTA — DoD military installations, ranges, and training areas (FY23) | U.S. Department of Defense (OSD/DISDI) | U.S. Government work — public domain; no license text published on the download page — **verify before release** | None required | <https://www.acq.osd.mil/eie/IMR/RPID/DISDI.html> |

> The NGA GNS data comes from **geonames.nga.mil** (a U.S. government
> gazetteer, public domain). It is unrelated to **geonames.org** (CC BY 4.0)
> — do not apply geonames.org terms to this pipeline.

## Required attribution on rendered maps

Any map rendered from tiles produced by this pipeline **must** display:

```
© OpenStreetMap contributors
```

OSM data is present in nearly every tile set this pipeline produces
(transportation, water, landcover, utilities, boundaries via FieldMaps, and
buildings via Overture), so treat the OSM credit as unconditional. Where
practical, also credit the other sources whose layers you serve:

```
© OpenStreetMap contributors | Overture Maps Foundation | FieldMaps |
Made with Natural Earth | NGA GNS | OurAirports
```

A shortened credit with a link to this file (or to the data-sources page of
the documentation) satisfies the "reasonably calculated to make any Person
aware" standard of ODbL section 4.3 when screen space is constrained.

## Code license vs. data licenses

GPL-3.0 (see [LICENSE](LICENSE)) covers this repository's **code** — the
`rbt` CLI, SQL schema files, importer scripts, and configuration. It does
**not** cover the tiles you generate: generated tile sets are derivative
works of the **data**, and they inherit the data licenses listed above. In
particular, ODbL share-alike applies to any publicly distributed tile set
built from OpenStreetMap or Overture buildings data — you must attribute
("© OpenStreetMap contributors"), license the derivative database under ODbL,
and keep it open on the same terms. Public-domain sources (Natural Earth,
OurAirports, NGA GNS, USGS GNIS) impose no such obligations, but they are
blended into the same tiles as ODbL data, so the ODbL obligations govern the
combined product.
